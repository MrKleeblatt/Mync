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
    /// Kapitel aus den Tags (ID3 CHAP, Vorbis CHAPTERxxx, MP4 chpl)
    chapters: []const ChapterJson,
    /// Kann mync die Tags dieser Datei schreiben?
    writable: bool,
};

fn readTags(a: std.mem.Allocator, io: Io, path: []const u8) !FileTags {
    const t = try core.tags.readFile(a, io, Io.Dir.cwd(), path);
    var f: Fields = .{};
    for (t.fields) |x| try f.map.put(a, x.name, x.values);
    const fmt = core.audiohash.Format.fromPath(path);
    const ch = try a.alloc(ChapterJson, t.chapters.len);
    for (t.chapters, ch) |c, *o| o.* = .{ .start_ms = c.start_ms, .end_ms = c.end_ms, .title = c.title };
    return .{ .fields = f, .pictures = t.pictures.len, .chapters = ch, .writable = fmt == .mp3 or fmt == .flac };
}

/// Liest alle Tags einer Datei (inkl. Lyrics).
export fn mync_read_tags(path: [*:0]const u8) ?[*:0]u8 {
    return call(readTags, .{std.mem.span(path)});
}

fn writeTags(a: std.mem.Allocator, io: Io, path: []const u8, fields_json: []const u8) !FileTags {
    const parsed = try std.json.parseFromSliceLeaky(Fields, a, fields_json, .{});
    var fields: std.ArrayList(core.tags.Field) = .empty;
    var it = parsed.map.iterator();
    while (it.next()) |kv| {
        if (core.tags.fieldIndex(kv.key_ptr.*) == null) return error.UnknownField;
        try fields.append(a, .{ .name = kv.key_ptr.*, .values = kv.value_ptr.* });
    }
    try core.writer.writeFile(a, io, Io.Dir.cwd(), path, fields.items);
    return readTags(a, io, path);
}

/// Ersetzt die Tags einer Datei. `fields_json`: {"title":["…"],"artist":["…","…"],…}
/// Nicht enthaltene Felder werden entfernt. Liefert die neu gelesenen Tags.
export fn mync_write_tags(path: [*:0]const u8, fields_json: [*:0]const u8) ?[*:0]u8 {
    return call(writeTags, .{ std.mem.span(path), std.mem.span(fields_json) });
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

test "Fehler werden als JSON gemeldet" {
    const r = mync_scan("/gibt/es/nicht", "/tmp/mync-ffi-test/manifest.db").?;
    defer mync_free(r);
    try std.testing.expectEqualStrings("{\"error\":\"FileNotFound\"}", std.mem.span(r));
}
