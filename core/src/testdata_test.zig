//! Tests mit echten Audiodateien aus `core/testdata/` (erzeugt von
//! `tools/make_testdata.py` mit ffmpeg und mutagen als unabhängiger Referenz).

const std = @import("std");
const Io = std.Io;
const t = std.testing;
const options = @import("build_options");
const audiohash = @import("audiohash.zig");
const tags = @import("tags.zig");
const manifest = @import("manifest.zig");
const diff = @import("diff.zig");

fn openTestdata() !Io.Dir {
    return Io.Dir.cwd().openDir(t.io, options.testdata_dir, .{});
}

fn expectedValue(arena: std.mem.Allocator, got: []const []const u8, want: []const u8) !void {
    try t.expectEqual(@as(usize, 1), got.len);
    if (std.mem.startsWith(u8, want, "sha256:")) {
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(got[0], &h, .{});
        const hex = std.fmt.bytesToHex(h, .lower);
        try t.expectEqualStrings(want[7..], &hex);
    } else {
        _ = arena;
        try t.expectEqualStrings(want, got[0]);
    }
}

test "Testdateien: Audio-Hash stabil, Tags korrekt gelesen" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try openTestdata();
    defer dir.close(t.io);

    const json = try dir.readFileAlloc(t.io, "expected.json", a, .unlimited);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const files = parsed.object.get("files").?.object;

    var group_hash: std.StringHashMapUnmanaged([64]u8) = .empty;
    var tag_hashes: std.StringHashMapUnmanaged(void) = .empty;
    var it = files.iterator();
    var count: usize = 0;
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        const exp = kv.value_ptr.object;
        const group = exp.get("group").?.string;
        errdefer std.debug.print("Datei: {s}\n", .{name});

        // Audio-Hash: in jeder Gruppe gleich, und nie „ganze Datei“
        const r = try audiohash.hashFile(t.io, dir, name);
        try t.expect(r.kind != .whole_file);
        const gop = try group_hash.getOrPut(a, group);
        if (gop.found_existing) {
            try t.expectEqualStrings(&gop.value_ptr.*, &r.hash);
        } else gop.value_ptr.* = r.hash;

        // Tags: genau die erwarteten Felder
        const tg = try tags.readFile(a, t.io, dir, name);
        const want = exp.get("fields").?.object;
        if (exp.get("skip_fields") == null) try t.expectEqual(want.count(), tg.fields.len);
        var wit = want.iterator();
        while (wit.next()) |w| {
            errdefer std.debug.print("Feld: {s}\n", .{w.key_ptr.*});
            const got = tg.get(w.key_ptr.*) orelse return error.FieldMissing;
            try expectedValue(a, got, w.value_ptr.string);
        }
        try t.expectEqual(@as(usize, @intCast(exp.get("pictures").?.integer)), tg.pictures.len);

        // Kapitel
        const want_ch = if (exp.get("chapters")) |c| c.array.items else &[_]std.json.Value{};
        try t.expectEqual(want_ch.len, tg.chapters.len);
        for (want_ch, tg.chapters) |w, c| {
            try t.expectEqual(@as(u64, @intCast(w.array.items[0].integer)), c.start_ms);
            try t.expectEqualStrings(w.array.items[1].string, c.title);
        }

        // tag_hash: innerhalb einer Gruppe verschieden
        const th = try tg.hash();
        const key = try std.fmt.allocPrint(a, "{s}:{s}", .{ group, &th });
        try t.expect(!tag_hashes.contains(key));
        try tag_hashes.put(a, key, {});
        count += 1;
    }
    try t.expectEqual(files.count(), count);
    try t.expect(count >= 26);
}

test "Scan erkennt Umbenennung mit Tag-Änderung und hasht nur Geändertes" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var td = try openTestdata();
    defer td.close(t.io);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    try tmp.dir.createDirPath(t.io, "Unsortiert");
    try td.copyFile("mp3-plain.mp3", tmp.dir, "Unsortiert/track03.mp3", t.io, .{});
    try tmp.dir.writeFile(t.io, .{ .sub_path = "liste.m3u", .data = "Unsortiert/track03.mp3\n" });
    try tmp.dir.createDirPath(t.io, ".mync");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mync/ignoriert.mp3", .data = "x" });

    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/.mync/manifest.db", .{root}, 0);
    const m = try manifest.Manifest.open(t.io, db_path, root);
    defer m.close();

    var r = try m.scan(a);
    try t.expectEqual(@as(u32, 2), r.total);
    try t.expectEqual(@as(u32, 2), r.added);
    const base = try m.entries(a);
    const id_before = for (try m.files(a)) |f| {
        if (std.mem.endsWith(u8, f.entry.path, ".mp3")) break f.file_id;
    } else unreachable;

    // Umbenennen + „taggen“ (getaggte Fassung derselben Audiodaten)
    try tmp.dir.createDirPath(t.io, "Björk/Post");
    try tmp.dir.deleteFile(t.io, "Unsortiert/track03.mp3");
    try td.copyFile("mp3-tagged.mp3", tmp.dir, "Björk/Post/02 - Hyperballad.mp3", t.io, .{});

    r = try m.scan(a);
    try t.expectEqual(@as(u32, 0), r.added);
    try t.expectEqual(@as(u32, 0), r.removed);
    const f = for (try m.files(a)) |f| {
        if (std.mem.endsWith(u8, f.entry.path, ".mp3")) break f;
    } else unreachable;
    try t.expectEqualStrings(id_before, f.file_id);

    const ch = try diff.changes(a, base, try m.entries(a));
    try t.expectEqual(@as(usize, 1), ch.len);
    try t.expectEqualStrings("Unsortiert/track03.mp3", ch[0].rename.old.path);
    try t.expectEqualStrings("Björk/Post/02 - Hyperballad.mp3", ch[0].rename.new.path);
    try t.expect(ch[0].rename.tags_changed);

    // Zweiter Scan ohne Änderungen hasht nichts neu
    r = try m.scan(a);
    try t.expectEqual(@as(u32, 0), r.hashed);
}

test "Scan aus einer Auflistung mit Deskriptoren, in Portionen (Android)" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var td = try openTestdata();
    defer td.close(t.io);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try td.copyFile("mp3-plain.mp3", tmp.dir, "a.mp3", t.io, .{});
    try td.copyFile("mp3-tagged.mp3", tmp.dir, "b.mp3", t.io, .{});

    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/manifest.db", .{root}, 0);
    const m = try manifest.Manifest.open(t.io, db_path, "");
    defer m.close();

    const L = manifest.Listed;
    // 1. Nur auflisten: beide Dateien müssen eingelesen werden
    const list = [_]L{
        .{ .path = "Rock/a.mp3", .size = 10, .mtime_ns = 1 },
        .{ .path = "Rock/b.mp3", .size = 20, .mtime_ns = 1 },
        .{ .path = ".mync-trash/x.mp3", .size = 1, .mtime_ns = 1 },
        .{ .path = "Rock/notiz.pdf", .size = 1, .mtime_ns = 1 },
    };
    var r = try m.scanEntries(a, std.Io.Dir.cwd(), &list, false);
    try t.expectEqual(@as(u32, 2), r.total);
    try t.expectEqual(@as(usize, 2), r.needed.len);

    // 2. Portion für Portion über Deskriptoren einlesen
    for ([_][]const u8{ "a.mp3", "b.mp3" }, 0..) |name, i| {
        const f = try tmp.dir.openFile(t.io, name, .{});
        defer f.close(t.io);
        var batch = list;
        batch[i].src = try std.fmt.allocPrint(a, "fd:{d}:{s}", .{ f.handle, list[i].path });
        r = try m.scanEntries(a, std.Io.Dir.cwd(), &batch, false);
        try t.expectEqual(@as(u32, 1), r.hashed);
        try t.expectEqual(@as(usize, 0), r.errors.len);
    }
    r = try m.scanEntries(a, std.Io.Dir.cwd(), &list, true);
    try t.expectEqual(@as(usize, 0), r.needed.len);
    try t.expectEqual(@as(u32, 0), r.removed);
    const before = try m.files(a);
    try t.expectEqual(@as(usize, 2), before.len);

    // 3. Umbenannt (a.mp3 → Pop/a.mp3): erst einlesen, dann abschließen –
    //    die file_id bleibt, nichts wird gelöscht
    const f = try tmp.dir.openFile(t.io, "a.mp3", .{});
    defer f.close(t.io);
    var moved = [_]L{
        .{ .path = "Pop/a.mp3", .size = 10, .mtime_ns = 2, .src = try std.fmt.allocPrint(a, "fd:{d}:a.mp3", .{f.handle}) },
        list[1],
    };
    r = try m.scanEntries(a, std.Io.Dir.cwd(), &moved, false);
    try t.expectEqual(@as(u32, 0), r.added);
    moved[0].src = null;
    r = try m.scanEntries(a, std.Io.Dir.cwd(), &moved, true);
    try t.expectEqual(@as(u32, 0), r.removed);
    const after = try m.files(a);
    try t.expectEqual(@as(usize, 2), after.len);
    try t.expectEqualStrings("Pop/a.mp3", after[0].entry.path);
    try t.expectEqualStrings(before[0].file_id, after[0].file_id);

    // 4. Datei weg: erst im abschließenden Aufruf gelöscht
    r = try m.scanEntries(a, std.Io.Dir.cwd(), moved[1..], false);
    try t.expectEqual(@as(u32, 0), r.removed);
    r = try m.scanEntries(a, std.Io.Dir.cwd(), moved[1..], true);
    try t.expectEqual(@as(u32, 1), r.removed);
}
