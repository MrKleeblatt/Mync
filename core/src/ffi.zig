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
    return "0.1.0";
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

const TrackInfo = struct {
    file_id: []const u8,
    path: []const u8,
    title: ?[]const u8,
    artist: ?[]const u8,
    album: ?[]const u8,
    track: ?[]const u8,
};

const TagsJson = struct { fields: std.json.ArrayHashMap([]const []const u8) };

fn listTracks(a: std.mem.Allocator, io: Io, root: []const u8, db: [:0]const u8) ![]TrackInfo {
    if (std.fs.path.dirname(db)) |d| try Io.Dir.cwd().createDirPath(io, d);
    const m = try core.manifest.Manifest.open(io, db, root);
    defer m.close();
    const rows = try m.files(a);
    const out = try a.alloc(TrackInfo, rows.len);
    for (rows, out) |r, *o| {
        const t = std.json.parseFromSliceLeaky(TagsJson, a, r.tags_json, .{ .ignore_unknown_fields = true }) catch
            TagsJson{ .fields = .{} };
        const get = struct {
            fn f(al: std.mem.Allocator, tj: TagsJson, k: []const u8) !?[]const u8 {
                const v = tj.fields.map.get(k) orelse return null;
                return try std.mem.join(al, "; ", v);
            }
        }.f;
        o.* = .{
            .file_id = r.file_id,
            .path = r.entry.path,
            .title = try get(a, t, "title"),
            .artist = try get(a, t, "artist"),
            .album = try get(a, t, "album"),
            .track = try get(a, t, "track"),
        };
    }
    return out;
}

/// Liefert alle Titel aus dem Manifest, sortiert nach Pfad.
export fn mync_list_tracks(root: [*:0]const u8, db: [*:0]const u8) ?[*:0]u8 {
    return call(listTracks, .{ std.mem.span(root), std.mem.span(db) });
}

test "Fehler werden als JSON gemeldet" {
    const r = mync_scan("/gibt/es/nicht", "/tmp/mync-ffi-test/manifest.db").?;
    defer mync_free(r);
    try std.testing.expectEqualStrings("{\"error\":\"FileNotFound\"}", std.mem.span(r));
}
