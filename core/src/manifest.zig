//! Manifest: SQLite-Datenbank mit einem Eintrag pro Datei der Musikbibliothek.
//!
//! Der Scan ist inkrementell: Hashes werden nur neu berechnet, wenn sich
//! Größe oder Änderungszeit einer Datei geändert haben. Eine verschobene
//! Datei (gleicher `audio_hash`, neuer Pfad) behält ihre `file_id`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite.zig");
const audiohash = @import("audiohash.zig");
const tags_mod = @import("tags.zig");
const diff = @import("diff.zig");
const duration = @import("duration.zig");

pub const extensions = [_][]const u8{
    "mp3", "flac", "ogg", "oga", "opus", "m4a", "m4b", "mp4", "aac", "wav", "lrc", "m3u", "m3u8",
};

const schema =
    \\PRAGMA journal_mode=WAL;
    \\CREATE TABLE IF NOT EXISTS file (
    \\  file_id    TEXT PRIMARY KEY,
    \\  path       TEXT UNIQUE NOT NULL,
    \\  size       INTEGER NOT NULL,
    \\  mtime_ns   INTEGER NOT NULL,
    \\  audio_hash TEXT NOT NULL,
    \\  tag_hash   TEXT NOT NULL,
    \\  tags_json  TEXT NOT NULL,
    \\  seq        INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
;

/// Spalten, die nach der ersten Version hinzukamen: (Name, Definition).
/// duration_ms: -2 = noch nicht berechnet (→ wird beim nächsten Scan ermittelt), -1 = unbekannt.
/// added_ms: Zeitpunkt, an dem die Datei zum ersten Mal gesehen wurde.
const migrations = [_][2][]const u8{
    .{ "duration_ms", "ALTER TABLE file ADD COLUMN duration_ms INTEGER NOT NULL DEFAULT -2" },
    .{ "added_ms", "ALTER TABLE file ADD COLUMN added_ms INTEGER NOT NULL DEFAULT 0" },
};

const not_computed: i64 = -2;

pub const FileRow = struct {
    file_id: []const u8,
    entry: diff.Entry,
    /// Tags als JSON (siehe `tags.Tags.writeJson`).
    tags_json: []const u8,
    size: u64,
    mtime_ns: i64,
    /// Dauer in ms, -1 wenn unbekannt.
    duration_ms: i64 = -1,
    /// Erstmals gesehen (Unix-Zeit in ms).
    added_ms: i64 = 0,
};

pub const ScanError = struct { path: []const u8, message: []const u8 };

pub const ScanReport = struct {
    total: u32 = 0,
    hashed: u32 = 0,
    added: u32 = 0,
    removed: u32 = 0,
    errors: []const ScanError = &.{},
};

pub const Manifest = struct {
    db: sqlite.Db,
    io: Io,
    root: []const u8,
    /// Ausschlussmuster (siehe `isExcluded`), vor `scan` setzen.
    excludes: []const []const u8 = &.{},
    /// Fortschritt (wird während `scan` aus anderen Threads gelesen).
    progress: ?*ScanProgress = null,

    pub fn open(io: Io, db_path: [:0]const u8, root: []const u8) !Manifest {
        const db = try sqlite.Db.open(db_path);
        errdefer db.close();
        try db.exec(schema);
        for (migrations) |mig| {
            const q = try db.prepare("SELECT COUNT(*) FROM pragma_table_info('file') WHERE name=?1");
            defer q.deinit();
            try q.bind(.{mig[0]});
            if (try q.step() and q.int(0) == 0) {
                var buf: [128]u8 = undefined;
                try db.exec(try std.fmt.bufPrintSentinel(&buf, "{s}", .{mig[1]}, 0));
                if (std.mem.eql(u8, mig[0], "added_ms")) {
                    try db.exec("UPDATE file SET added_ms = mtime_ns / 1000000");
                }
            }
        }
        return .{ .db = db, .io = io, .root = root };
    }

    pub fn close(m: Manifest) void {
        m.db.close();
    }

    /// Alle Einträge, nach Pfad sortiert. Speicher gehört `gpa` (Arena empfohlen).
    pub fn files(m: Manifest, gpa: Allocator) ![]FileRow {
        const st = try m.db.prepare(
            "SELECT file_id,path,audio_hash,tag_hash,tags_json,size,mtime_ns,duration_ms,added_ms FROM file ORDER BY path",
        );
        defer st.deinit();
        var out: std.ArrayList(FileRow) = .empty;
        while (try st.step()) {
            try out.append(gpa, .{
                .file_id = try gpa.dupe(u8, st.text(0)),
                .entry = .{
                    .path = try gpa.dupe(u8, st.text(1)),
                    .audio_hash = try gpa.dupe(u8, st.text(2)),
                    .tag_hash = try gpa.dupe(u8, st.text(3)),
                },
                .tags_json = try gpa.dupe(u8, st.text(4)),
                .size = @intCast(st.int(5)),
                .mtime_ns = st.int(6),
                .duration_ms = st.int(7),
                .added_ms = st.int(8),
            });
        }
        return out.items;
    }

    pub fn entries(m: Manifest, gpa: Allocator) ![]diff.Entry {
        const rows = try m.files(gpa);
        const out = try gpa.alloc(diff.Entry, rows.len);
        for (rows, out) |r, *e| e.* = r.entry;
        return out;
    }

    fn nextSeq(m: Manifest) !i64 {
        const sel = try m.db.prepare("SELECT value FROM meta WHERE key='seq'");
        defer sel.deinit();
        const cur: i64 = if (try sel.step()) std.fmt.parseInt(i64, sel.text(0), 10) catch 0 else 0;
        var buf: [24]u8 = undefined;
        const up = try m.db.prepare(
            "INSERT INTO meta(key,value) VALUES('seq',?1) ON CONFLICT(key) DO UPDATE SET value=?1",
        );
        defer up.deinit();
        try up.run(.{try std.fmt.bufPrint(&buf, "{d}", .{cur + 1})});
        return cur + 1;
    }

    /// Durchsucht die Bibliothek und aktualisiert das Manifest.
    /// `gpa` sollte eine Arena sein; der Bericht lebt in ihr.
    pub fn scan(m: Manifest, gpa: Allocator) !ScanReport {
        const io = m.io;
        var report: ScanReport = .{};
        var errors: std.ArrayList(ScanError) = .empty;

        var known: std.StringHashMapUnmanaged(FileRow) = .empty;
        for (try m.files(gpa)) |f| try known.put(gpa, f.entry.path, f);
        var seen: std.StringHashMapUnmanaged(void) = .empty;

        const Fresh = struct { row: FileRow };
        var fresh: std.ArrayList(Fresh) = .empty;
        var jobs: std.ArrayList(HashJob) = .empty;
        const prog = m.progress;

        var root_dir = try Io.Dir.cwd().openDir(io, m.root, .{ .iterate = true });
        defer root_dir.close(io);
        var walker = try root_dir.walkSelectively(gpa);
        defer walker.deinit();

        while (true) {
            const ent = walker.next(io) catch |err| {
                try errors.append(gpa, .{ .path = "", .message = @errorName(err) });
                continue;
            } orelse break;
            switch (ent.kind) {
                .directory => {
                    if (ent.basename.len > 0 and ent.basename[0] == '.') continue; // .mync, .trash …
                    if (isExcluded(m.excludes, try relPath(gpa, ent.path), ent.basename)) continue;
                    walker.enter(io, ent) catch |err| {
                        try errors.append(gpa, .{ .path = try gpa.dupe(u8, ent.path), .message = @errorName(err) });
                    };
                    continue;
                },
                .file, .sym_link => {},
                else => continue,
            }
            if (!hasKnownExt(ent.basename)) continue;
            const rel = try relPath(gpa, ent.path);
            if (isExcluded(m.excludes, rel, ent.basename)) continue;
            const st = ent.dir.statFile(io, ent.basename, .{}) catch |err| {
                try errors.append(gpa, .{ .path = rel, .message = @errorName(err) });
                continue;
            };
            if (st.kind != .file) continue;
            report.total += 1;
            if (prog) |p| _ = @atomicRmw(u32, &p.found, .Add, 1, .monotonic);
            try seen.put(gpa, rel, {});
            const mtime_ns: i64 = @intCast(st.mtime.nanoseconds);
            if (known.get(rel)) |k| {
                if (k.size == st.size and k.mtime_ns == mtime_ns and k.duration_ms != not_computed) continue; // unverändert
            }
            report.hashed += 1;
            try jobs.append(gpa, .{ .rel = rel, .size = st.size, .mtime_ns = mtime_ns });
        }

        // Neue/geänderte Dateien parallel hashen (ein Thread je CPU-Kern)
        var pool: HashPool = .{ .root = root_dir, .jobs = jobs.items, .progress = prog };
        defer pool.deinit();
        if (prog) |p| @atomicStore(u32, &p.total, @intCast(jobs.items.len), .release);
        try pool.run(io);
        for (jobs.items) |j| {
            if (j.err) |e| {
                try errors.append(gpa, .{ .path = j.rel, .message = e });
                continue;
            }
            try fresh.append(gpa, .{ .row = .{
                .file_id = "",
                .entry = .{ .path = j.rel, .audio_hash = try gpa.dupe(u8, j.audio_hash), .tag_hash = try gpa.dupe(u8, j.tag_hash) },
                .tags_json = try gpa.dupe(u8, j.tags_json),
                .size = j.size,
                .mtime_ns = j.mtime_ns,
                .duration_ms = j.duration_ms,
            } });
        }

        // Verschwundene Dateien entfernen (ggf. gleich als Umbenennung wiederverwendet).
        var vanished: std.ArrayList(FileRow) = .empty;
        var kit = known.valueIterator();
        while (kit.next()) |k| if (!seen.contains(k.entry.path)) try vanished.append(gpa, k.*);

        try m.db.exec("BEGIN");
        errdefer m.db.exec("ROLLBACK") catch {};
        const del = try m.db.prepare("DELETE FROM file WHERE file_id=?1");
        defer del.deinit();
        for (vanished.items) |v| try del.run(.{v.file_id});

        const ins = try m.db.prepare(
            \\INSERT INTO file(file_id,path,size,mtime_ns,audio_hash,tag_hash,tags_json,seq,duration_ms,added_ms)
            \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
            \\ON CONFLICT(file_id) DO UPDATE SET path=?2,size=?3,mtime_ns=?4,
            \\  audio_hash=?5,tag_hash=?6,tags_json=?7,seq=?8,duration_ms=?9
        );
        defer ins.deinit();
        const now_ms: i64 = @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
        for (fresh.items) |*f| {
            var r = &f.row;
            var id: ?[]const u8 = if (known.get(r.entry.path)) |k| k.file_id else null;
            if (id == null) {
                for (vanished.items, 0..) |v, i| {
                    if (std.mem.eql(u8, v.entry.audio_hash, r.entry.audio_hash)) {
                        id = v.file_id;
                        _ = vanished.swapRemove(i);
                        break;
                    }
                } else report.added += 1;
            }
            r.file_id = id orelse try newUuid(gpa, io);
            const seq = try m.nextSeq();
            try ins.run(.{
                r.file_id,           r.entry.path,      r.size,     r.mtime_ns,
                r.entry.audio_hash,  r.entry.tag_hash,  r.tags_json, seq,
                r.duration_ms,       now_ms,
            });
        }
        try m.db.exec("COMMIT");
        report.removed = @intCast(vanished.items.len);
        report.errors = errors.items;
        return report;
    }
};

/// Ausschlussmuster: `*` (ohne `/`), `**` (beliebig), `?`; Groß-/Klein-
/// schreibung egal. Ein Muster ohne `/` gilt für jeden Datei- oder
/// Ordnernamen (z. B. `*.wav`, `Hörproben`), mit `/` für den Pfad ab dem
/// Musikordner (z. B. `Hörbücher/Alt`, `Podcasts/**/*.mp3`).
pub fn isExcluded(excludes: []const []const u8, rel: []const u8, basename: []const u8) bool {
    for (excludes) |raw| {
        var pat = std.mem.trim(u8, raw, " \t\r\n");
        while (pat.len > 0 and pat[0] == '/') pat = pat[1..];
        while (pat.len > 0 and pat[pat.len - 1] == '/') pat = pat[0 .. pat.len - 1];
        if (pat.len == 0) continue;
        const target = if (std.mem.indexOfScalar(u8, pat, '/') == null) basename else rel;
        if (globMatch(pat, target)) return true;
    }
    return false;
}

pub fn globMatch(pat: []const u8, s: []const u8) bool {
    if (pat.len == 0) return s.len == 0;
    if (pat[0] == '*') {
        const deep = pat.len > 1 and pat[1] == '*';
        const rest = pat[if (deep) 2 else 1..];
        // „**/“ darf auch null Ordner bedeuten
        if (deep and rest.len > 0 and rest[0] == '/' and globMatch(rest[1..], s)) return true;
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (globMatch(rest, s[i..])) return true;
            if (i < s.len and !deep and s[i] == '/') return false;
        }
        return false;
    }
    if (s.len == 0) return false;
    if (pat[0] == '?') return s[0] != '/' and globMatch(pat[1..], s[1..]);
    if (std.ascii.toLower(pat[0]) != std.ascii.toLower(s[0])) return false;
    return globMatch(pat[1..], s[1..]);
}

test "Ausschlussmuster" {
    const t = std.testing;
    const ex = [_][]const u8{ "*.wav", "Hörproben", "Hörbücher/Alt", "Podcasts/**/*.mp3", " /Temp/ " };
    try t.expect(isExcluded(&ex, "a/b/x.WAV", "x.WAV"));
    try t.expect(isExcluded(&ex, "a/Hörproben", "Hörproben"));
    try t.expect(isExcluded(&ex, "Hörbücher/Alt", "Alt"));
    try t.expect(!isExcluded(&ex, "Rock/Alt", "Alt"));
    try t.expect(isExcluded(&ex, "Podcasts/x.mp3", "x.mp3"));
    try t.expect(isExcluded(&ex, "Podcasts/2024/03/x.mp3", "x.mp3"));
    try t.expect(!isExcluded(&ex, "Podcasts/2024/x.opus", "x.opus"));
    try t.expect(isExcluded(&ex, "Temp", "Temp"));
    try t.expect(!isExcluded(&ex, "Rock/a.flac", "a.flac"));
    try t.expect(globMatch("a*c", "abbc"));
    try t.expect(!globMatch("a*c", "ab/c"));
    try t.expect(globMatch("a?c", "abc"));
}

fn hasKnownExt(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    if (ext.len < 2) return false;
    for (extensions) |e| if (std.ascii.eqlIgnoreCase(e, ext[1..])) return true;
    return false;
}

/// Relativer Pfad mit `/` als Trenner – auf allen Geräten gleich.
fn relPath(gpa: Allocator, p: []const u8) ![]const u8 {
    const out = try gpa.dupe(u8, p);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
    return out;
}

pub const Hashed = struct {
    audio_hash: []const u8,
    tag_hash: []const u8,
    tags_json: []const u8,
    tags: tags_mod.Tags,
};

/// Berechnet `audio_hash`, Tags und `tag_hash` einer Datei.
/// Fortschritt eines Scans: gefundene Audiodateien, davon zu hashen, fertig.
pub const ScanProgress = extern struct {
    found: u32 = 0,
    total: u32 = 0,
    done: u32 = 0,
};

const HashJob = struct {
    rel: []const u8,
    size: u64,
    mtime_ns: i64,
    audio_hash: []const u8 = "",
    tag_hash: []const u8 = "",
    tags_json: []const u8 = "",
    duration_ms: i64 = -1,
    err: ?[]const u8 = null,
};

/// Hasht Dateien parallel. Jeder Thread hat ein eigenes `Io` und eine
/// eigene Arena für die Ergebnisse; das Lesen einer Datei (inkl. Covern)
/// geschieht in einer Wegwerf-Arena, damit der Speicher nicht mit der
/// Größe der Bibliothek wächst.
const HashPool = struct {
    root: Io.Dir,
    jobs: []HashJob,
    progress: ?*ScanProgress,
    next: usize = 0,
    arenas: [max_threads]std.heap.ArenaAllocator = undefined,
    used: usize = 0,

    const max_threads = 8;

    fn deinit(p: *HashPool) void {
        for (p.arenas[0..p.used]) |*a| a.deinit();
    }

    fn run(p: *HashPool, io: Io) !void {
        _ = io;
        if (p.jobs.len == 0) return;
        const cpus = std.Thread.getCpuCount() catch 1;
        const n = @max(1, @min(@min(cpus, max_threads), p.jobs.len));
        for (0..n) |i| p.arenas[i] = .init(std.heap.page_allocator);
        p.used = n;
        var threads: [max_threads]?std.Thread = @splat(null);
        for (1..n) |i| {
            threads[i] = std.Thread.spawn(.{ .stack_size = 2 << 20 }, work, .{ p, i }) catch null;
        }
        work(p, 0); // der aufrufende Thread arbeitet mit
        for (threads[1..n]) |t| if (t) |th| th.join();
    }

    fn work(p: *HashPool, slot: usize) void {
        var threaded: Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const keep = p.arenas[slot].allocator();
        var tmp: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer tmp.deinit();
        while (true) {
            const i = @atomicRmw(usize, &p.next, .Add, 1, .monotonic);
            if (i >= p.jobs.len) break;
            const j = &p.jobs[i];
            _ = tmp.reset(.retain_capacity);
            const a = tmp.allocator();
            if (hashFile(a, io, p.root, j.rel)) |h| {
                j.audio_hash = keep.dupe(u8, h.audio_hash) catch "";
                j.tag_hash = keep.dupe(u8, h.tag_hash) catch "";
                j.tags_json = keep.dupe(u8, h.tags_json) catch "";
                j.duration_ms = if (duration.ofFile(io, p.root, j.rel)) |d| @intCast(d) else -1;
                if (j.audio_hash.len == 0 or j.tags_json.len == 0) j.err = "OutOfMemory";
            } else |err| {
                j.err = @errorName(err);
            }
            if (p.progress) |pr| _ = @atomicRmw(u32, &pr.done, .Add, 1, .monotonic);
        }
    }
};

pub fn hashFile(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) !Hashed {
    const a = try audiohash.hashFile(io, dir, path);
    const t = try tags_mod.readFile(gpa, io, dir, path);
    var aw: Io.Writer.Allocating = .init(gpa);
    try t.writeJson(&aw.writer);
    const th = try t.hash();
    return .{
        .audio_hash = try gpa.dupe(u8, &a.hash),
        .tag_hash = try gpa.dupe(u8, &th),
        .tags_json = aw.written(),
        .tags = t,
    };
}

fn newUuid(gpa: Allocator, io: Io) ![]const u8 {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40; // Version 4
    b[8] = (b[8] & 0x3f) | 0x80; // Variante RFC 4122
    const h = std.fmt.bytesToHex(b, .lower);
    return std.fmt.allocPrint(gpa, "{s}-{s}-{s}-{s}-{s}", .{ h[0..8], h[8..12], h[12..16], h[16..20], h[20..32] });
}
