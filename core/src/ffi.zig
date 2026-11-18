//! C-Schnittstelle für die Flutter-App (dart:ffi).
//!
//! Alle Funktionen liefern einen JSON-String, der mit `mync_free` wieder
//! freigegeben werden muss:
//!   {"ok": <Ergebnis>}   oder   {"error": "<Meldung>"}
//! Aufrufe werden intern serialisiert.

const std = @import("std");
const Io = std.Io;
const core = @import("mync_core");

const gpa = std.heap.c_allocator;
var threaded: Io.Threaded = .init_single_threaded;
var busy = std.atomic.Value(bool).init(false);

fn lock() void {
    while (busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn unlock() void {
    busy.store(false, .release);
}

/// Ruft `f` mit Arena und Io auf und verpackt Ergebnis oder Fehler als JSON.
fn call(comptime f: anytype, args: anytype) ?[*:0]u8 {
    lock();
    defer unlock();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = threaded.io();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    const ok = blk: {
        const result = @call(.auto, f, .{ a, io } ++ args) catch |err| break :blk err;
        s.beginObject() catch return null;
        s.objectField("ok") catch return null;
        s.write(result) catch return null;
        s.endObject() catch return null;
        break :blk {};
    };
    ok catch |err| {
        out.clearRetainingCapacity();
        s = .{ .writer = &out.writer };
        s.write(.{ .@"error" = @errorName(err) }) catch return null;
    };
    const z = gpa.dupeSentinel(u8, out.written(), 0) catch return null;
    return z.ptr;
}

export fn mync_free(p: ?[*:0]u8) void {
    const ptr = p orelse return;
    gpa.free(std.mem.span(ptr));
}

export fn mync_version() [*:0]const u8 {
    return "0.3.0";
}

// ───────────────────────────── Bibliothek ──────────────────────────────────

const ScanSummary = struct {
    total: u32,
    hashed: u32,
    added: u32,
    removed: u32,
    errors: []const []const u8,
};

fn scan(a: std.mem.Allocator, io: Io, root: []const u8, db: [:0]const u8) !ScanSummary {
    if (std.fs.path.dirname(db)) |d| try Io.Dir.cwd().createDirPath(io, d);
    const m = try core.manifest.Manifest.open(io, db, root);
    defer m.close();
    const r = try m.scan(a);
    const errs = try a.alloc([]const u8, r.errors.len);
    for (r.errors, errs) |e, *o| o.* = try std.fmt.allocPrint(a, "{s}: {s}", .{ e.path, e.message });
    return .{ .total = r.total, .hashed = r.hashed, .added = r.added, .removed = r.removed, .errors = errs };
}

/// Durchsucht den Musikordner `root` und aktualisiert das Manifest `db`.
export fn mync_scan(root: [*:0]const u8, db: [*:0]const u8) ?[*:0]u8 {
    return call(scan, .{ std.mem.span(root), std.mem.span(db) });
}

const Fields = std.json.ArrayHashMap([]const []const u8);
const TagsJson = struct { fields: Fields };

/// Ein Titel der Bibliothek. `fields` enthält alle Tag-Felder außer den
/// Lyrics (die werden einzeln über `mync_read_tags` geladen).
const TrackInfo = struct {
    file_id: []const u8,
    path: []const u8,
    duration_ms: i64,
    added_ms: i64,
    has_lyrics: bool,
    fields: Fields,
};

fn isAudio(path: []const u8) bool {
    return core.audiohash.Format.fromPath(path) != .other;
}

fn listTracks(a: std.mem.Allocator, io: Io, root: []const u8, db: [:0]const u8) ![]TrackInfo {
    if (std.fs.path.dirname(db)) |d| try Io.Dir.cwd().createDirPath(io, d);
    const m = try core.manifest.Manifest.open(io, db, root);
    defer m.close();
    const rows = try m.files(a);
    var out: std.ArrayList(TrackInfo) = .empty;
    for (rows) |r| {
        if (!isAudio(r.entry.path)) continue;
        var t = std.json.parseFromSliceLeaky(TagsJson, a, r.tags_json, .{ .ignore_unknown_fields = true }) catch
            TagsJson{ .fields = .{} };
        const has_lyrics = t.fields.map.orderedRemove("lyrics");
        try out.append(a, .{
            .file_id = r.file_id,
            .path = r.entry.path,
            .duration_ms = r.duration_ms,
            .added_ms = r.added_ms,
            .has_lyrics = has_lyrics,
            .fields = t.fields,
        });
    }
    return out.items;
}

/// Liefert alle Audiodateien aus dem Manifest, sortiert nach Pfad.
export fn mync_list_tracks(root: [*:0]const u8, db: [*:0]const u8) ?[*:0]u8 {
    return call(listTracks, .{ std.mem.span(root), std.mem.span(db) });
}

// ───────────────────────────── Einzelne Datei ──────────────────────────────

const ChapterJson = struct { start_ms: u64, end_ms: ?u64, title: []const u8 };

const FileTags = struct {
    fields: Fields,
    pictures: usize,
    /// SHA-256 je Bild (für den Sync: hat sich das Cover geändert?)
    picture_hashes: []const []const u8,
    /// Kapitel aus den Tags (ID3 CHAP, Vorbis CHAPTERxxx, MP4 chpl)
    chapters: []const ChapterJson,
    /// Kann mync die Tags dieser Datei schreiben?
    writable: bool,
};

fn readTags(a: std.mem.Allocator, io: Io, path: []const u8) !FileTags {
    const t = try core.tags.readFile(a, io, Io.Dir.cwd(), path);
    var f: Fields = .{};
    for (t.fields) |x| try f.map.put(a, x.name, x.values);
    const ch = try a.alloc(ChapterJson, t.chapters.len);
    for (t.chapters, ch) |c, *o| o.* = .{ .start_ms = c.start_ms, .end_ms = c.end_ms, .title = c.title };
    const ph = try a.alloc([]const u8, t.pictures.len);
    for (t.pictures, ph) |p, *o| o.* = try a.dupe(u8, &p);
    return .{ .fields = f, .pictures = t.pictures.len, .picture_hashes = ph, .chapters = ch, .writable = core.writer.canWrite(path) };
}

/// Liest alle Tags einer Datei (inkl. Lyrics).
export fn mync_read_tags(path: [*:0]const u8) ?[*:0]u8 {
    return call(readTags, .{std.mem.span(path)});
}

fn writeTags(a: std.mem.Allocator, io: Io, path: []const u8, fields_json: []const u8, cover_arg: []const u8) !FileTags {
    const parsed = try std.json.parseFromSliceLeaky(Fields, a, fields_json, .{});
    var fields: std.ArrayList(core.tags.Field) = .empty;
    var it = parsed.map.iterator();
    while (it.next()) |kv| {
        if (core.tags.fieldIndex(kv.key_ptr.*) == null) return error.UnknownField;
        try fields.append(a, .{ .name = kv.key_ptr.*, .values = kv.value_ptr.* });
    }
    const cover: core.writer.Cover = if (cover_arg.len == 0)
        .keep
    else if (std.mem.eql(u8, cover_arg, "-"))
        .remove
    else
        .{ .set = try Io.Dir.cwd().readFileAlloc(io, cover_arg, a, .limited(32 << 20)) };
    try core.writer.writeFile(a, io, Io.Dir.cwd(), path, fields.items, cover);
    return readTags(a, io, path);
}

/// Ersetzt die Tags einer Datei. `fields_json`: {"title":["…"],"artist":["…","…"],…}
/// Nicht enthaltene Felder werden entfernt. `cover`: "" = Bilder behalten,
/// "-" = entfernen, sonst Pfad zu einem JPEG/PNG. Liefert die neu gelesenen Tags.
export fn mync_write_tags(path: [*:0]const u8, fields_json: [*:0]const u8, cover: [*:0]const u8) ?[*:0]u8 {
    return call(writeTags, .{ std.mem.span(path), std.mem.span(fields_json), std.mem.span(cover) });
}

fn extractCover(a: std.mem.Allocator, io: Io, path: []const u8, out_path: []const u8) !bool {
    const t = try core.tags.readFile(a, io, Io.Dir.cwd(), path);
    const pic = t.first_picture orelse return false;
    if (std.fs.path.dirname(out_path)) |d| try Io.Dir.cwd().createDirPath(io, d);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = pic });
    return true;
}

/// Schreibt das erste eingebettete Bild nach `out_path`; ok=false wenn keins da ist.
export fn mync_extract_cover(path: [*:0]const u8, out_path: [*:0]const u8) ?[*:0]u8 {
    return call(extractCover, .{ std.mem.span(path), std.mem.span(out_path) });
}

// ───────────────────────────── Updates ─────────────────────────────────────

fn verifySig(_: std.mem.Allocator, _: Io, public_hex: []const u8, msg: []const u8, sig_hex: []const u8) error{InvalidInput}!bool {
    return core.sign.verify(public_hex, msg, sig_hex);
}

/// Prüft eine Ed25519-Signatur (Schlüssel und Signatur hex): {"ok":true|false}
export fn mync_verify_ed25519(public_hex: [*:0]const u8, msg: [*:0]const u8, sig_hex: [*:0]const u8) ?[*:0]u8 {
    return call(verifySig, .{ std.mem.span(public_hex), std.mem.span(msg), std.mem.span(sig_hex) });
}

fn sha256(a: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    const h = try core.sign.sha256File(io, Io.Dir.cwd(), path);
    return a.dupe(u8, &h);
}

/// SHA-256 einer Datei (hex).
export fn mync_sha256_file(path: [*:0]const u8) ?[*:0]u8 {
    return call(sha256, .{std.mem.span(path)});
}

test "Fehler werden als JSON gemeldet" {
    const r = mync_scan("/gibt/es/nicht", "/tmp/mync-ffi-test/manifest.db").?;
    defer mync_free(r);
    try std.testing.expectEqualStrings("{\"error\":\"FileNotFound\"}", std.mem.span(r));
}

// ───────────────────────────── Sync ────────────────────────────────────────

const SyncEntry = struct {
    path: []const u8,
    audio_hash: []const u8,
    tag_hash: []const u8,
    file_id: []const u8 = "",
    size: u64 = 0,
};

fn manifestEntries(a: std.mem.Allocator, io: Io, root: []const u8, db: [:0]const u8) ![]SyncEntry {
    if (std.fs.path.dirname(db)) |d| try Io.Dir.cwd().createDirPath(io, d);
    const m = try core.manifest.Manifest.open(io, db, root);
    defer m.close();
    const rows = try m.files(a);
    const out = try a.alloc(SyncEntry, rows.len);
    for (rows, out) |r, *o| o.* = .{
        .path = r.entry.path,
        .audio_hash = r.entry.audio_hash,
        .tag_hash = r.entry.tag_hash,
        .file_id = r.file_id,
        .size = r.size,
    };
    return out;
}

/// Alle Dateien des Manifests mit Hashes (für den Sync-Abgleich).
export fn mync_manifest_entries(root: [*:0]const u8, db: [*:0]const u8) ?[*:0]u8 {
    return call(manifestEntries, .{ std.mem.span(root), std.mem.span(db) });
}

const PlanInput = struct {
    base: []const SyncEntry,
    local: []const SyncEntry,
    remote: []const SyncEntry,
};

fn toEntries(a: std.mem.Allocator, xs: []const SyncEntry) ![]core.diff.Entry {
    const out = try a.alloc(core.diff.Entry, xs.len);
    for (xs, out) |x, *o| o.* = .{ .path = x.path, .audio_hash = x.audio_hash, .tag_hash = x.tag_hash };
    return out;
}

fn syncPlan(a: std.mem.Allocator, _: Io, input_json: []const u8) ![]core.diff.Proposal {
    const in = try std.json.parseFromSliceLeaky(PlanInput, a, input_json, .{ .ignore_unknown_fields = true });
    const base = try toEntries(a, in.base);
    const local = try core.diff.changes(a, base, try toEntries(a, in.local));
    const remote = try core.diff.changes(a, base, try toEntries(a, in.remote));
    return core.diff.proposals(a, local, remote);
}

/// Vorschläge für das lokale Gerät: {"base":[…],"local":[…],"remote":[…]} → Proposals
export fn mync_sync_plan(input_json: [*:0]const u8) ?[*:0]u8 {
    return call(syncPlan, .{std.mem.span(input_json)});
}

// ─── Kryptografie (binär, ohne JSON) ───

const X25519 = std.crypto.dh.X25519;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

/// Erzeugt ein X25519-Schlüsselpaar (je 32 Byte).
export fn mync_x25519_keypair(secret_out: [*]u8, public_out: [*]u8) void {
    const kp = X25519.KeyPair.generate(threaded.io());
    @memcpy(secret_out[0..32], &kp.secret_key);
    @memcpy(public_out[0..32], &kp.public_key);
}

/// Gemeinsames Geheimnis; 0 = ok, -1 = ungültiger Schlüssel.
export fn mync_x25519(secret: [*]const u8, public: [*]const u8, out: [*]u8) c_int {
    const s = X25519.scalarmult(secret[0..32].*, public[0..32].*) catch return -1;
    @memcpy(out[0..32], &s);
    return 0;
}

/// Verschlüsselt [msg] → out (len + 16 Byte Tag am Ende).
export fn mync_aead_seal(key: [*]const u8, nonce: [*]const u8, ad: [*]const u8, ad_len: usize, msg: [*]const u8, len: usize, out: [*]u8) void {
    var tag: [Aead.tag_length]u8 = undefined;
    Aead.encrypt(out[0..len], &tag, msg[0..len], ad[0..ad_len], nonce[0..12].*, key[0..32].*);
    @memcpy(out[len .. len + 16], &tag);
}

/// Entschlüsselt und prüft; 0 = ok, -1 = manipuliert/falscher Schlüssel.
export fn mync_aead_open(key: [*]const u8, nonce: [*]const u8, ad: [*]const u8, ad_len: usize, ct: [*]const u8, len: usize, out: [*]u8) c_int {
    if (len < 16) return -1;
    const m = len - 16;
    Aead.decrypt(out[0..m], ct[0..m], ct[m..len][0..16].*, ad[0..ad_len], nonce[0..12].*, key[0..32].*) catch return -1;
    return 0;
}

/// HKDF-SHA256.
export fn mync_hkdf(salt: [*]const u8, salt_len: usize, ikm: [*]const u8, ikm_len: usize, info: [*]const u8, info_len: usize, out: [*]u8, out_len: usize) void {
    const prk = Hkdf.extract(salt[0..salt_len], ikm[0..ikm_len]);
    Hkdf.expand(out[0..out_len], info[0..info_len], prk);
}

/// SHA-256 über einen Speicherbereich.
export fn mync_sha256(data: [*]const u8, len: usize, out: [*]u8) void {
    std.crypto.hash.sha2.Sha256.hash(data[0..len], out[0..32], .{});
}

test "Sync-Plan über FFI" {
    const json =
        \\{"base":[{"path":"a.mp3","audio_hash":"A","tag_hash":"1"}],
        \\ "local":[{"path":"a.mp3","audio_hash":"A","tag_hash":"1"}],
        \\ "remote":[{"path":"neu/a.mp3","audio_hash":"A","tag_hash":"2"},{"path":"b.mp3","audio_hash":"B","tag_hash":"1"}]}
    ;
    const r = mync_sync_plan(json).?;
    defer mync_free(r);
    const s = std.mem.span(r);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"rename\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"add\"") != null);
}

test "AEAD und X25519 über FFI" {
    var sa: [32]u8 = undefined;
    var pa: [32]u8 = undefined;
    var sb: [32]u8 = undefined;
    var pb: [32]u8 = undefined;
    mync_x25519_keypair(&sa, &pa);
    mync_x25519_keypair(&sb, &pb);
    var k1: [32]u8 = undefined;
    var k2: [32]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), mync_x25519(&sa, &pb, &k1));
    try std.testing.expectEqual(@as(c_int, 0), mync_x25519(&sb, &pa, &k2));
    try std.testing.expectEqualSlices(u8, &k1, &k2);
    const nonce: [12]u8 = @splat(0);
    var ct: [21]u8 = undefined;
    mync_aead_seal(&k1, &nonce, "ad", 2, "hallo", 5, &ct);
    var pt: [5]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), mync_aead_open(&k2, &nonce, "ad", 2, &ct, 21, &pt));
    try std.testing.expectEqualStrings("hallo", &pt);
    ct[0] ^= 1;
    try std.testing.expectEqual(@as(c_int, -1), mync_aead_open(&k2, &nonce, "ad", 2, &ct, 21, &pt));
}
