//! Tags schreiben: MP3 (ID3v2.4), FLAC (Vorbis Comment), Ogg Vorbis/Opus
//! (Kommentar-Paket), MP4/M4A (`moov/udta/meta/ilst`), WAV (`id3 `-Chunk).
//! Außerdem Cover setzen oder entfernen.
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
const ogg = @import("ogg.zig");

pub const Field = tags.Field;

pub const Error = error{ UnsupportedFormat, UnsupportedImage };

/// Was mit eingebetteten Bildern passieren soll.
pub const Cover = union(enum) {
    keep,
    remove,
    /// Ersetzt alle Bilder durch dieses (JPEG oder PNG) als Vorderseite.
    set: []const u8,

    fn changes(c: Cover) bool {
        return c != .keep;
    }
};

pub const Image = struct { data: []const u8, mime: []const u8, width: u32 = 0, height: u32 = 0, depth: u32 = 24 };

/// Erkennt JPEG/PNG und liest die Bildgröße.
pub fn imageInfo(data: []const u8) !Image {
    if (data.len >= 24 and std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) {
        const depth: u32 = if (data.len > 25) @as(u32, data[24]) * switch (data[25]) {
            2 => @as(u32, 3),
            4 => 2,
            6 => 4,
            else => 1,
        } else 24;
        return .{ .data = data, .mime = "image/png", .width = src_mod.readU32Be(data[16..20]), .height = src_mod.readU32Be(data[20..24]), .depth = depth };
    }
    if (data.len >= 4 and data[0] == 0xff and data[1] == 0xd8) {
        var img: Image = .{ .data = data, .mime = "image/jpeg" };
        var p: usize = 2;
        while (p + 4 <= data.len) {
            if (data[p] != 0xff) {
                p += 1;
                continue;
            }
            const m = data[p + 1];
            if (m == 0xff) {
                p += 1;
                continue;
            }
            if (m == 0xd8 or m == 0x01 or (m >= 0xd0 and m <= 0xd7)) {
                p += 2;
                continue;
            }
            const len = src_mod.readU16Be(data[p + 2 ..]);
            const sof = m >= 0xc0 and m <= 0xcf and m != 0xc4 and m != 0xc8 and m != 0xcc;
            if (sof and p + 10 <= data.len) {
                img.height = src_mod.readU16Be(data[p + 5 ..]);
                img.width = src_mod.readU16Be(data[p + 7 ..]);
                img.depth = @as(u32, data[p + 4]) * data[p + 9];
                break;
            }
            if (m == 0xda) break;
            p += 2 + len;
        }
        return img;
    }
    return error.UnsupportedImage;
}

/// Ersetzt alle von mync verwalteten Felder durch `fields` (fehlende Felder
/// werden entfernt). `gpa` sollte eine Arena sein.
pub fn writeFile(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, fields: []const Field, cover: Cover) !void {
    const img: ?Image = switch (cover) {
        .set => |d| try imageInfo(d),
        else => null,
    };
    switch (audiohash.Format.fromPath(path)) {
        .mp3 => try writeMp3(gpa, io, dir, path, fields, cover, img),
        .flac => try writeFlac(gpa, io, dir, path, fields, cover, img),
        .ogg => try writeOgg(gpa, io, dir, path, fields, cover, img),
        .mp4 => try writeMp4(gpa, io, dir, path, fields, cover, img),
        .wav => try writeWav(gpa, io, dir, path, fields, cover, img),
        else => return error.UnsupportedFormat,
    }
}

/// Kann mync die Tags dieser Datei schreiben?
pub fn canWrite(path: []const u8) bool {
    return switch (audiohash.Format.fromPath(path)) {
        .mp3, .flac, .ogg, .mp4, .wav => true,
        else => false,
    };
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

/// Schreibt `head` + Bytes ab `tail_from` des Originals neu (siehe `rewritePieces`).
fn rewrite(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, s: Source, head: []const u8, tail_from: u64) !void {
    return rewritePieces(gpa, io, dir, path, s, &.{ .{ .bytes = head }, .{ .copy = .{ .from = tail_from, .to = s.len } } });
}

/// Ein Stück der neuen Datei.
const Piece = union(enum) {
    bytes: []const u8,
    /// Bereich des Originals unverändert übernehmen.
    copy: struct { from: u64, to: u64 },
    /// Ogg-Seiten ab `from` bis Dateiende: Seitennummer + `delta`, neue CRC.
    ogg: struct { from: u64, delta: u32 },
};

/// Schreibt die Stücke in eine temporäre Datei, prüft den Audio-Hash und
/// ersetzt das Original.
fn rewritePieces(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, s: Source, pieces: []const Piece) !void {
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
        const buf = try gpa.alloc(u8, 27 + 255 + 255 * 255);
        var dst: u64 = 0;
        for (pieces) |piece| switch (piece) {
            .bytes => |b| {
                try out.writePositionalAll(io, b, dst);
                dst += b.len;
            },
            .copy => |c| {
                var pos = c.from;
                while (pos < c.to) {
                    const n = try s.readAt(buf[0..@intCast(@min(buf.len, c.to - pos))], pos);
                    if (n == 0) return error.EndOfStream;
                    try out.writePositionalAll(io, buf[0..n], dst);
                    pos += n;
                    dst += n;
                }
            },
            .ogg => |o| {
                var pos = o.from;
                while (pos + 27 <= s.len) {
                    try s.readExactAt(buf[0..27], pos);
                    if (!std.mem.eql(u8, buf[0..4], "OggS")) return error.InvalidOgg;
                    const nseg: usize = buf[26];
                    try s.readExactAt(buf[27 .. 27 + nseg], pos + 27);
                    var body: usize = 0;
                    for (buf[27 .. 27 + nseg]) |l| body += l;
                    const len = 27 + nseg + body;
                    try s.readExactAt(buf[27 + nseg .. len], pos + 27 + nseg);
                    const seq = std.mem.readInt(u32, buf[18..22], .little);
                    std.mem.writeInt(u32, buf[18..22], seq +% o.delta, .little);
                    setOggCrc(buf[0..len]);
                    try out.writePositionalAll(io, buf[0..len], dst);
                    pos += len;
                    dst += len;
                }
                if (pos != s.len) return error.InvalidOgg;
            },
        };
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
fn keptFrames(gpa: Allocator, tag: []const u8, out: *std.ArrayList(u8), drop_pictures: bool) !void {
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
                if (drop_pictures and std.mem.eql(u8, id, "APIC")) continue;
                try out.appendSlice(gpa, body[frame_start..pos]); // unverändert übernehmen
            },
            3 => {
                if (fl[1] & 0xc0 != 0) continue; // komprimiert/verschlüsselt: verwerfen
                if (fl[1] & 0x20 != 0) {
                    if (data.len < 1) continue;
                    data = data[1..];
                }
                if (managed_id3.has(id) or isManagedLangFrame(gpa, id, data)) continue;
                if (drop_pictures and std.mem.eql(u8, id, "APIC")) continue;
                if (std.mem.eql(u8, id, "TSIZ") or std.mem.eql(u8, id, "EQUA") or std.mem.eql(u8, id, "RVAD")) continue; // in 2.4 entfallen
                try appendFrame(gpa, out, id, data);
            },
            else => {
                // ID3v2.2: nur Bilder übernehmen (PIC → APIC)
                if (drop_pictures or !std.mem.eql(u8, id, "PIC") or data.len < 5) continue;
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
fn managedFrames(gpa: Allocator, fields: []const Field, img: ?Image, out: *std.ArrayList(u8)) !void {
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
    if (img) |im| {
        var body: std.ArrayList(u8) = .empty;
        try body.append(gpa, 0);
        try body.appendSlice(gpa, im.mime);
        try body.appendSlice(gpa, &.{ 0, 3, 0 }); // Vorderseite, leere Beschreibung
        try body.appendSlice(gpa, im.data);
        try appendFrame(gpa, out, "APIC", body.items);
    }
}

/// Baut ein ID3v2.4-Tag aus verwalteten + übernommenen Frames.
fn buildId3(gpa: Allocator, old_tag: ?[]const u8, fields: []const Field, cover: Cover, img: ?Image, padding: usize) ![]u8 {
    var frames: std.ArrayList(u8) = .empty;
    try managedFrames(gpa, fields, img, &frames);
    if (old_tag) |t| try keptFrames(gpa, t, &frames, cover.changes());
    const out = try gpa.alloc(u8, 10 + frames.items.len + padding);
    @memset(out, 0);
    @memcpy(out[0..10], &id3Header(frames.items.len + padding));
    @memcpy(out[10 .. 10 + frames.items.len], frames.items);
    return out;
}

fn id3Header(size: usize) [10]u8 {
    const n: u32 = @intCast(size);
    return .{ 'I', 'D', '3', 4, 0, 0, @intCast((n >> 21) & 0x7f), @intCast((n >> 14) & 0x7f), @intCast((n >> 7) & 0x7f), @intCast(n & 0x7f) };
}

fn writeMp3(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, fields: []const Field, cover: Cover, img: ?Image) !void {
    const s = try Source.open(io, dir, path);
    var closed = false;
    defer if (!closed) s.close();

    // Alle ID3v2-Tags am Anfang (manche Dateien haben mehrere hintereinander)
    var old_total: u64 = 0;
    var frames: std.ArrayList(u8) = .empty;
    try managedFrames(gpa, fields, img, &frames);
    while (true) {
        const l = try audiohash.id3v2Len(s, old_total);
        if (l == 0) break;
        const tag = try s.alloc(gpa, old_total, @min(l, s.len - old_total));
        try keptFrames(gpa, tag, &frames, cover.changes());
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
/// `drop_pictures`: eingebettete Bilder (METADATA_BLOCK_PICTURE/COVERART)
/// entfernen; `picture`: neuer FLAC-PICTURE-Block als METADATA_BLOCK_PICTURE.
pub fn buildVorbisComment(gpa: Allocator, old: ?[]const u8, fields: []const Field, drop_pictures: bool, picture: ?[]const u8) ![]u8 {
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
            if (tags.vorbisField(key) != null) continue;
            if (drop_pictures and (std.mem.eql(u8, key, "METADATA_BLOCK_PICTURE") or std.mem.startsWith(u8, key, "COVERART"))) continue;
            try kept.append(gpa, entry);
        }
    }
    var entries: std.ArrayList([]const u8) = .empty;
    for (vorbis_out) |m| {
        if (get(fields, m[0])) |vals| for (vals) |v| {
            try entries.append(gpa, try std.fmt.allocPrint(gpa, "{s}={s}", .{ m[1], v }));
        };
    }
    try entries.appendSlice(gpa, kept.items);
    if (picture) |p| {
        const enc = std.base64.standard.Encoder;
        const prefix = "METADATA_BLOCK_PICTURE=";
        const e = try gpa.alloc(u8, prefix.len + enc.calcSize(p.len));
        @memcpy(e[0..prefix.len], prefix);
        _ = enc.encode(e[prefix.len..], p);
        try entries.append(gpa, e);
    }
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

/// FLAC-PICTURE-Block (auch für METADATA_BLOCK_PICTURE in Ogg).
fn flacPicture(gpa: Allocator, img: Image) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const nums = [_]u32{ 3, @intCast(img.mime.len) };
    for (nums) |n| try appendU32Be(gpa, &out, n);
    try out.appendSlice(gpa, img.mime);
    for ([_]u32{ 0, img.width, img.height, img.depth, 0, @intCast(img.data.len) }) |n| try appendU32Be(gpa, &out, n);
    try out.appendSlice(gpa, img.data);
    return out.items;
}

fn appendU32Be(gpa: Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try out.appendSlice(gpa, &b);
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

fn writeFlac(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, fields: []const Field, cover: Cover, img: ?Image) !void {
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

    const vc = try buildVorbisComment(gpa, old_vc, fields, cover.changes(), null);
    // Reihenfolge: STREAMINFO, (VC an alter Stelle bzw. direkt danach), Rest; ohne PADDING
    var ordered: std.ArrayList(Block) = .empty;
    var vc_placed = false;
    for (blocks.items, 0..) |b, i| {
        if (b.typ == 1) continue; // PADDING
        if (b.typ == 6 and cover.changes()) continue; // PICTURE wird ersetzt
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
    if (img) |im| try ordered.append(gpa, .{ .typ = 6, .data = try flacPicture(gpa, im) });
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

// ───────────────────────────── Ogg Vorbis / Opus ───────────────────────────

const OggCrc = std.hash.crc.Generic(u32, .{
    .polynomial = 0x04c11db7,
    .initial = 0,
    .reflect_input = false,
    .reflect_output = false,
    .xor_output = 0,
});

fn setOggCrc(page: []u8) void {
    @memset(page[22..26], 0);
    std.mem.writeInt(u32, page[22..26], OggCrc.hash(page), .little);
}

/// Verpackt Pakete in Ogg-Seiten (Granule 0 bzw. -1, ab Seitennummer `seq`).
fn paginate(gpa: Allocator, out: *std.ArrayList(u8), serial: u32, seq: *u32, packets: []const []const u8) !void {
    var lacing: std.ArrayList(u8) = .empty;
    var body: std.ArrayList(u8) = .empty;
    var continued = false;
    var ends_packet = false;
    const flush = struct {
        fn f(g: Allocator, o: *std.ArrayList(u8), ser: u32, sq: *u32, lac: *std.ArrayList(u8), bd: *std.ArrayList(u8), cont: bool, ends: bool) !void {
            const start = o.items.len;
            try o.appendSlice(g, "OggS");
            try o.append(g, 0);
            try o.append(g, if (cont) 1 else 0);
            var gran: [8]u8 = undefined;
            std.mem.writeInt(i64, &gran, if (ends) 0 else -1, .little);
            try o.appendSlice(g, &gran);
            var b4: [4]u8 = undefined;
            std.mem.writeInt(u32, &b4, ser, .little);
            try o.appendSlice(g, &b4);
            std.mem.writeInt(u32, &b4, sq.*, .little);
            try o.appendSlice(g, &b4);
            try o.appendSlice(g, &.{ 0, 0, 0, 0 });
            try o.append(g, @intCast(lac.items.len));
            try o.appendSlice(g, lac.items);
            try o.appendSlice(g, bd.items);
            setOggCrc(o.items[start..]);
            sq.* += 1;
            lac.clearRetainingCapacity();
            bd.clearRetainingCapacity();
        }
    }.f;
    for (packets) |p| {
        var off: usize = 0;
        while (true) {
            const n = @min(255, p.len - off);
            try lacing.append(gpa, @intCast(n));
            try body.appendSlice(gpa, p[off .. off + n]);
            off += n;
            const done = n < 255;
            if (done) ends_packet = true;
            if (lacing.items.len == 255) {
                try flush(gpa, out, serial, seq, &lacing, &body, continued, ends_packet);
                continued = !done;
                ends_packet = false;
            }
            if (done) break;
        }
    }
    if (lacing.items.len > 0) try flush(gpa, out, serial, seq, &lacing, &body, continued, ends_packet);
}

fn writeOgg(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, fields: []const Field, cover: Cover, img: ?Image) !void {
    const s = try Source.open(io, dir, path);
    defer s.close();

    // Header-Seiten lesen, bis alle Header-Pakete vollständig sind.
    var packets: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var needed: ?u64 = null;
    var pos: u64 = 0;
    var pages: u32 = 0;
    var first_page_end: u64 = 0;
    var serial: u32 = 0;
    while (needed == null or packets.items.len < needed.?) {
        if (pos + 27 > s.len) return error.InvalidOgg;
        var hdr: [27]u8 = undefined;
        try s.readExactAt(&hdr, pos);
        if (!std.mem.eql(u8, hdr[0..4], "OggS")) return error.InvalidOgg;
        const ser = std.mem.readInt(u32, hdr[14..18], .little);
        if (pages == 0) serial = ser else if (ser != serial) return error.UnsupportedFormat; // gemultiplext
        const nseg: usize = hdr[26];
        var lacing: [255]u8 = undefined;
        try s.readExactAt(lacing[0..nseg], pos + 27);
        var body_len: usize = 0;
        for (lacing[0..nseg]) |l| body_len += l;
        const body = try s.alloc(gpa, pos + 27 + nseg, body_len);
        var off: usize = 0;
        for (lacing[0..nseg], 0..) |l, i| {
            if (needed != null and packets.items.len >= needed.?) {
                _ = i;
                return error.UnsupportedFormat; // Audio auf einer Header-Seite
            }
            try cur.appendSlice(gpa, body[off .. off + l]);
            off += l;
            if (l < 255) {
                const pkt = try cur.toOwnedSlice(gpa);
                if (packets.items.len == 0) needed = try ogg.headerCount(pkt);
                try packets.append(gpa, pkt);
            }
        }
        pos += 27 + nseg + body_len;
        pages += 1;
        if (pages == 1) {
            if (packets.items.len != 1 or cur.items.len != 0) return error.InvalidOgg;
            first_page_end = pos;
        }
    }
    if (cur.items.len != 0) return error.UnsupportedFormat;
    const codec = try ogg.codecOf(packets.items[0]);
    const old = packets.items[1];
    const prefix: []const u8 = switch (codec) {
        .vorbis => "\x03vorbis",
        .opus => "OpusTags",
        .flac => return error.UnsupportedFormat,
    };
    if (!std.mem.startsWith(u8, old, prefix)) return error.InvalidOgg;
    const pic: ?[]const u8 = if (img) |im| try flacPicture(gpa, im) else null;
    const vc = try buildVorbisComment(gpa, old[prefix.len..], fields, cover.changes(), pic);
    var comment: std.ArrayList(u8) = .empty;
    try comment.appendSlice(gpa, prefix);
    try comment.appendSlice(gpa, vc);
    if (codec == .vorbis) try comment.append(gpa, 1); // Framing-Bit

    var head: std.ArrayList(u8) = .empty;
    try head.appendSlice(gpa, try s.alloc(gpa, 0, first_page_end));
    var seq: u32 = 1;
    var rest: std.ArrayList([]const u8) = .empty;
    try rest.append(gpa, comment.items);
    try rest.appendSlice(gpa, packets.items[2..]);
    try paginate(gpa, &head, serial, &seq, rest.items);
    const delta = seq -% pages;
    const tail: Piece = if (delta == 0)
        .{ .copy = .{ .from = pos, .to = s.len } }
    else
        .{ .ogg = .{ .from = pos, .delta = delta } };
    try rewritePieces(gpa, io, dir, path, s, &.{ .{ .bytes = head.items }, tail });
}

// ───────────────────────────── MP4 / M4A ───────────────────────────────────

const mp4_text = [_][2][]const u8{
    .{ "title", "\xa9nam" },     .{ "artist", "\xa9ART" },  .{ "album", "\xa9alb" },
    .{ "albumartist", "aART" },  .{ "composer", "\xa9wrt" }, .{ "genre", "\xa9gen" },
    .{ "date", "\xa9day" },      .{ "comment", "\xa9cmt" }, .{ "lyrics", "\xa9lyr" },
};

const mp4_managed = std.StaticStringMap(void).initComptime(.{
    .{"\xa9nam"}, .{"\xa9ART"}, .{"\xa9alb"}, .{"aART"}, .{"\xa9wrt"}, .{"\xa9gen"},
    .{"gnre"},    .{"\xa9day"}, .{"\xa9cmt"}, .{"\xa9lyr"}, .{"trkn"}, .{"disk"},
    .{"desc"},    .{"ldes"},
});

fn appendBox(gpa: Allocator, out: *std.ArrayList(u8), typ: []const u8, parts: []const []const u8) !void {
    var len: usize = 8;
    for (parts) |p| len += p.len;
    if (len > std.math.maxInt(u32)) return error.BoxTooLarge;
    try appendU32Be(gpa, out, @intCast(len));
    try out.appendSlice(gpa, typ);
    for (parts) |p| try out.appendSlice(gpa, p);
}

fn mp4Item(gpa: Allocator, out: *std.ArrayList(u8), typ: []const u8, kind: u32, values: []const []const u8) !void {
    var datas: std.ArrayList(u8) = .empty;
    for (values) |v| {
        var k: [8]u8 = @splat(0);
        std.mem.writeInt(u32, k[0..4], kind, .big);
        try appendBox(gpa, &datas, "data", &.{ &k, v });
    }
    try appendBox(gpa, out, typ, &.{datas.items});
}

fn mp4Number(gpa: Allocator, out: *std.ArrayList(u8), typ: []const u8, n: ?[]const u8, total: ?[]const u8, len: usize) !void {
    if (n == null and total == null) return;
    var b: [8]u8 = @splat(0);
    const nv = if (n) |x| std.fmt.parseInt(u16, x, 10) catch 0 else 0;
    const tv = if (total) |x| std.fmt.parseInt(u16, x, 10) catch 0 else 0;
    std.mem.writeInt(u16, b[2..4], nv, .big);
    std.mem.writeInt(u16, b[4..6], tv, .big);
    try mp4Item(gpa, out, typ, 0, &.{b[0..len]});
}

/// UTF-8 auf höchstens `max` Bytes kürzen, ohne ein Zeichen zu zerschneiden.
fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var e = max;
    while (e > 0 and s[e] & 0xc0 == 0x80) e -= 1;
    return s[0..e];
}

fn buildIlst(gpa: Allocator, old: ?[]const u8, fields: []const Field, cover: Cover, img: ?Image) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (mp4_text) |m| if (get(fields, m[0])) |v| try mp4Item(gpa, &out, m[1], 1, v);
    try mp4Number(gpa, &out, "trkn", first(fields, "track"), first(fields, "tracktotal"), 8);
    try mp4Number(gpa, &out, "disk", first(fields, "disc"), first(fields, "disctotal"), 6);
    if (first(fields, "description")) |d| {
        try mp4Item(gpa, &out, "desc", 1, &.{utf8Prefix(d, 255)});
        if (d.len > 255) try mp4Item(gpa, &out, "ldes", 1, &.{d});
    }
    if (old) |o| {
        var it: MemIter = .{ .data = o };
        while (it.next()) |a| {
            if (mp4_managed.has(a.typ)) continue;
            if (cover.changes() and std.mem.eql(u8, a.typ, "covr")) continue;
            try out.appendSlice(gpa, a.raw);
        }
    }
    if (img) |im| try mp4Item(gpa, &out, "covr", if (std.mem.eql(u8, im.mime, "image/png")) 14 else 13, &.{im.data});
    return out.items;
}

/// Kind-Boxen in einem Speicherbereich (mit Kopf, für unverändertes Kopieren).
const MemIter = struct {
    data: []const u8,
    pos: usize = 0,

    const Box = struct { typ: []const u8, raw: []const u8, body: []const u8, body_off: usize };

    fn next(it: *MemIter) ?Box {
        if (it.pos + 8 > it.data.len) return null;
        var size: u64 = src_mod.readU32Be(it.data[it.pos..]);
        var header: usize = 8;
        if (size == 1) {
            if (it.pos + 16 > it.data.len) return null;
            size = src_mod.readU64Be(it.data[it.pos + 8 ..]);
            header = 16;
        } else if (size == 0) size = it.data.len - it.pos;
        if (size < header or size > it.data.len - it.pos) return null;
        const start = it.pos;
        const end = start + @as(usize, @intCast(size));
        it.pos = end;
        return .{ .typ = it.data[start + 4 .. start + 8], .raw = it.data[start..end], .body = it.data[start + header .. end], .body_off = start + header };
    }
};

fn buildMeta(gpa: Allocator, old: ?[]const u8, fields: []const Field, cover: Cover, img: ?Image) ![]u8 {
    var children: std.ArrayList(u8) = .empty;
    var full: []const u8 = &.{ 0, 0, 0, 0 };
    var body: []const u8 = &.{};
    if (old) |m| {
        body = m;
        if (!(m.len >= 8 and std.mem.eql(u8, m[4..8], "hdlr")) and m.len >= 4) {
            full = m[0..4];
            body = m[4..];
        } else full = &.{};
    }
    var old_ilst: ?[]const u8 = null;
    var has_hdlr = false;
    var it: MemIter = .{ .data = body };
    while (it.next()) |a| {
        if (std.mem.eql(u8, a.typ, "ilst")) {
            old_ilst = a.body;
            continue;
        }
        if (std.mem.eql(u8, a.typ, "free") or std.mem.eql(u8, a.typ, "skip")) continue;
        if (std.mem.eql(u8, a.typ, "hdlr")) has_hdlr = true;
        try children.appendSlice(gpa, a.raw);
    }
    var out: std.ArrayList(u8) = .empty;
    if (!has_hdlr) {
        try appendBox(gpa, &out, "hdlr", &.{"\x00\x00\x00\x00\x00\x00\x00\x00mdirappl\x00\x00\x00\x00\x00\x00\x00\x00\x00"});
    }
    try out.appendSlice(gpa, children.items);
    try appendBox(gpa, &out, "ilst", &.{try buildIlst(gpa, old_ilst, fields, cover, img)});
    var meta: std.ArrayList(u8) = .empty;
    try appendBox(gpa, &meta, "meta", &.{ full, out.items });
    return meta.items;
}

fn buildMoov(gpa: Allocator, moov_body: []const u8, fields: []const Field, cover: Cover, img: ?Image) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var udta_done = false;
    var it: MemIter = .{ .data = moov_body };
    while (it.next()) |a| {
        if (!std.mem.eql(u8, a.typ, "udta")) {
            try out.appendSlice(gpa, a.raw);
            continue;
        }
        if (udta_done) continue;
        udta_done = true;
        try out.appendSlice(gpa, try buildUdta(gpa, a.body, fields, cover, img));
    }
    if (it.pos != moov_body.len) return error.InvalidMp4;
    if (!udta_done) try out.appendSlice(gpa, try buildUdta(gpa, null, fields, cover, img));
    var moov: std.ArrayList(u8) = .empty;
    try appendBox(gpa, &moov, "moov", &.{out.items});
    return moov.items;
}

fn buildUdta(gpa: Allocator, old: ?[]const u8, fields: []const Field, cover: Cover, img: ?Image) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var meta_done = false;
    if (old) |u| {
        var it: MemIter = .{ .data = u };
        while (it.next()) |a| {
            if (std.mem.eql(u8, a.typ, "meta")) {
                if (!meta_done) try out.appendSlice(gpa, try buildMeta(gpa, a.body, fields, cover, img));
                meta_done = true;
            } else try out.appendSlice(gpa, a.raw);
        }
    }
    if (!meta_done) try out.appendSlice(gpa, try buildMeta(gpa, null, fields, cover, img));
    var udta: std.ArrayList(u8) = .empty;
    try appendBox(gpa, &udta, "udta", &.{out.items});
    return udta.items;
}

/// Verschiebt alle Chunk-Offsets (stco/co64) ab `threshold` um `delta`.
fn shiftChunkOffsets(buf: []u8, threshold: u64, delta: i64) !void {
    var it: MemIter = .{ .data = buf };
    while (it.next()) |a| {
        const body = buf[a.body_off .. a.body_off + a.body.len];
        if (std.mem.eql(u8, a.typ, "trak") or std.mem.eql(u8, a.typ, "mdia") or
            std.mem.eql(u8, a.typ, "minf") or std.mem.eql(u8, a.typ, "stbl"))
        {
            try shiftChunkOffsets(body, threshold, delta);
        } else if (std.mem.eql(u8, a.typ, "stco") or std.mem.eql(u8, a.typ, "co64")) {
            if (body.len < 8) return error.InvalidMp4;
            const n = src_mod.readU32Be(body[4..8]);
            const w: usize = if (a.typ[0] == 's') 4 else 8;
            if (8 + @as(u64, n) * w > body.len) return error.InvalidMp4;
            for (0..n) |i| {
                const p = 8 + i * w;
                const v: u64 = if (w == 4) src_mod.readU32Be(body[p..]) else src_mod.readU64Be(body[p..]);
                if (v < threshold) continue;
                const nv: u64 = @intCast(@as(i64, @intCast(v)) + delta);
                if (w == 4) {
                    if (nv > std.math.maxInt(u32)) return error.UnsupportedFormat;
                    std.mem.writeInt(u32, body[p..][0..4], @intCast(nv), .big);
                } else std.mem.writeInt(u64, body[p..][0..8], nv, .big);
            }
        }
    }
}

fn freeBox(gpa: Allocator, len: u64) ![]u8 {
    const b = try gpa.alloc(u8, @intCast(len));
    @memset(b, 0);
    std.mem.writeInt(u32, b[0..4], @intCast(len), .big);
    @memcpy(b[4..8], "free");
    return b;
}

fn writeMp4(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, fields: []const Field, cover: Cover, img: ?Image) !void {
    const s = try Source.open(io, dir, path);
    var closed = false;
    defer if (!closed) s.close();

    var head: [8]u8 = undefined;
    if (try s.readAt(&head, 0) != 8 or !std.mem.eql(u8, head[4..8], "ftyp")) return error.UnsupportedFormat;
    var moov: ?audiohash.Atom = null;
    var region_end: u64 = 0;
    var mdat_after = false;
    var fragmented = false;
    var pos: u64 = 0;
    while (pos + 8 <= s.len) {
        const a = try audiohash.readAtom(s, pos, s.len);
        if (std.mem.eql(u8, &a.typ, "moov")) {
            moov = a;
            region_end = a.start + a.size;
        } else if (moov != null and region_end == a.start and
            (std.mem.eql(u8, &a.typ, "free") or std.mem.eql(u8, &a.typ, "skip")))
        {
            region_end = a.start + a.size;
        }
        if (moov != null and std.mem.eql(u8, &a.typ, "mdat")) mdat_after = true;
        if (std.mem.eql(u8, &a.typ, "moof")) fragmented = true;
        pos += a.size;
    }
    const mv = moov orelse return error.InvalidMp4;
    if (mv.header != 8) return error.UnsupportedFormat;
    const old_body = try s.alloc(gpa, mv.start + 8, mv.size - 8);
    const new_moov = try buildMoov(gpa, old_body, fields, cover, img);
    const old_region = region_end - mv.start;

    if (new_moov.len == old_region or new_moov.len + 8 <= old_region) {
        // In-place: Rest des alten Bereichs wird „free“
        s.close();
        closed = true;
        const f = try dir.openFile(io, path, .{ .mode = .read_write });
        defer f.close(io);
        if (new_moov.len < old_region) {
            try f.writePositionalAll(io, try freeBox(gpa, old_region - new_moov.len), mv.start + new_moov.len);
        }
        try f.writePositionalAll(io, new_moov, mv.start);
        try f.sync(io);
        return;
    }
    const padding: u64 = 1024;
    const new_region = new_moov.len + padding;
    if (mdat_after) {
        if (fragmented) return error.UnsupportedFormat;
        const delta: i64 = @as(i64, @intCast(new_region)) - @as(i64, @intCast(old_region));
        try shiftChunkOffsets(new_moov[8..], region_end, delta);
    }
    try rewritePieces(gpa, io, dir, path, s, &.{
        .{ .copy = .{ .from = 0, .to = mv.start } },
        .{ .bytes = new_moov },
        .{ .bytes = try freeBox(gpa, padding) },
        .{ .copy = .{ .from = region_end, .to = s.len } },
    });
}

// ───────────────────────────── WAV ─────────────────────────────────────────

const Chunk = struct { id: [4]u8, start: u64, size: u64, end: u64 };

const info_managed = std.StaticStringMap(void).initComptime(.{
    .{"INAM"}, .{"IART"}, .{"IPRD"}, .{"ICMT"}, .{"IGNR"}, .{"ICRD"}, .{"ITRK"}, .{"IPRT"},
});

/// LIST/INFO ohne die von mync verwalteten Einträge (null, wenn leer).
fn cleanInfo(gpa: Allocator, body: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    var p: usize = 4;
    while (p + 8 <= body.len) {
        const len = src_mod.readU32Le(body[p + 4 ..]);
        if (len > body.len - p - 8) break;
        const end = @min(body.len, p + 8 + len + (len & 1));
        if (!info_managed.has(body[p .. p + 4])) try out.appendSlice(gpa, body[p..end]);
        p = end;
    }
    if (out.items.len == 0) return null;
    var chunk: std.ArrayList(u8) = .empty;
    try chunk.appendSlice(gpa, "LIST");
    try appendU32Le(gpa, &chunk, 4 + out.items.len);
    try chunk.appendSlice(gpa, "INFO");
    try chunk.appendSlice(gpa, out.items);
    return chunk.items;
}

fn writeWav(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, fields: []const Field, cover: Cover, img: ?Image) !void {
    const s = try Source.open(io, dir, path);
    var closed = false;
    defer if (!closed) s.close();

    var riff: [12]u8 = undefined;
    try s.readExactAt(&riff, 0);
    if (!std.mem.eql(u8, riff[0..4], "RIFF") or !std.mem.eql(u8, riff[8..12], "WAVE")) return error.InvalidWav;
    var chunks: std.ArrayList(Chunk) = .empty;
    var pos: u64 = 12;
    var data_idx: ?usize = null;
    while (pos + 8 <= s.len) {
        var hdr: [8]u8 = undefined;
        try s.readExactAt(&hdr, pos);
        const size: u64 = src_mod.readU32Le(hdr[4..8]);
        const end = @min(s.len, pos + 8 + size + (size & 1));
        if (std.mem.eql(u8, hdr[0..4], "data")) data_idx = chunks.items.len;
        try chunks.append(gpa, .{ .id = hdr[0..4].*, .start = pos, .size = size, .end = end });
        pos = end;
    }
    const di = data_idx orelse return error.NoDataChunk;

    // Neue Teile: alte id3-Chunks fallen weg, LIST/INFO wird bereinigt.
    var old_id3: ?[]const u8 = null;
    const Repl = union(enum) { keep, drop, bytes: []const u8 };
    const repl = try gpa.alloc(Repl, chunks.items.len);
    for (chunks.items, repl) |c, *r| {
        r.* = .keep;
        if (std.ascii.eqlIgnoreCase(&c.id, "id3 ")) {
            if (old_id3 == null) old_id3 = try s.alloc(gpa, c.start + 8, @min(c.size, s.len - c.start - 8));
            r.* = .drop;
        } else if (std.mem.eql(u8, &c.id, "LIST") and c.size >= 4) {
            const body = try s.alloc(gpa, c.start + 8, @min(c.size, s.len - c.start - 8));
            if (std.mem.eql(u8, body[0..4], "INFO")) {
                r.* = if (try cleanInfo(gpa, body)) |b| .{ .bytes = b } else .drop;
            }
        }
    }
    const tag = try buildId3(gpa, old_id3, fields, cover, img, 0);
    var id3_chunk: std.ArrayList(u8) = .empty;
    try id3_chunk.appendSlice(gpa, "id3 ");
    try appendU32Le(gpa, &id3_chunk, tag.len);
    try id3_chunk.appendSlice(gpa, tag);
    if (tag.len & 1 == 1) try id3_chunk.append(gpa, 0);

    // Ab dem ersten geänderten Chunk neu schreiben. Liegt der hinter den
    // Audiodaten, geht das ohne die Datei zu kopieren.
    var first_changed: usize = chunks.items.len;
    for (repl, 0..) |r, i| if (r != .keep) {
        first_changed = i;
        break;
    };
    var tail: std.ArrayList(Piece) = .empty;
    for (chunks.items[first_changed..], repl[first_changed..]) |c, r| switch (r) {
        .keep => try tail.append(gpa, .{ .copy = .{ .from = c.start, .to = c.end } }),
        .drop => {},
        .bytes => |b| try tail.append(gpa, .{ .bytes = b }),
    };
    try tail.append(gpa, .{ .bytes = id3_chunk.items });
    const tail_start = if (first_changed < chunks.items.len) chunks.items[first_changed].start else pos;
    var new_len: u64 = tail_start;
    for (tail.items) |p| new_len += switch (p) {
        .bytes => |b| b.len,
        .copy => |c| c.to - c.from,
        .ogg => unreachable,
    };
    if (new_len - 8 > std.math.maxInt(u32)) return error.UnsupportedFormat;
    var size_hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &size_hdr, @intCast(new_len - 8), .little);

    if (first_changed > di) {
        // Nachspann im Speicher zusammensetzen und direkt schreiben
        var buf: std.ArrayList(u8) = .empty;
        for (tail.items) |p| switch (p) {
            .bytes => |b| try buf.appendSlice(gpa, b),
            .copy => |c| try buf.appendSlice(gpa, try s.alloc(gpa, c.from, c.to - c.from)),
            .ogg => unreachable,
        };
        s.close();
        closed = true;
        const f = try dir.openFile(io, path, .{ .mode = .read_write });
        defer f.close(io);
        try f.writePositionalAll(io, buf.items, tail_start);
        try f.setLength(io, new_len);
        try f.writePositionalAll(io, &size_hdr, 4);
        try f.sync(io);
        return;
    }
    var pieces: std.ArrayList(Piece) = .empty;
    try pieces.append(gpa, .{ .bytes = "RIFF" });
    try pieces.append(gpa, .{ .bytes = &size_hdr });
    try pieces.append(gpa, .{ .copy = .{ .from = 8, .to = tail_start } });
    try pieces.appendSlice(gpa, tail.items);
    try rewritePieces(gpa, io, dir, path, s, pieces.items);
}

// ───────────────────────────── Tests ───────────────────────────────────────

const testing = std.testing;

// comptime: sonst zeigt `values` auf ein Array im Stack dieser Funktion
fn field(comptime name: []const u8, comptime v: []const u8) Field {
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
        try fields.append(a, .{ .name = "lyrics", .values = try a.dupe([]const u8, &.{long}) });
    }
    try writeFile(a, testing.io, tmp.dir, name, fields.items, .keep);

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
    for ([_][]const u8{ "mp3-chapters.mp3", "flac-chapters.flac", "m4a-chapters.m4a", "opus-chapters.opus", "vorbis-chapters.ogg" }) |name| {
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
        try writeFile(a, testing.io, tmp.dir, name, &new_fields, .keep);
        const after = try tags.readFile(a, testing.io, tmp.dir, name);
        try testing.expectEqual(@as(usize, 3), after.chapters.len);
        try testing.expectEqualStrings("Hauptteil – Ärger", after.chapters[1].title);
        try testing.expectEqual(@as(u64, 150), after.chapters[1].start_ms);
    }
}

test "nicht unterstützte Formate" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnsupportedFormat, writeFile(arena.allocator(), testing.io, Io.Dir.cwd(), "x.wma", &.{}, .keep));
    try testing.expectError(error.UnsupportedImage, writeFile(arena.allocator(), testing.io, Io.Dir.cwd(), "x.mp3", &.{}, .{ .set = "GIF89a" }));
}

test "Ogg Vorbis/Opus: Kommentar-Paket neu, Seiten neu nummeriert" {
    for ([_][]const u8{ "opus-tagged.opus", "opus-retagged.opus", "opus-plain.opus", "vorbis-tagged.ogg", "vorbis-retagged.ogg", "vorbis-plain.ogg" }) |n| {
        try checkRoundtrip(n, false);
        try checkRoundtrip(n, true);
    }
}

test "MP4: ilst in-place und mit Neuschreiben (Chunk-Offsets)" {
    for ([_][]const u8{ "m4a-tagged.m4a", "m4a-retagged.m4a", "m4a-plain.m4a", "m4a-description.m4a" }) |n| {
        try checkRoundtrip(n, false);
        try checkRoundtrip(n, true);
    }
}

test "WAV: id3-Chunk" {
    for ([_][]const u8{ "wav-tagged.wav", "wav-retagged.wav", "wav-plain.wav" }) |n| {
        try checkRoundtrip(n, false);
        try checkRoundtrip(n, true);
    }
}

/// Minimales PNG (nur Kopf und ein paar Bytes – reicht für Tags).
const fake_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x20\x00\x00\x00\x10\x08\x02\x00\x00\x00" ++ "bilddaten-bilddaten-bilddaten-bilddaten-bilddaten-bilddaten-bilddaten-bilddaten";

test "Cover setzen, ersetzen und entfernen (alle Formate)" {
    const names = [_][]const u8{ "mp3-tagged.mp3", "mp3-plain.mp3", "flac-tagged.flac", "flac-plain.flac", "opus-tagged.opus", "vorbis-plain.ogg", "m4a-tagged.m4a", "m4a-plain.m4a", "wav-tagged.wav", "wav-plain.wav" };
    for (names) |name| {
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

        try writeFile(a, testing.io, tmp.dir, name, &new_fields, .{ .set = fake_png });
        var got = try tags.readFile(a, testing.io, tmp.dir, name);
        try testing.expectEqual(@as(usize, 1), got.pictures.len);
        try testing.expectEqualSlices(u8, fake_png, got.first_picture.?);
        try testing.expectEqualStrings("Album", got.get("album").?[0]);

        // Nur Felder ändern: Cover bleibt
        try writeFile(a, testing.io, tmp.dir, name, &.{field("title", "Nur Titel")}, .keep);
        got = try tags.readFile(a, testing.io, tmp.dir, name);
        try testing.expectEqual(@as(usize, 1), got.pictures.len);
        try testing.expect(got.get("album") == null);

        try writeFile(a, testing.io, tmp.dir, name, &new_fields, .remove);
        got = try tags.readFile(a, testing.io, tmp.dir, name);
        try testing.expectEqual(@as(usize, 0), got.pictures.len);
        const after = try audiohash.hashFile(testing.io, tmp.dir, name);
        try testing.expectEqualStrings(&before.hash, &after.hash);
    }
}

test "Bildgröße aus PNG und JPEG" {
    const p = try imageInfo(fake_png);
    try testing.expectEqual(@as(u32, 32), p.width);
    try testing.expectEqual(@as(u32, 16), p.height);
    const jpg = "\xff\xd8\xff\xe0\x00\x04ab\xff\xc0\x00\x11\x08\x00\x40\x00\x80\x03rest";
    const j = try imageInfo(jpg);
    try testing.expectEqualStrings("image/jpeg", j.mime);
    try testing.expectEqual(@as(u32, 128), j.width);
    try testing.expectEqual(@as(u32, 64), j.height);
}
