//! `audio_hash`: SHA-256 über die reinen Audiodaten einer Datei – ohne Tags.
//!
//! Damit bleibt der Hash bei Tag-Änderungen (Titel, Cover, Lyrics …) gleich,
//! und eine Umbenennung lässt sich am identischen Hash erkennen.
//!
//! - MP3:  alles außer ID3v2 (Anfang), APEv2 und ID3v1 (Ende)
//! - FLAC: die Audio-Frames nach den Metadaten-Blöcken
//! - Ogg (Vorbis, Opus, FLAC): alle Pakete nach den Header-Paketen
//! - MP4/M4A: der Inhalt aller `mdat`-Atome
//! - WAV:  der Inhalt des `data`-Chunks
//! - sonst: die ganze Datei (z. B. `.lrc`, `.m3u`)

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const src_mod = @import("source.zig");
const Source = src_mod.Source;
const ogg = @import("ogg.zig");

pub const Kind = enum { mp3, flac, ogg, mp4, wav, whole_file };

pub const Format = enum {
    mp3,
    flac,
    ogg,
    mp4,
    wav,
    other,

    pub fn fromPath(path: []const u8) Format {
        const ext = std.fs.path.extension(path);
        if (ext.len < 2) return .other;
        var buf: [8]u8 = undefined;
        if (ext.len - 1 > buf.len) return .other;
        const e = std.ascii.lowerString(&buf, ext[1..]);
        const map = std.StaticStringMap(Format).initComptime(.{
            .{ "mp3", .mp3 },  .{ "flac", .flac }, .{ "ogg", .ogg },
            .{ "oga", .ogg },  .{ "opus", .ogg },  .{ "m4a", .mp4 },
            .{ "m4b", .mp4 },  .{ "mp4", .mp4 },   .{ "aac", .mp4 },
            .{ "wav", .wav },
        });
        return map.get(e) orelse .other;
    }
};

pub const Hex = [64]u8;

pub const Result = struct { hash: Hex, kind: Kind };

pub fn hashFile(io: Io, dir: Io.Dir, path: []const u8) !Result {
    const s = try Source.open(io, dir, path);
    defer s.close();
    return hashSource(s, Format.fromPath(path));
}

pub fn hashSource(s: Source, format: Format) !Result {
    var h = Sha256.init(.{});
    var kind: Kind = undefined;
    switch (format) {
        .mp3 => {
            const r = try mp3AudioRange(s);
            try hashRange(s, r[0], r[1], &h);
            kind = .mp3;
        },
        .flac => {
            try hashRange(s, try flacAudioStart(s), s.len, &h);
            kind = .flac;
        },
        .ogg => {
            try hashOgg(s, &h);
            kind = .ogg;
        },
        .mp4 => if (try isMp4(s)) {
            try hashMp4(s, &h);
            kind = .mp4;
        } else {
            try hashRange(s, 0, s.len, &h);
            kind = .whole_file;
        },
        .wav => {
            try hashWav(s, &h);
            kind = .wav;
        },
        .other => {
            try hashRange(s, 0, s.len, &h);
            kind = .whole_file;
        },
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return .{ .hash = std.fmt.bytesToHex(out, .lower), .kind = kind };
}

fn hashRange(s: Source, start: u64, end: u64, h: *Sha256) !void {
    if (end < start) return error.InvalidRange;
    var buf: [64 * 1024]u8 = undefined;
    var pos = start;
    while (pos < end) {
        const want: usize = @intCast(@min(buf.len, end - pos));
        const n = try s.readAt(buf[0..want], pos);
        if (n == 0) return error.EndOfStream;
        h.update(buf[0..n]);
        pos += n;
    }
}

/// Länge eines ID3v2-Tags an Position `pos` (inkl. Header/Footer), 0 wenn keiner.
pub fn id3v2Len(s: Source, pos: u64) !u64 {
    var hdr: [10]u8 = undefined;
    if (try s.readAt(&hdr, pos) != 10 or !std.mem.eql(u8, hdr[0..3], "ID3")) return 0;
    const footer: u64 = if (hdr[5] & 0x10 != 0) 10 else 0;
    return 10 + @as(u64, src_mod.syncsafe(hdr[6..10])) + footer;
}

fn mp3AudioRange(s: Source) ![2]u64 {
    var start: u64 = 0;
    while (true) {
        const l = try id3v2Len(s, start);
        if (l == 0) break;
        start += l;
    }
    start = @min(start, s.len);
    var end = s.len;
    var tag: [3]u8 = undefined;
    if (end >= start + 128 and try s.readAt(&tag, end - 128) == 3 and std.mem.eql(u8, &tag, "TAG")) {
        end -= 128;
    }
    var footer: [32]u8 = undefined;
    if (end >= start + 32 and try s.readAt(&footer, end - 32) == 32 and std.mem.eql(u8, footer[0..8], "APETAGEX")) {
        const size: u64 = src_mod.readU32Le(footer[12..16]);
        const flags = src_mod.readU32Le(footer[20..24]);
        const header: u64 = if (flags & (1 << 31) != 0) 32 else 0;
        end = @max(end -| (size + header), start);
    }
    return .{ start, end };
}

/// Position nach den FLAC-Metadaten-Blöcken (ID3v2 davor wird übersprungen).
pub fn flacAudioStart(s: Source) !u64 {
    var pos = try id3v2Len(s, 0);
    var magic: [4]u8 = undefined;
    try s.readExactAt(&magic, pos);
    if (!std.mem.eql(u8, &magic, "fLaC")) return error.InvalidFlac;
    pos += 4;
    while (true) {
        var hdr: [4]u8 = undefined;
        try s.readExactAt(&hdr, pos);
        const size = std.mem.readInt(u24, hdr[1..4], .big);
        pos += 4 + @as(u64, size);
        if (hdr[0] & 0x80 != 0) return pos;
    }
}

fn hashOgg(s: Source, h: *Sha256) !void {
    var r = ogg.SegmentReader.init(s);
    var first: std.ArrayList(u8) = .empty;
    var first_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&first_buf);
    var headers: ?u64 = null;
    var packets: u64 = 0;
    while (try r.next()) |seg| {
        if (headers) |n| {
            if (packets >= n) h.update(seg.data);
        } else {
            // Erstes Paket sammeln (nur der Anfang wird zur Codec-Erkennung gebraucht)
            const room = first_buf.len - first.items.len;
            first.appendSlice(fba.allocator(), seg.data[0..@min(seg.data.len, room)]) catch {};
        }
        if (seg.ends_packet) {
            if (headers == null) headers = try ogg.headerCount(first.items);
            packets += 1;
        }
    }
    if (headers == null) return error.InvalidOgg;
}

fn isMp4(s: Source) !bool {
    var b: [8]u8 = undefined;
    return try s.readAt(&b, 0) == 8 and std.mem.eql(u8, b[4..8], "ftyp");
}

pub const Atom = struct { typ: [4]u8, start: u64, header: u64, size: u64 };

/// Liest den Kopf eines MP4-Atoms an `pos` (beachtet 64-Bit-Größen und Größe 0).
pub fn readAtom(s: Source, pos: u64, end: u64) !Atom {
    var hdr: [16]u8 = undefined;
    try s.readExactAt(hdr[0..8], pos);
    var size: u64 = src_mod.readU32Be(hdr[0..4]);
    var header: u64 = 8;
    if (size == 1) {
        try s.readExactAt(hdr[8..16], pos + 8);
        size = src_mod.readU64Be(hdr[8..16]);
        header = 16;
    } else if (size == 0) {
        size = end - pos;
    }
    if (size < header or pos + size > end) return error.InvalidMp4;
    return .{ .typ = hdr[4..8].*, .start = pos, .header = header, .size = size };
}

fn hashMp4(s: Source, h: *Sha256) !void {
    var pos: u64 = 0;
    var found = false;
    while (pos + 8 <= s.len) {
        const a = try readAtom(s, pos, s.len);
        if (std.mem.eql(u8, &a.typ, "mdat")) {
            try hashRange(s, a.start + a.header, a.start + a.size, h);
            found = true;
        }
        pos += a.size;
    }
    if (!found) return error.NoMdat;
}

fn hashWav(s: Source, h: *Sha256) !void {
    var riff: [12]u8 = undefined;
    try s.readExactAt(&riff, 0);
    if (!std.mem.eql(u8, riff[0..4], "RIFF") or !std.mem.eql(u8, riff[8..12], "WAVE")) return error.InvalidWav;
    var pos: u64 = 12;
    while (pos + 8 <= s.len) {
        var hdr: [8]u8 = undefined;
        try s.readExactAt(&hdr, pos);
        const size: u64 = src_mod.readU32Le(hdr[4..8]);
        if (std.mem.eql(u8, hdr[0..4], "data")) {
            return hashRange(s, pos + 8, @min(pos + 8 + size, s.len), h);
        }
        pos += 8 + size + (size & 1);
    }
    return error.NoDataChunk;
}
