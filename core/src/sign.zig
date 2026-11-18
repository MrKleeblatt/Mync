//! Ed25519-Signaturen für Update-Manifeste und SHA-256 für Dateien.
//!
//! Schlüssel werden hexadezimal gespeichert: der geheime Schlüssel als
//! 32-Byte-Seed (64 Hex-Zeichen), der öffentliche als 32 Byte (64 Hex-Zeichen),
//! die Signatur als 64 Byte (128 Hex-Zeichen).

const std = @import("std");
const Io = std.Io;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const KeyHex = struct { seed: [64]u8, public: [64]u8 };

pub fn generate(io: Io) KeyHex {
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    io.random(&seed);
    const kp = Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
    return .{
        .seed = std.fmt.bytesToHex(seed, .lower),
        .public = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower),
    };
}

fn fromHex(comptime n: usize, hex: []const u8) ![n]u8 {
    const t = std.mem.trim(u8, hex, " \t\r\n");
    if (t.len != n * 2) return error.InvalidKey;
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, t) catch return error.InvalidKey;
    return out;
}

/// Öffentlicher Schlüssel zu einem geheimen Seed (hex).
pub fn publicFromSeed(seed_hex: []const u8) ![64]u8 {
    const kp = try Ed25519.KeyPair.generateDeterministic(try fromHex(32, seed_hex));
    return std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
}

/// Signiert [msg] mit dem geheimen Seed (hex); Ergebnis hex.
pub fn sign(seed_hex: []const u8, msg: []const u8) ![128]u8 {
    const kp = try Ed25519.KeyPair.generateDeterministic(try fromHex(32, seed_hex));
    const sig = try kp.sign(msg, null);
    return std.fmt.bytesToHex(sig.toBytes(), .lower);
}

/// Prüft eine Signatur (alles hex). false bei falscher Signatur oder Schlüssel.
pub fn verify(public_hex: []const u8, msg: []const u8, sig_hex: []const u8) bool {
    const pk = Ed25519.PublicKey.fromBytes(fromHex(32, public_hex) catch return false) catch return false;
    const sig = Ed25519.Signature.fromBytes(fromHex(64, sig_hex) catch return false);
    sig.verify(msg, pk) catch return false;
    return true;
}

/// SHA-256 einer Datei (hex).
pub fn sha256File(io: Io, dir: Io.Dir, path: []const u8) ![64]u8 {
    const f = try dir.openFile(io, path, .{});
    defer f.close(io);
    var h = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = try f.readPositionalAll(io, &buf, off);
        if (n == 0) break;
        h.update(buf[0..n]);
        off += n;
        if (n < buf.len) break;
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return std.fmt.bytesToHex(out, .lower);
}

test "Signieren und Prüfen" {
    const k = generate(std.testing.io);
    const msg = "{\"version\":\"1.2.3\"}";
    const sig = try sign(&k.seed, msg);
    try std.testing.expect(verify(&k.public, msg, &sig));
    try std.testing.expect(!verify(&k.public, "{\"version\":\"6.6.6\"}", &sig));
    const other = generate(std.testing.io);
    try std.testing.expect(!verify(&other.public, msg, &sig));
    try std.testing.expect(!verify("zz", msg, &sig));
    try std.testing.expectEqualStrings(&k.public, &(try publicFromSeed(&k.seed)));
}

test "SHA-256 einer Datei" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "abc" });
    const h = try sha256File(std.testing.io, tmp.dir, "a");
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &h);
}
