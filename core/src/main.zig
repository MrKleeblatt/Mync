//! Kommandozeilenwerkzeug zum Testen des Kerns.
//!
//!   mync scan   <musikordner> [db]   Bibliothek ins Manifest einlesen
//!   mync status <musikordner> [db]   Manifest auflisten
//!   mync hash   <datei>...           Hashes und Tags einzelner Dateien zeigen
//!   mync tag    <datei> feld=wert…   Tags setzen (feld= entfernt; MP3, FLAC)

const std = @import("std");
const Io = std.Io;
const core = @import("mync_core");

const usage =
    \\Aufruf:
    \\  mync scan|status <musikordner> [db]
    \\  mync hash <datei>...
    \\  mync tag <datei> feld=wert...   (Felder: title artist album albumartist composer
    \\                                   genre date track tracktotal disc disctotal comment lyrics)
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    if (args.len < 3) {
        try w.writeAll(usage);
        return 2;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "scan") or std.mem.eql(u8, cmd, "status")) {
        const root = args[2];
        const db: [:0]const u8 = if (args.len > 3)
            try a.dupeSentinel(u8, args[3], 0)
        else
            try std.fmt.allocPrintSentinel(a, "{s}/.mync/manifest.db", .{root}, 0);
        if (std.fs.path.dirname(db)) |d| try Io.Dir.cwd().createDirPath(io, d);
        const m = try core.manifest.Manifest.open(io, db, root);
        defer m.close();
        if (std.mem.eql(u8, cmd, "scan")) {
            const r = try m.scan(a);
            try w.print("{d} Dateien, {d} neu gehasht, {d} neu, {d} entfernt, {d} Fehler\n", .{
                r.total, r.hashed, r.added, r.removed, r.errors.len,
            });
            for (r.errors) |e| try w.print("  Fehler: {s}: {s}\n", .{ e.path, e.message });
        } else {
            for (try m.files(a)) |f| {
                try w.print("{s}  {s}  {s}\n", .{ f.entry.audio_hash[0..12], f.entry.tag_hash[0..12], f.entry.path });
            }
        }
    } else if (std.mem.eql(u8, cmd, "hash")) {
        for (args[2..]) |p| {
            const r = try core.audiohash.hashFile(io, Io.Dir.cwd(), p);
            const t = try core.tags.readFile(a, io, Io.Dir.cwd(), p);
            try w.print("{s}\n  audio_hash ({t}): {s}\n  tag_hash: {s}\n", .{ p, r.kind, &r.hash, &(try t.hash()) });
            if (core.duration.ofFile(io, Io.Dir.cwd(), p)) |d| try w.print("  dauer: {d}.{d:0>3} s\n", .{ d / 1000, d % 1000 });
            for (t.fields) |f| {
                try w.print("  {s}: ", .{f.name});
                for (f.values, 0..) |v, i| try w.print("{s}{s}", .{ if (i > 0) "; " else "", v });
                try w.writeByte('\n');
            }
            if (t.pictures.len > 0) try w.print("  Bilder: {d}\n", .{t.pictures.len});
            for (t.chapters) |c| try w.print("  Kapitel {d}:{d:0>2}.{d:0>3} {s}\n", .{ c.start_ms / 60000, c.start_ms / 1000 % 60, c.start_ms % 1000, c.title });
        }
    } else if (std.mem.eql(u8, cmd, "tag")) {
        const p = args[2];
        const old = try core.tags.readFile(a, io, Io.Dir.cwd(), p);
        var map: std.StringArrayHashMapUnmanaged([]const []const u8) = .empty;
        for (old.fields) |f| try map.put(a, f.name, f.values);
        for (args[3..]) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse {
                try w.print("Ungültig (feld=wert erwartet): {s}\n", .{kv});
                return 2;
            };
            const name = kv[0..eq];
            if (core.tags.fieldIndex(name) == null) {
                try w.print("Unbekanntes Feld: {s}\n", .{name});
                return 2;
            }
            if (eq + 1 == kv.len) {
                _ = map.orderedRemove(name);
            } else {
                const vals = try a.alloc([]const u8, 1);
                vals[0] = kv[eq + 1 ..];
                try map.put(a, name, vals);
            }
        }
        var fields: std.ArrayList(core.tags.Field) = .empty;
        for (map.keys(), map.values()) |k, v| try fields.append(a, .{ .name = k, .values = v });
        core.writer.writeFile(a, io, Io.Dir.cwd(), p, fields.items) catch |err| {
            try w.print("Fehler: {t}\n", .{err});
            return 1;
        };
        try w.print("Tags geschrieben: {s}\n", .{p});
    } else {
        try w.writeAll(usage);
        return 2;
    }
    return 0;
}
