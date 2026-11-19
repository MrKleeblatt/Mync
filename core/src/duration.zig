//! Spieldauer einer Audiodatei in Millisekunden, ohne zu dekodieren.
//!
//! - MP3:  Xing/Info- bzw. VBRI-Header (Frame-Anzahl), sonst CBR-Schätzung
//! - FLAC: STREAMINFO (Samples / Abtastrate)
//! - Ogg:  Granule-Position der letzten Seite (Opus: minus Pre-Skip)
//! - MP4:  `mvhd` (Dauer / Zeitbasis)
//! - WAV:  Größe des `data`-Chunks / Byterate

const std = @import("std");
const Io = std.Io;
const src_mod = @import("source.zig");
const Source = src_mod.Source;
const audiohash = @import("audiohash.zig");
const ogg = @import("ogg.zig");

/// Dauer in ms, oder null wenn unbekannt (z. B. `.lrc`, beschädigte Datei).
pub fn ofFile(io: Io, dir: Io.Dir, path: []const u8) ?u64 {
    const s = Source.open(io, dir, path) catch return null;
    defer s.close();
    return ofSource(s, audiohash.Format.fromPath(path)) catch null;
}

pub fn ofSource(s: Source, format: audiohash.Format) !?u64 {
    return switch (format) {
        .mp3 => try mp3(s),
        .flac => try flac(s),
        .ogg => try oggDuration(s),
        .mp4 => try mp4(s),
        .wav => try wav(s),
        .other => null,
    };
}

fn ms(samples: u64, rate: u64) ?u64 {
    if (rate == 0) return null;
    return samples * 1000 / rate;
}

// ───────────────────────────── MP3 ─────────────────────────────────────────

const FrameHeader = struct {
    version: enum { v1, v2, v25 },
    layer: u2, // 1, 2, 3
    bitrate: u32, // bit/s
    sample_rate: u32,
    mono: bool,
    size: u32,

    fn samplesPerFrame(h: FrameHeader) u32 {
        return switch (h.layer) {
            1 => 384,
            2 => 1152,
            else => if (h.version == .v1) 1152 else 576,
        };
    }
};

fn parseFrameHeader(b: [4]u8) ?FrameHeader {
    if (b[0] != 0xff or b[1] & 0xe0 != 0xe0) return null;
    const ver_bits = (b[1] >> 3) & 3;
    const layer_bits = (b[1] >> 1) & 3;
    const br_idx = b[2] >> 4;
    const sr_idx = (b[2] >> 2) & 3;
    if (ver_bits == 1 or layer_bits == 0 or br_idx == 0 or br_idx == 15 or sr_idx == 3) return null;
    const version: @FieldType(FrameHeader, "version") = switch (ver_bits) {
        3 => .v1,
        2 => .v2,
        else => .v25,
    };
    const layer: u2 = @intCast(4 - @as(u8, layer_bits));
    const kbps_table = [_][15]u16{
        .{ 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448 }, // V1 L1
        .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384 }, // V1 L2
        .{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 }, // V1 L3
        .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256 }, // V2 L1
        .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 }, // V2 L2/L3
    };
    const row: usize = if (version == .v1) @as(usize, layer) - 1 else if (layer == 1) 3 else 4;
    const bitrate = @as(u32, kbps_table[row][br_idx]) * 1000;
    const base_rates = [_]u32{ 44100, 48000, 32000 };
    const sample_rate = switch (version) {
        .v1 => base_rates[sr_idx],
        .v2 => base_rates[sr_idx] / 2,
        .v25 => base_rates[sr_idx] / 4,
    };
    const padding: u32 = (b[2] >> 1) & 1;
    const size = if (layer == 1)
        (12 * bitrate / sample_rate + padding) * 4
    else if (layer == 3 and version != .v1)
        72 * bitrate / sample_rate + padding
    else
        144 * bitrate / sample_rate + padding;
    return .{
        .version = version,
        .layer = layer,
        .bitrate = bitrate,
        .sample_rate = sample_rate,
        .mono = (b[3] >> 6) == 3,
        .size = size,
    };
}

fn mp3(s: Source) !?u64 {
    var start: u64 = 0;
    while (true) {
        const l = try audiohash.id3v2Len(s, start);
        if (l == 0) break;
        start += l;
    }
    // Erstes gültiges Frame suchen (zwei aufeinanderfolgende Header zur Sicherheit)
    var buf: [64 * 1024]u8 = undefined;
    const n = try s.readAt(&buf, start);
    var i: usize = 0;
    const first: struct { off: usize, h: FrameHeader } = while (i + 4 <= n) : (i += 1) {
        const h = parseFrameHeader(buf[i..][0..4].*) orelse continue;
        if (i + h.size + 4 <= n and parseFrameHeader(buf[i + h.size ..][0..4].*) == null) continue;
        break .{ .off = i, .h = h };
    } else return null;
    const h = first.h;
    const frame = buf[first.off..n];

    // Xing/Info steht nach der Side-Info
    const side: usize = if (h.version == .v1) (if (h.mono) 17 else 32) else (if (h.mono) 9 else 17);
    const xo = 4 + side;
    if (frame.len >= xo + 12 and (std.mem.eql(u8, frame[xo .. xo + 4], "Xing") or std.mem.eql(u8, frame[xo .. xo + 4], "Info"))) {
        const flags = src_mod.readU32Be(frame[xo + 4 ..]);
        if (flags & 1 != 0) {
            const frames = src_mod.readU32Be(frame[xo + 8 ..]);
            return ms(@as(u64, frames) * h.samplesPerFrame(), h.sample_rate);
        }
    }
    // VBRI (Fraunhofer) steht 32 Bytes nach dem Header
    if (frame.len >= 4 + 32 + 18 and std.mem.eql(u8, frame[36..40], "VBRI")) {
        const frames = src_mod.readU32Be(frame[36 + 14 ..]);
        return ms(@as(u64, frames) * h.samplesPerFrame(), h.sample_rate);
    }
    // CBR-Schätzung: Audiobytes / Bitrate
    var end = s.len;
    var tag: [3]u8 = undefined;
    if (end >= 128 and try s.readAt(&tag, end - 128) == 3 and std.mem.eql(u8, &tag, "TAG")) end -= 128;
    const audio = end -| (start + first.off);
    if (h.bitrate == 0) return null;
    return audio * 8 * 1000 / h.bitrate;
}

// ───────────────────────────── FLAC ────────────────────────────────────────

fn flac(s: Source) !?u64 {
    const pos = try audiohash.id3v2Len(s, 0);
    var b: [4 + 4 + 34]u8 = undefined;
    try s.readExactAt(&b, pos);
    if (!std.mem.eql(u8, b[0..4], "fLaC") or b[4] & 0x7f != 0) return null;
    return streaminfoMs(b[8..42]);
}

/// STREAMINFO (34 Bytes): Abtastrate 20 Bit ab Byte 10, Samples 36 Bit ab Bit 108.
fn streaminfoMs(si: []const u8) ?u64 {
    const rate: u64 = (@as(u64, si[10]) << 12) | (@as(u64, si[11]) << 4) | (si[12] >> 4);
    const total: u64 = (@as(u64, si[13] & 0x0f) << 32) | src_mod.readU32Be(si[14..18]);
    if (total == 0) return null;
    return ms(total, rate);
}

// ───────────────────────────── Ogg ─────────────────────────────────────────

fn oggDuration(s: Source) !?u64 {
    // Erstes Paket: Codec, Abtastrate, Pre-Skip, Seriennummer
    var r = try std.heap.page_allocator.create(ogg.SegmentReader);
    defer std.heap.page_allocator.destroy(r);
    r.* = ogg.SegmentReader.init(s);
    var pkt: std.ArrayList(u8) = .empty;
    defer pkt.deinit(std.heap.page_allocator);
    if (!try r.nextPacket(std.heap.page_allocator, &pkt)) return null;
    const p = pkt.items;
    const serial = r.serial orelse return null;
    var rate: u64 = undefined;
    var pre_skip: u64 = 0;
    switch (try ogg.codecOf(p)) {
        .opus => {
            if (p.len < 12) return null;
            rate = 48000;
            pre_skip = std.mem.readInt(u16, p[10..12], .little);
        },
        .vorbis => {
            if (p.len < 16) return null;
            rate = src_mod.readU32Le(p[12..16]);
        },
        .flac => {
            // 0x7F "FLAC" Version(2) Header-Anzahl(2) "fLaC" STREAMINFO-Kopf(4) STREAMINFO(34)
            if (p.len < 17 + 34) return null;
            return streaminfoMs(p[17 .. 17 + 34]);
        },
    }
    // Letzte Seite dieses Streams: vom Dateiende rückwärts nach "OggS" suchen
    const tail_len: u64 = @min(s.len, 128 * 1024);
    const tail = try std.heap.page_allocator.alloc(u8, @intCast(tail_len));
    defer std.heap.page_allocator.free(tail);
    try s.readExactAt(tail, s.len - tail_len);
    var i: usize = tail.len -| 27;
    while (true) : (i -= 1) {
        if (std.mem.eql(u8, tail[i .. i + 4], "OggS") and
            std.mem.readInt(u32, tail[i + 14 ..][0..4], .little) == serial)
        {
            const granule = std.mem.readInt(u64, tail[i + 6 ..][0..8], .little);
            if (granule != std.math.maxInt(u64)) return ms(granule -| pre_skip, rate);
        }
        if (i == 0) return null;
    }
}

// ───────────────────────────── MP4 ─────────────────────────────────────────

fn mp4(s: Source) !?u64 {
    var pos: u64 = 0;
    while (pos + 8 <= s.len) {
        const a = try audiohash.readAtom(s, pos, s.len);
        if (std.mem.eql(u8, &a.typ, "moov")) {
            var p = a.start + a.header;
            const end = a.start + a.size;
            while (p + 8 <= end) {
                const c = try audiohash.readAtom(s, p, end);
                if (std.mem.eql(u8, &c.typ, "mvhd")) {
                    var b: [32]u8 = undefined;
                    try s.readExactAt(&b, c.start + c.header);
                    if (b[0] == 1) {
                        return ms(src_mod.readU64Be(b[24..32]), src_mod.readU32Be(b[20..24]));
                    }
                    return ms(src_mod.readU32Be(b[16..20]), src_mod.readU32Be(b[12..16]));
                }
                p += c.size;
            }
            return null;
        }
        pos += a.size;
    }
    return null;
}

// ───────────────────────────── WAV ─────────────────────────────────────────

fn wav(s: Source) !?u64 {
    var pos: u64 = 12;
    var byte_rate: u64 = 0;
    while (pos + 8 <= s.len) {
        var hdr: [8]u8 = undefined;
        try s.readExactAt(&hdr, pos);
        const size: u64 = src_mod.readU32Le(hdr[4..8]);
        if (std.mem.eql(u8, hdr[0..4], "fmt ") and size >= 12) {
            var f: [12]u8 = undefined;
            try s.readExactAt(&f, pos + 8);
            byte_rate = src_mod.readU32Le(f[8..12]);
        } else if (std.mem.eql(u8, hdr[0..4], "data")) {
            if (byte_rate == 0) return null;
            return @min(size, s.len - pos - 8) * 1000 / byte_rate;
        }
        pos += 8 + size + (size & 1);
    }
    return null;
}

test "Dauer der Testdateien (je 0,5 s)" {
    const t = std.testing;
    const options = @import("build_options");
    var dir = try Io.Dir.cwd().openDir(t.io, options.testdata_dir, .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(t.io)) |e| {
        if (std.mem.endsWith(u8, e.name, ".json")) continue;
        const d = ofFile(t.io, dir, e.name) orelse {
            std.debug.print("keine Dauer: {s}\n", .{e.name});
            return error.NoDuration;
        };
        // Encoder fügen etwas Vor-/Nachlauf hinzu
        if (d < 450 or d > 600) {
            std.debug.print("{s}: {d} ms\n", .{ e.name, d });
            return error.WrongDuration;
        }
        n += 1;
    }
    try t.expect(n >= 26);
}
