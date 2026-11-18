//! Tags schreiben (MP3: ID3v2.4, FLAC: Vorbis Comment).
//!
//! Sicherheitsprinzip:
//! - Passt das neue Tag in den bisherigen Platz (inkl. Padding), wird nur der
//!   Tag-Bereich überschrieben – die Audiodaten werden nicht angefasst.
//! - Sonst wird die Datei als `.<name>.mync-part` neu geschrieben, deren
//!   `audio_hash` mit dem Original verglichen und erst dann per `rename`
//!   ersetzt. Bei Abweichung bleibt das Original unverändert.
//! - Nicht von mync verwaltete Frames/Kommentare (Cover, ReplayGain,
//!   MusicBrainz-IDs …) bleiben erhalten.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const src_mod = @import("source.zig");
const Source = src_mod.Source;
const audiohash = @import("audiohash.zig");
const tags = @import("tags.zig");

pub const Field = tags.Field;

pub const Error = error{UnsupportedFormat};

/// Ersetzt alle von mync verwalteten Felder durch `fields` (fehlende Felder
/// werden entfernt). `gpa` sollte eine Arena sein.
pub fn writeFile(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, fields: []const Field) !void {
    switch (audiohash.Format.fromPath(path)) {
        .mp3 => try writeMp3(gpa, io, dir, path, fields),
        .flac => try writeFlac(gpa, io, dir, path, fields),
        else => return error.UnsupportedFormat,
    }
}

fn get(fields: []const Field, name: []const u8) ?[]const []const u8 {
    for (fields) |f| if (std.mem.eql(u8, f.name, name) and f.values.len > 0) return f.values;
    return null;
}

fn first(fields: []const Field, name: []const u8) ?[]const u8 {
    const v = get(fields, name) orelse return null;
    return v[0];
}

// ───────────────────────────── Gemeinsames Neuschreiben ────────────────────

/// Schreibt `head` + Bytes ab `tail_from` des Originals in eine temporäre
/// Datei, prüft den Audio-Hash und ersetzt das Original.
fn rewrite(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, s: Source, head: []const u8, tail_from: u64) !void {
    const format = audiohash.Format.fromPath(path);
    const before = try audiohash.hashSource(s, format);
    const base = std.fs.path.basename(path);
    const dirname = std.fs.path.dirname(path);
    const tmp_name = try std.fmt.allocPrint(gpa, ".{s}.mync-part", .{base});
    const tmp_path = if (dirname) |d| try std.fs.path.join(gpa, &.{ d, tmp_name }) else tmp_name;

    const st = try s.file.stat(io);
    {
        const out = try dir.createFile(io, tmp_path, .{ .exclusive = false, .permissions = st.permissions });
        defer out.close(io);
        errdefer dir.deleteFile(io, tmp_path) catch {};
        try out.writePositionalAll(io, head, 0);
        var buf: [64 * 1024]u8 = undefined;
        var pos = tail_from;
        var dst: u64 = head.len;
        while (pos < s.len) {
            const n = try s.readAt(&buf, pos);
            if (n == 0) return error.EndOfStream;
            try out.writePositionalAll(io, buf[0..n], dst);
            pos += n;
            dst += n;
        }
        try out.sync(io);
    }
    // Mit dem Format des Originals prüfen (die Endung .mync-part ist unbekannt)
    const check = blk: {
        const ts = Source.open(io, dir, tmp_path) catch |e| {
            dir.deleteFile(io, tmp_path) catch {};
            return e;
        };
        defer ts.close();
        break :blk audiohash.hashSource(ts, format) catch |e| {
            dir.deleteFile(io, tmp_path) catch {};
            return e;
        };
    };
    if (!std.mem.eql(u8, &check.hash, &before.hash)) {
        dir.deleteFile(io, tmp_path) catch {};
        return error.AudioChanged;
    }
    try Io.Dir.rename(dir, tmp_path, dir, path, io);
}

// ───────────────────────────── MP3 / ID3v2.4 ───────────────────────────────

const managed_id3 = std.StaticStringMap(void).initComptime(.{
    .{"TIT2"}, .{"TPE1"}, .{"TALB"}, .{"TPE2"}, .{"TCOM"}, .{"TCON"},
    .{"TDRC"}, .{"TYER"}, .{"TDAT"}, .{"TIME"}, .{"TRDA"}, .{"TRCK"},
    .{"TPOS"},
});

fn appendFrame(gpa: Allocator, out: *std.ArrayList(u8), id: []const u8, body: []const u8) !void {
    try out.appendSlice(gpa, id);
    var size: [4]u8 = undefined;
    const n: u32 = @intCast(body.len);
    size = .{ @intCast((n >> 21) & 0x7f), @intCast((n >> 14) & 0x7f), @intCast((n >> 7) & 0x7f), @intCast(n & 0x7f) };
    try out.appendSlice(gpa, &size);
    try out.appendSlice(gpa, &.{ 0, 0 });
    try out.appendSlice(gpa, body);
}

fn appendText(gpa: Allocator, out: *std.ArrayList(u8), id: []const u8, values: []const []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    try body.append(gpa, 3); // UTF-8
    for (values, 0..) |v, i| {
        if (i > 0) try body.append(gpa, 0);
        try body.appendSlice(gpa, v);
    }
    try appendFrame(gpa, out, id, body.items);
}

/// COMM/USLT mit leerer Beschreibung, Sprache „XXX“ (unbekannt).
fn appendLangText(gpa: Allocator, out: *std.ArrayList(u8), id: []const u8, text: []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(gpa, &.{ 3, 'X', 'X', 'X', 0 });
    try body.appendSlice(gpa, text);
    try appendFrame(gpa, out, id, body.items);
}

fn numberPair(gpa: Allocator, n: ?[]const u8, total: ?[]const u8) !?[]const u8 {
    const v = n orelse return null;
    if (total) |t| return try std.fmt.allocPrint(gpa, "{s}/{s}", .{ v, t });
    return v;
}

/// Ist das ein COMM/USLT mit leerer Beschreibung (also von mync verwaltet)?
fn isManagedLangFrame(gpa: Allocator, id: []const u8, body: []const u8) bool {
    if (!(std.mem.eql(u8, id, "COMM") or std.mem.eql(u8, id, "USLT"))) return false;
    if (body.len < 4) return true;
    const rest = body[4..];
    const t = tags.termEnd(body[0], rest);
    const desc = tags.decodeText(gpa, body[0], rest[0..t.text_end]) catch return true;
    return desc.len == 0;
}

/// Übernimmt nicht verwaltete Frames aus einem bestehenden ID3v2-Tag als v2.4-Frames.
fn keptFrames(gpa: Allocator, tag: []const u8, out: *std.ArrayList(u8)) !void {
    if (tag.len < 10) return;
    const major = tag[3];
    const flags = tag[5];
    if (major < 2 or major > 4) return;
    const size = @min(src_mod.syncsafe(tag[6..10]), tag.len - 10);
    var body: []const u8 = tag[10 .. 10 + size];
    if (flags & 0x80 != 0 and major < 4) body = try deunsync(gpa, body);
    var pos: usize = 0;
    if (flags & 0x40 != 0 and major >= 3 and body.len >= 4) {
        pos = if (major == 3) 4 + src_mod.readU32Be(body[0..4]) else src_mod.syncsafe(body[0..4]);
    }
    const id_len: usize = if (major == 2) 3 else 4;
    const hdr_len: usize = if (major == 2) 6 else 10;
    while (pos + hdr_len <= body.len) {
        const id = body[pos .. pos + id_len];
        if (id[0] == 0) break;
        const fsize: usize = switch (major) {
            2 => std.mem.readInt(u24, body[pos + 3 ..][0..3], .big),
            3 => src_mod.readU32Be(body[pos + 4 ..]),
            else => src_mod.syncsafe(body[pos + 4 .. pos + 8]),
        };
        const fl: [2]u8 = if (major >= 3) .{ body[pos + 8], body[pos + 9] } else .{ 0, 0 };
        const frame_start = pos;
        pos += hdr_len;
        if (fsize > body.len - pos) break;
        var data = body[pos .. pos + fsize];
        pos += fsize;

        switch (major) {
            4 => {
                const plain = blk: {
                    if (fl[1] & 0x0c != 0) break :blk data; // komprimiert/verschlüsselt: roh behalten
                    var d = data;
                    if (fl[1] & 0x02 != 0) d = try deunsync(gpa, d);
                    if (fl[1] & 0x01 != 0 and d.len >= 4) d = d[4..];
                    break :blk d;
                };
                if (managed_id3.has(id) or isManagedLangFrame(gpa, id, plain)) continue;
                try out.appendSlice(gpa, body[frame_start..pos]); // unverändert übernehmen
            },
            3 => {
                if (fl[1] & 0xc0 != 0) continue; // komprimiert/verschlüsselt: verwerfen
                if (fl[1] & 0x20 != 0) {
                    if (data.len < 1) continue;
                    data = data[1..];
                }
                if (managed_id3.has(id) or isManagedLangFrame(gpa, id, data)) continue;
                if (std.mem.eql(u8, id, "TSIZ") or std.mem.eql(u8, id, "EQUA") or std.mem.eql(u8, id, "RVAD")) continue; // in 2.4 entfallen
                try appendFrame(gpa, out, id, data);
            },
            else => {
                // ID3v2.2: nur Bilder übernehmen (PIC → APIC)
                if (!std.mem.eql(u8, id, "PIC") or data.len < 5) continue;
                const mime: []const u8 = if (std.ascii.eqlIgnoreCase(data[1..4], "PNG")) "image/png" else "image/jpeg";
                var b: std.ArrayList(u8) = .empty;
                try b.append(gpa, data[0]);
                try b.appendSlice(gpa, mime);
                try b.append(gpa, 0);
                try b.appendSlice(gpa, data[4..]);
                try appendFrame(gpa, out, "APIC", b.items);
            },
        }
    }
}

fn deunsync(gpa: Allocator, data: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(gpa, data.len);
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        out.appendAssumeCapacity(data[i]);
        if (data[i] == 0xff and i + 1 < data.len and data[i + 1] == 0) i += 1;
    }
    return out.items;
}

/// Erzeugt die Frames für die verwalteten Felder.
fn managedFrames(gpa: Allocator, fields: []const Field, out: *std.ArrayList(u8)) !void {
    const text = [_][2][]const u8{
        .{ "title", "TIT2" },    .{ "artist", "TPE1" },   .{ "album", "TALB" },
        .{ "albumartist", "TPE2" }, .{ "composer", "TCOM" }, .{ "genre", "TCON" },
        .{ "date", "TDRC" },
    };
    for (text) |m| if (get(fields, m[0])) |v| try appendText(gpa, out, m[1], v);
    if (try numberPair(gpa, first(fields, "track"), first(fields, "tracktotal"))) |v| try appendText(gpa, out, "TRCK", &.{v});
    if (try numberPair(gpa, first(fields, "disc"), first(fields, "disctotal"))) |v| try appendText(gpa, out, "TPOS", &.{v});
    if (first(fields, "comment")) |v| try appendLangText(gpa, out, "COMM", v);
    if (first(fields, "lyrics")) |v| try appendLangText(gpa, out, "USLT", v);
}

fn id3Header(size: usize) [10]u8 {
    const n: u32 = @intCast(size);
    return .{ 'I', 'D', '3', 4, 0, 0, @intCast((n >> 21) & 0x7f), @intCast((n >> 14) & 0x7f), @intCast((n >> 7) & 0x7f), @intCast(n & 0x7f) };
}

fn writeMp3(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, fields: []const Field) !void {
    const s = try Source.open(io, dir, path);
    var closed = false;
    defer if (!closed) s.close();

    // Alle ID3v2-Tags am Anfang (manche Dateien haben mehrere hintereinander)
    var old_total: u64 = 0;
    var frames: std.ArrayList(u8) = .empty;
    try managedFrames(gpa, fields, &frames);
    while (true) {
        const l = try audiohash.id3v2Len(s, old_total);
        if (l == 0) break;
        const tag = try s.alloc(gpa, old_total, @min(l, s.len - old_total));
        try keptFrames(gpa, tag, &frames);
        old_total += l;
    }

    if (old_total > 0 and frames.items.len + 10 <= old_total) {
        // In-place: gleicher Platz, Rest wird Padding
        const tag = try gpa.alloc(u8, @intCast(old_total));
        @memset(tag, 0);
        @memcpy(tag[0..10], &id3Header(@intCast(old_total - 10)));
        @memcpy(tag[10 .. 10 + frames.items.len], frames.items);
        s.close();
        closed = true;
        const f = try dir.openFile(io, path, .{ .mode = .read_write });
        defer f.close(io);
        try f.writePositionalAll(io, tag, 0);
        try writeId3v1(io, f, fields);
        try f.sync(io);
        return;
    }
    const padding = 2048;
    const head = try gpa.alloc(u8, 10 + frames.items.len + padding);
    @memset(head, 0);
    @memcpy(head[0..10], &id3Header(frames.items.len + padding));
    @memcpy(head[10 .. 10 + frames.items.len], frames.items);
    try rewrite(gpa, io, dir, path, s, head, old_total);
    s.close();
    closed = true;
    const f = try dir.openFile(io, path, .{ .mode = .read_write });
    defer f.close(io);
    try writeId3v1(io, f, fields);
    try f.sync(io);
}

/// Aktualisiert ein vorhandenes ID3v1-Tag (legt keines neu an).
fn writeId3v1(io: Io, f: Io.File, fields: []const Field) !void {
    const len = try f.length(io);
    if (len < 128) return;
    var t: [128]u8 = undefined;
    if (try f.readPositionalAll(io, &t, len - 128) != 128 or !std.mem.eql(u8, t[0..3], "TAG")) return;
    const genre = t[127];
    @memset(t[3..127], 0);
    latin1Into(t[3..33], first(fields, "title"));
    latin1Into(t[33..63], first(fields, "artist"));
    latin1Into(t[63..93], first(fields, "album"));
    latin1Into(t[93..97], first(fields, "date"));
    latin1Into(t[97..125], first(fields, "comment"));
    if (first(fields, "track")) |tr| t[126] = std.fmt.parseInt(u8, tr, 10) catch 0;
    t[127] = genre;
    try f.writePositionalAll(io, &t, len - 128);
}

/// UTF-8 → Latin-1, abgeschnitten; nicht darstellbare Zeichen werden „?“.
fn latin1Into(dst: []u8, src: ?[]const u8) void {
    const s = src orelse return;
    var view = std.unicode.Utf8View.init(s) catch return;
    var it = view.iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (i >= dst.len) break;
        dst[i] = if (cp < 256) @intCast(cp) else '?';
        i += 1;
    }
}

// ───────────────────────────── FLAC / Vorbis Comment ───────────────────────

const vorbis_out = [_][2][]const u8{
    .{ "title", "TITLE" },         .{ "artist", "ARTIST" },       .{ "album", "ALBUM" },
    .{ "albumartist", "ALBUMARTIST" }, .{ "composer", "COMPOSER" }, .{ "genre", "GENRE" },
    .{ "date", "DATE" },           .{ "track", "TRACKNUMBER" },   .{ "tracktotal", "TRACKTOTAL" },
    .{ "disc", "DISCNUMBER" },     .{ "disctotal", "DISCTOTAL" }, .{ "comment", "COMMENT" },
    .{ "lyrics", "LYRICS" },        .{ "description", "DESCRIPTION" },
};

fn appendU32Le(gpa: Allocator, out: *std.ArrayList(u8), v: usize) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(v), .little);
    try out.appendSlice(gpa, &b);
}

/// Baut einen neuen Vorbis-Comment-Block: Vendor + fremde Kommentare bleiben.
pub fn buildVorbisComment(gpa: Allocator, old: ?[]const u8, fields: []const Field) ![]u8 {
    var vendor: []const u8 = "mync";
    var kept: std.ArrayList([]const u8) = .empty;
    if (old) |d| parse: {
        if (d.len < 8) break :parse;
        const vl = src_mod.readU32Le(d[0..4]);
        if (4 + vl + 4 > d.len) break :parse;
        vendor = d[4 .. 4 + vl];
        var pos: usize = 4 + vl;
        const count = src_mod.readU32Le(d[pos..]);
        pos += 4;
        var i: u32 = 0;
        while (i < count and pos + 4 <= d.len) : (i += 1) {
            const len = src_mod.readU32Le(d[pos..]);
            pos += 4;
            if (len > d.len - pos) break;
            const entry = d[pos .. pos + len];
            pos += len;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            var kb: [64]u8 = undefined;
            if (eq > kb.len) {
                try kept.append(gpa, entry);
                continue;
            }
            const key = std.ascii.upperString(&kb, entry[0..eq]);
            if (tags.vorbisField(key) == null) try kept.append(gpa, entry);
        }
    }
    var entries: std.ArrayList([]const u8) = .empty;
    for (vorbis_out) |m| {
        if (get(fields, m[0])) |vals| for (vals) |v| {
            try entries.append(gpa, try std.fmt.allocPrint(gpa, "{s}={s}", .{ m[1], v }));
        };
    }
    try entries.appendSlice(gpa, kept.items);
    var out: std.ArrayList(u8) = .empty;
    try appendU32Le(gpa, &out, vendor.len);
    try out.appendSlice(gpa, vendor);
    try appendU32Le(gpa, &out, entries.items.len);
    for (entries.items) |e| {
        try appendU32Le(gpa, &out, e.len);
        try out.appendSlice(gpa, e);
    }
    return out.items;
}

const Block = struct { typ: u7, data: []const u8 };

fn appendBlock(gpa: Allocator, out: *std.ArrayList(u8), typ: u7, last: bool, data: []const u8) !void {
    if (data.len > 0xffffff) return error.BlockTooLarge;
    try out.append(gpa, @as(u8, typ) | (if (last) @as(u8, 0x80) else 0));
    var b: [3]u8 = undefined;
    std.mem.writeInt(u24, &b, @intCast(data.len), .big);
    try out.appendSlice(gpa, &b);
    try out.appendSlice(gpa, data);
}

fn writeFlac(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, fields: []const Field) !void {
    const s = try Source.open(io, dir, path);
    var closed = false;
    defer if (!closed) s.close();

    const prefix = try audiohash.id3v2Len(s, 0);
    var magic: [4]u8 = undefined;
    try s.readExactAt(&magic, prefix);
    if (!std.mem.eql(u8, &magic, "fLaC")) return error.InvalidFlac;
    const meta_start = prefix + 4;

    var blocks: std.ArrayList(Block) = .empty;
    var pos = meta_start;
    var old_vc: ?[]const u8 = null;
    while (true) {
        var hdr: [4]u8 = undefined;
        try s.readExactAt(&hdr, pos);
        const typ: u7 = @intCast(hdr[0] & 0x7f);
        const size = std.mem.readInt(u24, hdr[1..4], .big);
        const data = try s.alloc(gpa, pos + 4, size);
        if (typ == 4) old_vc = data;
        try blocks.append(gpa, .{ .typ = typ, .data = data });
        pos += 4 + @as(u64, size);
        if (hdr[0] & 0x80 != 0) break;
    }
    const meta_end = pos;
    if (blocks.items.len == 0 or blocks.items[0].typ != 0) return error.InvalidFlac;

    const vc = try buildVorbisComment(gpa, old_vc, fields);
    // Reihenfolge: STREAMINFO, (VC an alter Stelle bzw. direkt danach), Rest; ohne PADDING
    var ordered: std.ArrayList(Block) = .empty;
    var vc_placed = false;
    for (blocks.items, 0..) |b, i| {
        if (b.typ == 1) continue; // PADDING
        if (b.typ == 4) {
            if (!vc_placed) try ordered.append(gpa, .{ .typ = 4, .data = vc });
            vc_placed = true;
            continue;
        }
        try ordered.append(gpa, b);
        if (i == 0 and old_vc == null) {
            try ordered.append(gpa, .{ .typ = 4, .data = vc });
            vc_placed = true;
        }
    }
    var used: u64 = 0;
    for (ordered.items) |b| used += 4 + b.data.len;
    const old_len = meta_end - meta_start;

    const in_place = used <= old_len and (old_len - used == 0 or old_len - used >= 4);
    const pad_len: usize = if (in_place) (if (old_len == used) 0 else @intCast(old_len - used - 4)) else 4096;
    var meta: std.ArrayList(u8) = .empty;
    // Ohne Padding ist der letzte echte Block der letzte, sonst das Padding.
    const no_padding = in_place and old_len == used;
    for (ordered.items, 0..) |b, i| {
        try appendBlock(gpa, &meta, b.typ, no_padding and i == ordered.items.len - 1, b.data);
    }
    if (!no_padding) {
        const pad = try gpa.alloc(u8, pad_len);
        @memset(pad, 0);
        try appendBlock(gpa, &meta, 1, true, pad);
    }

    if (in_place) {
        std.debug.assert(meta.items.len == old_len);
        s.close();
        closed = true;
        const f = try dir.openFile(io, path, .{ .mode = .read_write });
        defer f.close(io);
        try f.writePositionalAll(io, meta.items, meta_start);
        try f.sync(io);
        return;
    }
    const head = try gpa.alloc(u8, @intCast(meta_start + meta.items.len));
    try s.readExactAt(head[0..@intCast(meta_start)], 0);
    @memcpy(head[@intCast(meta_start)..], meta.items);
    try rewrite(gpa, io, dir, path, s, head, meta_end);
}

// ───────────────────────────── Tests ───────────────────────────────────────

const testing = std.testing;

fn field(name: []const u8, v: []const u8) Field {
    return .{ .name = name, .values = &.{v} };
}

const new_fields = [_]Field{
    field("title", "Neuer Titel – äöü"),
    .{ .name = "artist", .values = &.{ "Künstler A", "Künstler B" } },
    field("album", "Album"),
    field("date", "2001"),
    field("track", "7"),
    field("tracktotal", "12"),
    field("genre", "Elektronik"),
    field("comment", "Kommentar"),
};

fn checkRoundtrip(name: []const u8, extra_lyrics: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const options = @import("build_options");
    var td = try Io.Dir.cwd().openDir(testing.io, options.testdata_dir, .{});
    defer td.close(testing.io);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try td.copyFile(name, tmp.dir, name, testing.io, .{});

    const before = try audiohash.hashFile(testing.io, tmp.dir, name);
    const old = try tags.readFile(a, testing.io, tmp.dir, name);
    var fields: std.ArrayList(Field) = .empty;
    try fields.appendSlice(a, &new_fields);
    if (extra_lyrics) {
        const line = "Zeile\n";
        const long = try a.alloc(u8, line.len * 2000);
        for (0..2000) |i| @memcpy(long[i * line.len ..][0..line.len], line);
        try fields.append(a, field("lyrics", long));
    }
    try writeFile(a, testing.io, tmp.dir, name, fields.items);

    const after = try audiohash.hashFile(testing.io, tmp.dir, name);
    try testing.expectEqualStrings(&before.hash, &after.hash);
    const got = try tags.readFile(a, testing.io, tmp.dir, name);
    try testing.expectEqualStrings("Neuer Titel – äöü", got.get("title").?[0]);
    try testing.expectEqual(@as(usize, 2), got.get("artist").?.len);
    try testing.expectEqualStrings("Künstler B", got.get("artist").?[1]);
    try testing.expectEqualStrings("7", got.get("track").?[0]);
    try testing.expectEqualStrings("12", got.get("tracktotal").?[0]);
    try testing.expectEqualStrings("Kommentar", got.get("comment").?[0]);
    try testing.expect(got.get("composer") == null); // entfernt
    try testing.expectEqual(old.pictures.len, got.pictures.len); // Cover bleibt
    if (extra_lyrics) try testing.expect(got.get("lyrics") != null) else try testing.expect(got.get("lyrics") == null);
    // Keine temporäre Datei übrig
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, try std.fmt.allocPrint(a, ".{s}.mync-part", .{name}), .{}));
}

test "MP3: ID3v2.4 in-place und mit Neuschreiben" {
    try checkRoundtrip("mp3-tagged.mp3", false); // passt in Padding
    try checkRoundtrip("mp3-tagged.mp3", true); // zu groß → Neuschreiben
    try checkRoundtrip("mp3-retagged.mp3", false); // ID3v2.3 + ID3v1
    try checkRoundtrip("mp3-plain.mp3", false); // ohne Tag
}

test "FLAC: Vorbis Comment in-place und mit Neuschreiben" {
    try checkRoundtrip("flac-tagged.flac", false);
    try checkRoundtrip("flac-tagged.flac", true);
    try checkRoundtrip("flac-retagged.flac", false);
    try checkRoundtrip("flac-plain.flac", false);
}

test "Kapitel bleiben beim Tag-Schreiben erhalten" {
    for ([_][]const u8{ "mp3-chapters.mp3", "flac-chapters.flac" }) |name| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const options = @import("build_options");
        var td = try Io.Dir.cwd().openDir(testing.io, options.testdata_dir, .{});
        defer td.close(testing.io);
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try td.copyFile(name, tmp.dir, name, testing.io, .{});
        const before = try tags.readFile(a, testing.io, tmp.dir, name);
        try testing.expectEqual(@as(usize, 3), before.chapters.len);
        try writeFile(a, testing.io, tmp.dir, name, &new_fields);
        const after = try tags.readFile(a, testing.io, tmp.dir, name);
        try testing.expectEqual(@as(usize, 3), after.chapters.len);
        try testing.expectEqualStrings("Hauptteil – Ärger", after.chapters[1].title);
        try testing.expectEqual(@as(u64, 150), after.chapters[1].start_ms);
    }
}

test "nicht unterstützte Formate" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnsupportedFormat, writeFile(arena.allocator(), testing.io, Io.Dir.cwd(), "x.opus", &.{}));
}
