//! Normalisierte Tags und `tag_hash`.
//!
//! Liest Tags aus ID3v2 (2.2/2.3/2.4), ID3v1, Vorbis Comments (FLAC, Ogg
//! Vorbis/Opus/FLAC), MP4-`ilst` und WAV (`id3 `-Chunk bzw. `LIST/INFO`) und
//! bildet sie auf feste Feldnamen ab (ID3 `TIT2`, Vorbis `TITLE`, MP4 `©nam`
//! → `title`). Werte werden normalisiert und sortiert; der `tag_hash` ist
//! SHA-256 über die JSON-Darstellung plus die Hashes eingebetteter Bilder.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const src_mod = @import("source.zig");
const Source = src_mod.Source;
const ogg = @import("ogg.zig");
const audiohash = @import("audiohash.zig");

/// Alle unterstützten Feldnamen, alphabetisch.
pub const field_names = [_][]const u8{
    "album",  "albumartist", "artist", "comment", "composer", "date",  "disc",
    "disctotal", "genre", "lyrics", "title", "track", "tracktotal",
};

pub const Field = struct {
    name: []const u8,
    values: []const []const u8,
};

/// Ergebnis: Felder alphabetisch sortiert, Werte sortiert und ohne Duplikate.
/// Der gesamte Speicher gehört dem beim Lesen übergebenen (Arena-)Allocator.
pub const Tags = struct {
    fields: []const Field = &.{},
    /// SHA-256 (hex) je eingebettetem Bild, in Dateireihenfolge.
    pictures: []const [64]u8 = &.{},

    pub fn get(t: Tags, name: []const u8) ?[]const []const u8 {
        for (t.fields) |f| if (std.mem.eql(u8, f.name, name)) return f.values;
        return null;
    }

    /// Erster Wert eines Feldes, mehrere Werte mit „; “ verbunden.
    pub fn joined(t: Tags, gpa: Allocator, name: []const u8) !?[]u8 {
        const v = t.get(name) orelse return null;
        return try std.mem.join(gpa, "; ", v);
    }

    /// `{"fields":{"album":["Post"],…},"pictures":["…"]}`
    pub fn writeJson(t: Tags, w: *Io.Writer) !void {
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("fields");
        try s.beginObject();
        for (t.fields) |f| {
            try s.objectField(f.name);
            try s.write(f.values);
        }
        try s.endObject();
        try s.objectField("pictures");
        try s.beginArray();
        for (t.pictures) |p| try s.write(@as([]const u8, &p));
        try s.endArray();
        try s.endObject();
    }

    pub fn hash(t: Tags) ![64]u8 {
        var buf: [4096]u8 = undefined;
        var hw = Sha256Writer.init(&buf);
        try t.writeJson(&hw.writer);
        try hw.writer.flush();
        var out: [32]u8 = undefined;
        hw.sha.final(&out);
        return std.fmt.bytesToHex(out, .lower);
    }
};

/// Io.Writer, der alles in einen SHA-256 schreibt.
const Sha256Writer = struct {
    sha: Sha256 = .init(.{}),
    writer: Io.Writer,

    fn init(buf: []u8) Sha256Writer {
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buf } };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Sha256Writer = @alignCast(@fieldParentPtr("writer", w));
        self.sha.update(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            self.sha.update(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| self.sha.update(last);
        return n + last.len * splat;
    }
};

// ───────────────────────────── Sammeln & Normalisieren ─────────────────────

const Builder = struct {
    gpa: Allocator,
    map: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    pictures: std.ArrayList([64]u8) = .empty,

    fn add(b: *Builder, name: []const u8, raw: []const u8) !void {
        if (std.mem.eql(u8, name, "track") or std.mem.eql(u8, name, "disc")) {
            // "2/11" → track=2, tracktotal=11
            if (std.mem.indexOfScalar(u8, raw, '/')) |i| {
                try b.addOne(name, raw[0..i]);
                const total = if (name[0] == 't') "tracktotal" else "disctotal";
                try b.addOne(total, raw[i + 1 ..]);
                return;
            }
        }
        try b.addOne(name, raw);
    }

    fn addOne(b: *Builder, name: []const u8, raw: []const u8) !void {
        const v = try normalize(b.gpa, name, raw) orelse return;
        const gop = try b.map.getOrPut(b.gpa, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(b.gpa, v);
    }

    fn addPicture(b: *Builder, data: []const u8) !void {
        var out: [32]u8 = undefined;
        Sha256.hash(data, &out, .{});
        try b.pictures.append(b.gpa, std.fmt.bytesToHex(out, .lower));
    }

    fn isEmpty(b: *const Builder) bool {
        return b.map.count() == 0 and b.pictures.items.len == 0;
    }

    fn finish(b: *Builder) !Tags {
        const Ctx = struct {
            keys: [][]const u8,
            pub fn lessThan(c: @This(), a: usize, x: usize) bool {
                return std.mem.lessThan(u8, c.keys[a], c.keys[x]);
            }
        };
        b.map.sort(Ctx{ .keys = b.map.keys() });
        var fields: std.ArrayList(Field) = .empty;
        for (b.map.keys(), b.map.values()) |k, *vals| {
            std.mem.sort([]const u8, vals.items, {}, struct {
                fn lt(_: void, a: []const u8, x: []const u8) bool {
                    return std.mem.lessThan(u8, a, x);
                }
            }.lt);
            var out: std.ArrayList([]const u8) = .empty;
            for (vals.items) |v| {
                if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1], v)) continue;
                try out.append(b.gpa, v);
            }
            try fields.append(b.gpa, .{ .name = k, .values = out.items });
        }
        return .{ .fields = fields.items, .pictures = b.pictures.items };
    }
};

/// Entfernt Steuerzeichen (außer Zeilenumbruch), vereinheitlicht CRLF, trimmt.
/// Nummern (track, disc, …) werden ohne führende Nullen geschrieben; „0“ fällt weg.
fn normalize(gpa: Allocator, name: []const u8, raw: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\r' and i + 1 < raw.len and raw[i + 1] == '\n') continue;
        if ((c < 0x20 and c != '\n') or c == 0x7f) continue;
        try out.append(gpa, c);
    }
    const t = std.mem.trim(u8, out.items, " \t\n");
    if (t.len == 0) return null;
    if (isNumberField(name)) {
        const n = std.fmt.parseInt(u32, t, 10) catch return t;
        if (n == 0) return null;
        return try std.fmt.allocPrint(gpa, "{d}", .{n});
    }
    return t;
}

fn isNumberField(name: []const u8) bool {
    for ([_][]const u8{ "track", "tracktotal", "disc", "disctotal" }) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

// ───────────────────────────── Einstieg ────────────────────────────────────

/// Liest die Tags einer Datei. Speicher gehört `gpa` (am besten eine Arena).
/// Dateien ohne Tags oder unbekannte Formate liefern leere Tags.
pub fn readFile(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) !Tags {
    const s = try Source.open(io, dir, path);
    defer s.close();
    return readSource(gpa, s, audiohash.Format.fromPath(path));
}

pub fn readSource(gpa: Allocator, s: Source, format: audiohash.Format) !Tags {
    var b: Builder = .{ .gpa = gpa };
    switch (format) {
        .mp3 => {
            if (try audiohash.id3v2Len(s, 0) > 0) {
                const data = try s.alloc(gpa, 0, @min(try audiohash.id3v2Len(s, 0), s.len));
                try parseId3v2(&b, data);
            }
            if (b.isEmpty()) try parseId3v1(&b, s);
        },
        .flac => try readFlac(&b, s),
        .ogg => try readOgg(&b, s),
        .mp4 => try readMp4(&b, s),
        .wav => try readWav(&b, s),
        .other => {},
    }
    return b.finish();
}

// ───────────────────────────── ID3v2 ───────────────────────────────────────

fn id3Field(id: []const u8) ?[]const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "TIT2", "title" }, .{ "TPE1", "artist" },      .{ "TALB", "album" },
        .{ "TPE2", "albumartist" }, .{ "TCOM", "composer" }, .{ "TCON", "genre" },
        .{ "TDRC", "date" },  .{ "TYER", "date" },        .{ "TRCK", "track" },
        .{ "TPOS", "disc" },  .{ "TT2", "title" },        .{ "TP1", "artist" },
        .{ "TAL", "album" },  .{ "TP2", "albumartist" },  .{ "TCM", "composer" },
        .{ "TCO", "genre" },  .{ "TYE", "date" },         .{ "TRK", "track" },
        .{ "TPA", "disc" },
    });
    return map.get(id);
}

/// Entfernt die ID3-„Unsynchronisation“ (FF 00 → FF).
fn deunsync(gpa: Allocator, data: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(gpa, data.len);
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        out.appendAssumeCapacity(data[i]);
        if (data[i] == 0xff and i + 1 < data.len and data[i + 1] == 0) i += 1;
    }
    return out.items;
}

/// Parst ein komplettes ID3v2-Tag (inkl. 10-Byte-Header).
fn parseId3v2(b: *Builder, tag: []const u8) !void {
    if (tag.len < 10 or !std.mem.eql(u8, tag[0..3], "ID3")) return;
    const major = tag[3];
    const flags = tag[5];
    if (major < 2 or major > 4) return;
    const size = @min(src_mod.syncsafe(tag[6..10]), tag.len - 10);
    var body: []const u8 = tag[10 .. 10 + size];
    if (flags & 0x80 != 0 and major < 4) body = try deunsync(b.gpa, body);
    var pos: usize = 0;
    if (flags & 0x40 != 0 and major >= 3) {
        if (body.len < 4) return;
        pos = if (major == 3) 4 + src_mod.readU32Be(body[0..4]) else src_mod.syncsafe(body[0..4]);
    }
    const id_len: usize = if (major == 2) 3 else 4;
    const hdr_len: usize = if (major == 2) 6 else 10;
    while (pos + hdr_len <= body.len) {
        const id = body[pos .. pos + id_len];
        if (id[0] == 0) break; // Padding
        const fsize: usize = switch (major) {
            2 => std.mem.readInt(u24, body[pos + 3 ..][0..3], .big),
            3 => src_mod.readU32Be(body[pos + 4 ..]),
            else => src_mod.syncsafe(body[pos + 4 .. pos + 8]),
        };
        const fflags: u8 = if (major >= 3) body[pos + 9] else 0;
        pos += hdr_len;
        if (fsize > body.len - pos) break;
        var data: []const u8 = body[pos .. pos + fsize];
        pos += fsize;

        if (major == 4) {
            if (fflags & 0x0c != 0) continue; // komprimiert/verschlüsselt
            if (fflags & 0x02 != 0) data = try deunsync(b.gpa, data);
            if (fflags & 0x01 != 0) {
                if (data.len < 4) continue;
                data = data[4..];
            }
        } else if (major == 3) {
            if (fflags & 0xc0 != 0) continue;
            if (fflags & 0x20 != 0) {
                if (data.len < 1) continue;
                data = data[1..];
            }
        }
        try id3Frame(b, id, data);
    }
}

fn id3Frame(b: *Builder, id: []const u8, data: []const u8) !void {
    if (data.len < 1) return;
    if (id3Field(id)) |name| {
        const vals = try decodeStrings(b.gpa, data[0], data[1..]);
        for (vals) |v| {
            if (std.mem.eql(u8, name, "genre")) {
                try b.add(name, cleanGenre(v));
            } else {
                try b.add(name, v);
            }
        }
        return;
    }
    const is_comm = std.mem.eql(u8, id, "COMM") or std.mem.eql(u8, id, "COM");
    const is_uslt = std.mem.eql(u8, id, "USLT") or std.mem.eql(u8, id, "ULT");
    if (is_comm or is_uslt) {
        // Kodierung, Sprache (3), Beschreibung (terminiert), Text
        if (data.len < 4) return;
        const enc = data[0];
        const rest = data[4..];
        const desc_end = termEnd(enc, rest);
        const desc = try decodeText(b.gpa, enc, rest[0..desc_end.text_end]);
        const text = rest[desc_end.next..];
        if (is_comm and desc.len > 0) return; // z. B. iTunNORM – kein Nutzerkommentar
        const vals = try decodeStrings(b.gpa, enc, text);
        if (vals.len > 0) try b.add(if (is_comm) "comment" else "lyrics", vals[0]);
        return;
    }
    if (std.mem.eql(u8, id, "APIC")) {
        // Kodierung, MIME (latin1, NUL), Bildtyp, Beschreibung, Daten
        const enc = data[0];
        const mime_end = std.mem.indexOfScalarPos(u8, data, 1, 0) orelse return;
        if (mime_end + 2 > data.len) return;
        const rest = data[mime_end + 2 ..];
        const d = termEnd(enc, rest);
        try b.addPicture(rest[d.next..]);
        return;
    }
    if (std.mem.eql(u8, id, "PIC")) {
        if (data.len < 5) return;
        const rest = data[5..];
        const d = termEnd(data[0], rest);
        try b.addPicture(rest[d.next..]);
    }
}

/// „(17)Rock“ → „Rock“
fn cleanGenre(v: []const u8) []const u8 {
    if (v.len > 2 and v[0] == '(') {
        if (std.mem.indexOfScalar(u8, v, ')')) |i| {
            if (i + 1 < v.len) return v[i + 1 ..];
        }
    }
    return v;
}

const Term = struct { text_end: usize, next: usize };

/// Ende eines terminierten Strings in Kodierung `enc`.
fn termEnd(enc: u8, data: []const u8) Term {
    if (enc == 1 or enc == 2) {
        var i: usize = 0;
        while (i + 1 < data.len) : (i += 2) {
            if (data[i] == 0 and data[i + 1] == 0) return .{ .text_end = i, .next = i + 2 };
        }
        return .{ .text_end = data.len, .next = data.len };
    }
    const i = std.mem.indexOfScalar(u8, data, 0) orelse return .{ .text_end = data.len, .next = data.len };
    return .{ .text_end = i, .next = i + 1 };
}

/// Dekodiert einen (ggf. NUL-getrennten, mehrwertigen) ID3-Text nach UTF-8.
fn decodeStrings(gpa: Allocator, enc: u8, data: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var rest = data;
    while (rest.len > 0) {
        const t = termEnd(enc, rest);
        const s = try decodeText(gpa, enc, rest[0..t.text_end]);
        if (s.len > 0) try out.append(gpa, s);
        rest = rest[t.next..];
    }
    return out.items;
}

fn decodeText(gpa: Allocator, enc: u8, data: []const u8) ![]const u8 {
    switch (enc) {
        0 => return latin1ToUtf8(gpa, data),
        3 => return data,
        1, 2 => {
            var bytes = data;
            var big = enc == 2;
            if (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0xfe) {
                big = false;
                bytes = bytes[2..];
            } else if (bytes.len >= 2 and bytes[0] == 0xfe and bytes[1] == 0xff) {
                big = true;
                bytes = bytes[2..];
            }
            const units = try gpa.alloc(u16, bytes.len / 2);
            for (units, 0..) |*u, i| {
                const pair = bytes[2 * i ..][0..2];
                u.* = if (big) std.mem.readInt(u16, pair, .big) else std.mem.readInt(u16, pair, .little);
            }
            return std.unicode.utf16LeToUtf8Alloc(gpa, units) catch "";
        },
        else => return "",
    }
}

fn latin1ToUtf8(gpa: Allocator, data: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(gpa, data.len * 2);
    for (data) |c| {
        if (c < 0x80) {
            out.appendAssumeCapacity(c);
        } else {
            out.appendAssumeCapacity(0xc0 | (c >> 6));
            out.appendAssumeCapacity(0x80 | (c & 0x3f));
        }
    }
    return out.items;
}

// ───────────────────────────── ID3v1 ───────────────────────────────────────

fn parseId3v1(b: *Builder, s: Source) !void {
    if (s.len < 128) return;
    var t: [128]u8 = undefined;
    try s.readExactAt(&t, s.len - 128);
    if (!std.mem.eql(u8, t[0..3], "TAG")) return;
    const fields = [_]struct { []const u8, []const u8 }{
        .{ "title", t[3..33] }, .{ "artist", t[33..63] }, .{ "album", t[63..93] }, .{ "date", t[93..97] },
    };
    for (fields) |f| try b.add(f[0], try latin1ToUtf8(b.gpa, std.mem.sliceTo(f[1], 0)));
    const comment = t[97..127];
    if (comment[28] == 0 and comment[29] != 0) {
        try b.add("comment", try latin1ToUtf8(b.gpa, std.mem.sliceTo(comment[0..28], 0)));
        try b.add("track", try std.fmt.allocPrint(b.gpa, "{d}", .{comment[29]}));
    } else {
        try b.add("comment", try latin1ToUtf8(b.gpa, std.mem.sliceTo(comment, 0)));
    }
}

// ───────────────────────────── Vorbis Comments / FLAC ──────────────────────

fn vorbisField(key_upper: []const u8) ?[]const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "TITLE", "title" },         .{ "ARTIST", "artist" },         .{ "ALBUM", "album" },
        .{ "ALBUMARTIST", "albumartist" }, .{ "ALBUM ARTIST", "albumartist" },
        .{ "COMPOSER", "composer" },   .{ "GENRE", "genre" },           .{ "DATE", "date" },
        .{ "YEAR", "date" },           .{ "TRACKNUMBER", "track" },     .{ "TRACKTOTAL", "tracktotal" },
        .{ "TOTALTRACKS", "tracktotal" }, .{ "DISCNUMBER", "disc" },    .{ "DISCTOTAL", "disctotal" },
        .{ "TOTALDISCS", "disctotal" }, .{ "COMMENT", "comment" },      .{ "DESCRIPTION", "comment" },
        .{ "LYRICS", "lyrics" },       .{ "UNSYNCEDLYRICS", "lyrics" },
    });
    return map.get(key_upper);
}

/// Parst einen Vorbis-Comment-Block (ohne Codec-Präfix).
fn parseVorbisComment(b: *Builder, data: []const u8) !void {
    var pos: usize = 0;
    if (data.len < 8) return;
    const vendor_len = src_mod.readU32Le(data[0..4]);
    pos = 4 + vendor_len;
    if (pos + 4 > data.len) return;
    const count = src_mod.readU32Le(data[pos..]);
    pos += 4;
    var i: u32 = 0;
    while (i < count and pos + 4 <= data.len) : (i += 1) {
        const len = src_mod.readU32Le(data[pos..]);
        pos += 4;
        if (len > data.len - pos) return;
        const entry = data[pos .. pos + len];
        pos += len;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq > 64) continue;
        var kb: [64]u8 = undefined;
        const key = std.ascii.upperString(&kb, entry[0..eq]);
        const value = entry[eq + 1 ..];
        if (vorbisField(key)) |name| {
            try b.add(name, value);
        } else if (std.mem.eql(u8, key, "METADATA_BLOCK_PICTURE")) {
            const raw = base64Decode(b.gpa, value) catch continue;
            try parseFlacPicture(b, raw);
        } else if (std.mem.eql(u8, key, "COVERART")) {
            const raw = base64Decode(b.gpa, value) catch continue;
            try b.addPicture(raw);
        }
    }
}

fn base64Decode(gpa: Allocator, s: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const out = try gpa.alloc(u8, try dec.calcSizeForSlice(s));
    try dec.decode(out, s);
    return out;
}

/// FLAC-PICTURE-Block: nur die Bilddaten werden gehasht.
fn parseFlacPicture(b: *Builder, d: []const u8) !void {
    var pos: usize = 4; // Bildtyp
    if (pos + 4 > d.len) return;
    pos += 4 + src_mod.readU32Be(d[pos..]); // MIME
    if (pos + 4 > d.len) return;
    pos += 4 + src_mod.readU32Be(d[pos..]); // Beschreibung
    pos += 16; // Breite, Höhe, Farbtiefe, Farben
    if (pos + 4 > d.len) return;
    const len = src_mod.readU32Be(d[pos..]);
    pos += 4;
    if (len > d.len - pos) return;
    try b.addPicture(d[pos .. pos + len]);
}

fn readFlac(b: *Builder, s: Source) !void {
    var pos = try audiohash.id3v2Len(s, 0);
    var magic: [4]u8 = undefined;
    try s.readExactAt(&magic, pos);
    if (!std.mem.eql(u8, &magic, "fLaC")) return error.InvalidFlac;
    pos += 4;
    while (true) {
        var hdr: [4]u8 = undefined;
        try s.readExactAt(&hdr, pos);
        const typ = hdr[0] & 0x7f;
        const size = std.mem.readInt(u24, hdr[1..4], .big);
        if (typ == 4 or typ == 6) {
            const data = try s.alloc(b.gpa, pos + 4, size);
            if (typ == 4) try parseVorbisComment(b, data) else try parseFlacPicture(b, data);
        }
        pos += 4 + @as(u64, size);
        if (hdr[0] & 0x80 != 0) return;
    }
}

fn readOgg(b: *Builder, s: Source) !void {
    const r = try b.gpa.create(ogg.SegmentReader);
    r.* = ogg.SegmentReader.init(s);
    var pkt: std.ArrayList(u8) = .empty;
    if (!try r.nextPacket(b.gpa, &pkt)) return error.InvalidOgg;
    const codec = try ogg.codecOf(pkt.items);
    if (!try r.nextPacket(b.gpa, &pkt)) return;
    const p = pkt.items;
    switch (codec) {
        .vorbis => if (std.mem.startsWith(u8, p, "\x03vorbis")) try parseVorbisComment(b, p[7..]),
        .opus => if (std.mem.startsWith(u8, p, "OpusTags")) try parseVorbisComment(b, p[8..]),
        // Ogg-FLAC: Metadaten-Blöcke als Pakete, VORBIS_COMMENT zuerst
        .flac => if (p.len > 4 and p[0] & 0x7f == 4) try parseVorbisComment(b, p[4..]),
    }
}

// ───────────────────────────── MP4 ─────────────────────────────────────────

fn mp4Field(typ: []const u8) ?[]const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "\xa9nam", "title" },  .{ "\xa9ART", "artist" }, .{ "\xa9alb", "album" },
        .{ "aART", "albumartist" }, .{ "\xa9wrt", "composer" }, .{ "\xa9gen", "genre" },
        .{ "\xa9day", "date" },   .{ "\xa9cmt", "comment" }, .{ "\xa9lyr", "lyrics" },
    });
    return map.get(typ);
}

const MemAtom = struct { typ: []const u8, body: []const u8 };

/// Iteriert über Kind-Atome in einem Speicherbereich.
const AtomIter = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(it: *AtomIter) ?MemAtom {
        if (it.pos + 8 > it.data.len) return null;
        var size: u64 = src_mod.readU32Be(it.data[it.pos..]);
        var header: usize = 8;
        if (size == 1) {
            if (it.pos + 16 > it.data.len) return null;
            size = src_mod.readU64Be(it.data[it.pos + 8 ..]);
            header = 16;
        } else if (size == 0) {
            size = it.data.len - it.pos;
        }
        if (size < header or size > it.data.len - it.pos) return null;
        const a: MemAtom = .{
            .typ = it.data[it.pos + 4 .. it.pos + 8],
            .body = it.data[it.pos + header .. it.pos + @as(usize, @intCast(size))],
        };
        it.pos += @intCast(size);
        return a;
    }
};

fn findChild(data: []const u8, typ: []const u8) ?[]const u8 {
    var it: AtomIter = .{ .data = data };
    while (it.next()) |a| if (std.mem.eql(u8, a.typ, typ)) return a.body;
    return null;
}

fn readMp4(b: *Builder, s: Source) !void {
    var pos: u64 = 0;
    const moov = while (pos + 8 <= s.len) {
        const a = try audiohash.readAtom(s, pos, s.len);
        if (std.mem.eql(u8, &a.typ, "moov")) break try s.alloc(b.gpa, a.start + a.header, a.size - a.header);
        pos += a.size;
    } else return;
    const udta = findChild(moov, "udta") orelse return;
    var meta = findChild(udta, "meta") orelse return;
    // „meta“ ist meist eine Full-Box (4 Byte Version/Flags), bei QuickTime nicht.
    if (meta.len >= 8 and !std.mem.eql(u8, meta[4..8], "hdlr")) meta = meta[4..];
    const ilst = findChild(meta, "ilst") orelse return;
    var items: AtomIter = .{ .data = ilst };
    while (items.next()) |item| {
        var datas: AtomIter = .{ .data = item.body };
        while (datas.next()) |d| {
            if (!std.mem.eql(u8, d.typ, "data") or d.body.len < 8) continue;
            const kind = src_mod.readU32Be(d.body[0..4]) & 0xffffff;
            const payload = d.body[8..];
            if (mp4Field(item.typ)) |name| {
                if (kind == 1) try b.add(name, payload);
            } else if (std.mem.eql(u8, item.typ, "trkn") or std.mem.eql(u8, item.typ, "disk")) {
                if (payload.len < 6) continue;
                const is_track = item.typ[0] == 't';
                const n = src_mod.readU16Be(payload[2..4]);
                const total = src_mod.readU16Be(payload[4..6]);
                try b.add(if (is_track) "track" else "disc", try std.fmt.allocPrint(b.gpa, "{d}", .{n}));
                try b.add(if (is_track) "tracktotal" else "disctotal", try std.fmt.allocPrint(b.gpa, "{d}", .{total}));
            } else if (std.mem.eql(u8, item.typ, "covr")) {
                try b.addPicture(payload);
            }
        }
    }
}

// ───────────────────────────── WAV ─────────────────────────────────────────

fn readWav(b: *Builder, s: Source) !void {
    var riff: [12]u8 = undefined;
    try s.readExactAt(&riff, 0);
    if (!std.mem.eql(u8, riff[0..4], "RIFF") or !std.mem.eql(u8, riff[8..12], "WAVE")) return error.InvalidWav;
    var pos: u64 = 12;
    var info: ?[]const u8 = null;
    while (pos + 8 <= s.len) {
        var hdr: [8]u8 = undefined;
        try s.readExactAt(&hdr, pos);
        const size: u64 = src_mod.readU32Le(hdr[4..8]);
        const id = hdr[0..4];
        if (std.ascii.eqlIgnoreCase(id, "id3 ")) {
            try parseId3v2(b, try s.alloc(b.gpa, pos + 8, @min(size, s.len - pos - 8)));
        } else if (std.mem.eql(u8, id, "LIST") and size >= 4) {
            const data = try s.alloc(b.gpa, pos + 8, @min(size, s.len - pos - 8));
            if (std.mem.eql(u8, data[0..4], "INFO")) info = data[4..];
        }
        pos += 8 + size + (size & 1);
    }
    if (!b.isEmpty()) return; // ID3 hat Vorrang
    const data = info orelse return;
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "INAM", "title" }, .{ "IART", "artist" }, .{ "IPRD", "album" }, .{ "ICMT", "comment" },
        .{ "IGNR", "genre" }, .{ "ICRD", "date" },   .{ "ITRK", "track" }, .{ "IPRT", "track" },
    });
    var p: usize = 0;
    while (p + 8 <= data.len) {
        const len = src_mod.readU32Le(data[p + 4 ..]);
        if (len > data.len - p - 8) break;
        const val = data[p + 8 .. p + 8 + len];
        if (map.get(data[p .. p + 4])) |name| try b.add(name, std.mem.sliceTo(val, 0));
        p += 8 + len + (len & 1);
    }
}

// ───────────────────────────── Feldvergleich ───────────────────────────────

pub const FieldDiff = struct {
    name: []const u8,
    old: ?[]const []const u8,
    new: ?[]const []const u8,
};

/// Feldweiser Unterschied (für die Inbox-Anzeige); Bilder als Feld „cover“.
pub fn diff(gpa: Allocator, a: Tags, x: Tags) ![]FieldDiff {
    var out: std.ArrayList(FieldDiff) = .empty;
    for (field_names) |name| {
        const va = a.get(name);
        const vx = x.get(name);
        if (!valuesEql(va, vx)) try out.append(gpa, .{ .name = name, .old = va, .new = vx });
    }
    var pics_eq = a.pictures.len == x.pictures.len;
    if (pics_eq) for (a.pictures, x.pictures) |p, q| {
        if (!std.mem.eql(u8, &p, &q)) pics_eq = false;
    };
    if (!pics_eq) try out.append(gpa, .{ .name = "cover", .old = null, .new = null });
    return out.items;
}

fn valuesEql(a: ?[]const []const u8, x: ?[]const []const u8) bool {
    const va = a orelse return x == null;
    const vx = x orelse return false;
    if (va.len != vx.len) return false;
    for (va, vx) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

test "normalize" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Abc", (try normalize(a, "title", "  Abc\x00 ")).?);
    try std.testing.expectEqualStrings("a\nb", (try normalize(a, "lyrics", "a\r\nb\n")).?);
    try std.testing.expectEqualStrings("3", (try normalize(a, "track", "03")).?);
    try std.testing.expect(try normalize(a, "track", "0") == null);
    try std.testing.expect(try normalize(a, "title", " \t ") == null);
}

test "track mit Gesamtzahl und Sortierung" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var b: Builder = .{ .gpa = arena.allocator() };
    try b.add("track", "02/11");
    try b.add("artist", "B");
    try b.add("artist", "A");
    try b.add("artist", "B");
    const t = try b.finish();
    try std.testing.expectEqualStrings("artist", t.fields[0].name);
    try std.testing.expectEqual(@as(usize, 2), t.get("artist").?.len);
    try std.testing.expectEqualStrings("A", t.get("artist").?[0]);
    try std.testing.expectEqualStrings("2", t.get("track").?[0]);
    try std.testing.expectEqualStrings("11", t.get("tracktotal").?[0]);
}
