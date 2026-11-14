//! Liest die Segmente des ersten logischen Streams einer Ogg-Datei.

const std = @import("std");
const Source = @import("source.zig").Source;

pub const Segment = struct {
    data: []const u8,
    /// Letztes Segment eines Pakets (Länge < 255).
    ends_packet: bool,
};

pub const SegmentReader = struct {
    src: Source,
    pos: u64 = 0,
    serial: ?u32 = null,
    lacing: [255]u8 = undefined,
    nseg: usize = 0,
    seg: usize = 0,
    body: [255 * 255]u8 = undefined,
    body_off: usize = 0,

    pub fn init(src: Source) SegmentReader {
        return .{ .src = src };
    }

    fn nextPage(r: *SegmentReader) !bool {
        while (true) {
            if (r.pos + 27 > r.src.len) return false;
            var hdr: [27]u8 = undefined;
            try r.src.readExactAt(&hdr, r.pos);
            if (!std.mem.eql(u8, hdr[0..4], "OggS")) return error.InvalidOgg;
            const serial = std.mem.readInt(u32, hdr[14..18], .little);
            const nseg: usize = hdr[26];
            try r.src.readExactAt(r.lacing[0..nseg], r.pos + 27);
            var body_len: usize = 0;
            for (r.lacing[0..nseg]) |l| body_len += l;
            const body_pos = r.pos + 27 + nseg;
            r.pos = body_pos + body_len;
            const first = r.serial orelse blk: {
                r.serial = serial;
                break :blk serial;
            };
            if (serial != first) continue; // anderer logischer Stream
            try r.src.readExactAt(r.body[0..body_len], body_pos);
            r.nseg = nseg;
            r.seg = 0;
            r.body_off = 0;
            return true;
        }
    }

    pub fn next(r: *SegmentReader) !?Segment {
        while (r.seg >= r.nseg) {
            if (!try r.nextPage()) return null;
        }
        const l = r.lacing[r.seg];
        r.seg += 1;
        const data = r.body[r.body_off .. r.body_off + l];
        r.body_off += l;
        return .{ .data = data, .ends_packet = l < 255 };
    }

    /// Setzt das nächste vollständige Paket zusammen.
    pub fn nextPacket(r: *SegmentReader, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !bool {
        out.clearRetainingCapacity();
        var any = false;
        while (try r.next()) |s| {
            any = true;
            try out.appendSlice(gpa, s.data);
            if (s.ends_packet) return true;
        }
        if (any) return error.InvalidOgg; // abgeschnittenes Paket
        return false;
    }
};

pub const Codec = enum { vorbis, opus, flac };

pub fn codecOf(first_packet: []const u8) !Codec {
    if (std.mem.startsWith(u8, first_packet, "OpusHead")) return .opus;
    if (std.mem.startsWith(u8, first_packet, "\x01vorbis")) return .vorbis;
    if (std.mem.startsWith(u8, first_packet, "\x7fFLAC")) return .flac;
    return error.UnknownOggCodec;
}

/// Anzahl der Header-Pakete (inklusive dem ersten).
pub fn headerCount(first_packet: []const u8) !u64 {
    return switch (try codecOf(first_packet)) {
        .opus => 2,
        .vorbis => 3,
        .flac => blk: {
            if (first_packet.len < 9) return error.InvalidOgg;
            break :blk 1 + @as(u64, std.mem.readInt(u16, first_packet[7..9], .big));
        },
    };
}
