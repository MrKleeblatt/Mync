//! Positionsbasierter Lesezugriff auf eine Datei.

const std = @import("std");
const Io = std.Io;

pub const Source = struct {
    file: Io.File,
    io: Io,
    len: u64,

    pub fn open(io: Io, dir: Io.Dir, path: []const u8) !Source {
        const file = try openInput(io, dir, path);
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

/// Öffnet `path` zum Lesen. `fd:N:<name>` steht für einen schon offenen
/// Dateideskriptor N (Android: Datei aus der Ordnerfreigabe, dort gibt es
/// keine Pfade); `<name>` liefert nur die Endung für die Formaterkennung.
/// Der Deskriptor wird dupliziert – der Aufrufer schließt seinen selbst.
pub fn openInput(io: Io, dir: Io.Dir, path: []const u8) !Io.File {
    if (fdOf(path)) |fd| {
        const d = std.c.dup(fd);
        if (d < 0) return error.BadFileDescriptor;
        return .{ .handle = d, .flags = .{ .nonblocking = false } };
    }
    return dir.openFile(io, path, .{});
}

/// Deskriptor aus `fd:N:<name>`, sonst null.
pub fn fdOf(path: []const u8) ?std.posix.fd_t {
    if (!std.mem.startsWith(u8, path, "fd:")) return null;
    const rest = path[3..];
    const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
    return std.fmt.parseInt(std.posix.fd_t, rest[0..end], 10) catch null;
}

test "fd:N:<name>" {
    try std.testing.expectEqual(@as(?std.posix.fd_t, 12), fdOf("fd:12:A/x.mp3"));
    try std.testing.expectEqual(@as(?std.posix.fd_t, 3), fdOf("fd:3"));
    try std.testing.expectEqual(@as(?std.posix.fd_t, null), fdOf("fd/x.mp3"));
    try std.testing.expectEqual(@as(?std.posix.fd_t, null), fdOf("A/x.mp3"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "a.bin", .data = "hallo" });
    const f = try tmp.dir.openFile(io, "a.bin", .{});
    defer f.close(io);
    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "fd:{d}:a.bin", .{f.handle});
    const s = try Source.open(io, std.Io.Dir.cwd(), name);
    var got: [5]u8 = undefined;
    try s.readExactAt(&got, 0);
    s.close(); // schließt nur das Duplikat
    try std.testing.expectEqualStrings("hallo", &got);
    try std.testing.expectEqual(@as(u64, 5), try f.length(io));
}

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
