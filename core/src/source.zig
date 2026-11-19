//! Positionsbasierter Lesezugriff auf eine Datei.

const std = @import("std");
const Io = std.Io;

pub const Source = struct {
    file: Io.File,
    io: Io,
    len: u64,

    pub fn open(io: Io, dir: Io.Dir, path: []const u8) !Source {
        const file = try dir.openFile(io, path, .{});
        errdefer file.close(io);
        const len = try file.length(io);
        return .{ .file = file, .io = io, .len = len };
    }

    pub fn close(s: Source) void {
        s.file.close(s.io);
    }

    /// Liest ab `off` so viel wie möglich; weniger als `buf.len` nur am Dateiende.
    pub fn readAt(s: Source, buf: []u8, off: u64) !usize {
        if (off >= s.len) return 0;
        return s.file.readPositionalAll(s.io, buf, off);
    }

    /// Liest genau `buf.len` Bytes ab `off`, sonst `error.EndOfStream`.
    pub fn readExactAt(s: Source, buf: []u8, off: u64) !void {
        if (try s.readAt(buf, off) != buf.len) return error.EndOfStream;
    }

    /// Liest `n` Bytes ab `off` in einen neuen Puffer.
    pub fn alloc(s: Source, gpa: std.mem.Allocator, off: u64, n: u64) ![]u8 {
        if (off + n > s.len) return error.EndOfStream;
        const buf = try gpa.alloc(u8, @intCast(n));
        errdefer gpa.free(buf);
        try s.readExactAt(buf, off);
        return buf;
    }
};

pub fn readU32Be(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}
pub fn readU32Le(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}
pub fn readU16Be(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .big);
}
pub fn readU64Be(b: []const u8) u64 {
    return std.mem.readInt(u64, b[0..8], .big);
}

/// ID3v2-„syncsafe“-Ganzzahl (7 Bit je Byte).
pub fn syncsafe(b: []const u8) u32 {
    var v: u32 = 0;
    for (b) |x| v = (v << 7) | (x & 0x7f);
    return v;
}
