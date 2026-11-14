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

pub const FileRow = struct {
    file_id: []const u8,
    entry: diff.Entry,
    /// Tags als JSON (siehe `tags.Tags.writeJson`).
    tags_json: []const u8,
    size: u64,
    mtime_ns: i64,
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

    pub fn open(io: Io, db_path: [:0]const u8, root: []const u8) !Manifest {
        const db = try sqlite.Db.open(db_path);
        errdefer db.close();
        try db.exec(schema);
        return .{ .db = db, .io = io, .root = root };
    }

    pub fn close(m: Manifest) void {
        m.db.close();
    }

    /// Alle Einträge, nach Pfad sortiert. Speicher gehört `gpa` (Arena empfohlen).
    pub fn files(m: Manifest, gpa: Allocator) ![]FileRow {
        const st = try m.db.prepare(
            "SELECT file_id,path,audio_hash,tag_hash,tags_json,size,mtime_ns FROM file ORDER BY path",
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
            const st = ent.dir.statFile(io, ent.basename, .{}) catch |err| {
                try errors.append(gpa, .{ .path = rel, .message = @errorName(err) });
                continue;
            };
            if (st.kind != .file) continue;
            report.total += 1;
            try seen.put(gpa, rel, {});
            const mtime_ns: i64 = @intCast(st.mtime.nanoseconds);
            if (known.get(rel)) |k| {
                if (k.size == st.size and k.mtime_ns == mtime_ns) continue; // unverändert
            }
            report.hashed += 1;
            const h = hashFile(gpa, io, ent.dir, ent.basename) catch |err| {
                try errors.append(gpa, .{ .path = rel, .message = @errorName(err) });
                continue;
            };
            try fresh.append(gpa, .{ .row = .{
                .file_id = "",
                .entry = .{ .path = rel, .audio_hash = h.audio_hash, .tag_hash = h.tag_hash },
                .tags_json = h.tags_json,
                .size = st.size,
                .mtime_ns = mtime_ns,
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
            \\INSERT INTO file(file_id,path,size,mtime_ns,audio_hash,tag_hash,tags_json,seq)
            \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8)
            \\ON CONFLICT(file_id) DO UPDATE SET path=?2,size=?3,mtime_ns=?4,
            \\  audio_hash=?5,tag_hash=?6,tags_json=?7,seq=?8
        );
        defer ins.deinit();
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
            });
        }
        try m.db.exec("COMMIT");
        report.removed = @intCast(vanished.items.len);
        report.errors = errors.items;
        return report;
    }
};

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
