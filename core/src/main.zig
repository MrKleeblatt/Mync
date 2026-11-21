//! Kommandozeilenwerkzeug zum Testen des Kerns.
//!
//!   mync scan   <musikordner> [db]   Bibliothek ins Manifest einlesen
//!   mync status <musikordner> [db]   Manifest auflisten
//!   mync hash   <datei>...           Hashes und Tags einzelner Dateien zeigen
//!   mync tag    <datei> feld=wert…   Tags setzen (feld= entfernt; cover=bild.jpg, cover= entfernt)
//!   mync keygen <schlüsseldatei>     Update-Signaturschlüssel erzeugen
//!   mync sign   <schlüsseldatei> <datei>   Datei signieren (→ <datei>.sig)
//!   mync verify <öffentlich-hex> <datei>   Signatur <datei>.sig prüfen
//!   mync chunk  <datei>              Bausteine für Teil-Updates (JSON: size, sha256, chunks)

const std = @import("std");
const Io = std.Io;
const core = @import("mync_core");

const usage =
    \\Aufruf:
    \\  mync scan|status <musikordner> [db]
    \\  mync hash <datei>...
    \\  mync keygen <schlüsseldatei>
    \\  mync sign <schlüsseldatei> <datei>
    \\  mync verify <öffentlicher-schlüssel-hex> <datei>
    \\  mync chunk <datei>
    \\  mync tag <datei> feld=wert...   (Felder: title artist album albumartist composer
    \\                                   genre date track tracktotal disc disctotal comment lyrics description;
    \\                                   cover=bild.jpg setzt das Cover, cover= entfernt es)
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
    } else if (std.mem.eql(u8, cmd, "keygen")) {
        const k = core.sign.generate(io);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = &k.seed });
        try w.print("Geheimer Schlüssel: {s} (geheim halten, z. B. als GitHub-Secret MYNC_UPDATE_KEY)\n", .{args[2]});
        try w.print("Öffentlicher Schlüssel: {s}\n", .{&k.public});
    } else if (std.mem.eql(u8, cmd, "sign") and args.len >= 4) {
        const seed = try Io.Dir.cwd().readFileAlloc(io, args[2], a, .limited(1024));
        const msg = try Io.Dir.cwd().readFileAlloc(io, args[3], a, .unlimited);
        const sig = try core.sign.sign(seed, msg);
        const out = try std.fmt.allocPrint(a, "{s}.sig", .{args[3]});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = &sig });
        try w.print("Signatur: {s}\n", .{out});
    } else if (std.mem.eql(u8, cmd, "verify") and args.len >= 4) {
        const msg = try Io.Dir.cwd().readFileAlloc(io, args[3], a, .unlimited);
        const sig = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}.sig", .{args[3]}), a, .limited(1024));
        const ok = core.sign.verify(args[2], msg, sig);
        try w.print("{s}\n", .{if (ok) "Signatur gültig" else "Signatur UNGÜLTIG"});
        return if (ok) 0 else 1;
    } else if (std.mem.eql(u8, cmd, "chunk")) {
        // Bausteinliste wie in Kassenbon: {"size","sha256","chunks":[[hash, länge], …]}
        const data = try Io.Dir.cwd().readFileAlloc(io, args[2], a, .unlimited);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        const chunks = try core.chunker.split(a, data);
        try w.print("{{\"size\":{d},\"sha256\":\"{s}\",\"chunks\":[", .{ data.len, &std.fmt.bytesToHex(digest, .lower) });
        for (chunks, 0..) |c, i| {
            try w.print("{s}[\"{s}\",{d}]", .{ if (i == 0) "" else ",", &c.hash, c.len });
        }
        try w.writeAll("]}\n");
    } else if (std.mem.eql(u8, cmd, "tag")) {
        const p = args[2];
        const old = try core.tags.readFile(a, io, Io.Dir.cwd(), p);
        var map: std.StringArrayHashMapUnmanaged([]const []const u8) = .empty;
        var cover: core.writer.Cover = .keep;
        for (old.fields) |f| try map.put(a, f.name, f.values);
        for (args[3..]) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse {
                try w.print("Ungültig (feld=wert erwartet): {s}\n", .{kv});
                return 2;
            };
            const name = kv[0..eq];
            if (std.mem.eql(u8, name, "cover")) {
                cover = if (eq + 1 == kv.len) .remove else .{ .set = Io.Dir.cwd().readFileAlloc(io, kv[eq + 1 ..], a, .limited(32 << 20)) catch |err| {
                    try w.print("Bild nicht lesbar: {t}\n", .{err});
                    return 1;
                } };
                continue;
            }
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
        core.writer.writeFile(a, io, Io.Dir.cwd(), p, fields.items, cover) catch |err| {
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
