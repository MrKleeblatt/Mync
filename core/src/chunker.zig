//! Inhaltsabhängige Zerlegung von Dateien in Bausteine (Gear-Hash, wie FastCDC), für Teil-Updates
//! der Android-App – übernommen aus Kassenbon (backend/src/updates/chunker.zig), mit denselben
//! Werten und Prüfdaten: Die App zerlegt ihre installierte APK genauso wie das Release-Skript die
//! neue (`mync chunk`) und lädt nur die Bausteine, die sie nicht schon hat. Schnitte hängen nur von
//! den letzten 64 Bytes ab; eingefügte oder entfernte Daten verschieben nicht alle Bausteine.
const std = @import("std");

pub const min_size = 8 * 1024;
pub const max_size = 128 * 1024;
pub const mask: u64 = (1 << 15) - 1; // im Mittel ~32 KiB nach der Mindestgröße

/// 256 Zufallszahlen aus splitmix64 mit festem Startwert ("KASSENBO").
pub const gear: [256]u64 = blk: {
    var t: [256]u64 = undefined;
    var s: u64 = 0x4B415353454E424F;
    for (&t) |*g| {
        s +%= 0x9E3779B97F4A7C15;
        var z = s;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        g.* = z ^ (z >> 31);
    }
    break :blk t;
};

/// Länge des nächsten Bausteins am Anfang von `data`.
pub fn cut(data: []const u8) usize {
    if (data.len <= min_size) return data.len;
    const end = @min(data.len, max_size);
    var h: u64 = 0;
    var i: usize = min_size;
    while (i < end) {
        h = (h << 1) +% gear[data[i]];
        i += 1;
        if (h & mask == 0) return i;
    }
    return end;
}

pub const Chunk = struct { offset: usize, len: usize, hash: [32]u8 };

/// Kennung eines Bausteins: die ersten 16 Bytes von SHA-256, als Hex.
pub fn chunkHash(bytes: []const u8) [32]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d[0..16].*, .lower);
}

pub fn split(a: std.mem.Allocator, data: []const u8) ![]Chunk {
    var out: std.ArrayList(Chunk) = .empty;
    var off: usize = 0;
    while (off < data.len) {
        const n = cut(data[off..]);
        try out.append(a, .{ .offset = off, .len = n, .hash = chunkHash(data[off .. off + n]) });
        off += n;
    }
    return out.items;
}

/// Zerlegt die Datei `path` (relativ zu `dir`).
pub fn splitFile(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]Chunk {
    const data = try dir.readFileAlloc(io, path, a, .unlimited);
    return split(a, data);
}

/// Prüfdaten, die auch der Test der App erzeugt: 300 000 Bytes aus splitmix64 (Startwert 42).
pub fn testData(a: std.mem.Allocator) ![]u8 {
    const buf = try a.alloc(u8, 300_000);
    var s: u64 = 42;
    for (buf) |*b| {
        s +%= 0x9E3779B97F4A7C15;
        var z = s;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        b.* = @truncate(z ^ (z >> 31));
    }
    return buf;
}

test "Bausteine: feste Prüfwerte (müssen in der App gleich sein)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try testData(a);
    const chunks = try split(a, data);
    const want = [_]usize{ 15101, 27119, 58303, 20822, 11470, 39488, 64528, 18597, 30563, 14009 };
    try std.testing.expectEqual(want.len, chunks.len);
    for (want, chunks) |w, c| try std.testing.expectEqual(w, c.len);
    try std.testing.expectEqualStrings("2c12667d4ab2cedc82508ad421eb578f", &chunks[0].hash);
}

test "Einfügen verschiebt nur wenige Bausteine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try testData(a);
    // 100 Bytes nach 50 000 einfügen
    const changed = try std.mem.concat(a, u8, &.{ data[0..50_000], &@as([100]u8, @splat(7)), data[50_000..] });
    const old = try split(a, data);
    const new = try split(a, changed);
    var known: usize = 0;
    for (new) |n| {
        for (old) |o| {
            if (std.mem.eql(u8, &o.hash, &n.hash)) {
                known += n.len;
                break;
            }
        }
    }
    try std.testing.expect(known > changed.len * 7 / 10);
}
