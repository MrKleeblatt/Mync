//! Diff-Engine: Erkennt Änderungen gegenüber dem letzten gemeinsamen Stand
//! („Basis“) und erzeugt daraus Vorschläge für das andere Gerät.
//!
//! Siehe `docs/sync-konzept.md`, Abschnitte 4 und 5.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Eine Datei, wie sie im Manifest oder in der Basis steht.
pub const Entry = struct {
    path: []const u8,
    audio_hash: []const u8,
    tag_hash: []const u8,

    pub fn eql(a: Entry, b: Entry) bool {
        return std.mem.eql(u8, a.path, b.path) and
            std.mem.eql(u8, a.audio_hash, b.audio_hash) and
            std.mem.eql(u8, a.tag_hash, b.tag_hash);
    }
};

/// Eine Änderung auf *einem* Gerät gegenüber der Basis.
pub const Change = union(enum) {
    add: struct { new: Entry },
    delete: struct { old: Entry },
    /// Umbenannt/verschoben; `tags_changed` wenn zusätzlich Tags geändert wurden.
    rename: struct { old: Entry, new: Entry, tags_changed: bool },
    tags: struct { old: Entry, new: Entry },
    /// Gleicher Pfad, andere Audiodaten (z. B. bessere Qualität).
    replace: struct { old: Entry, new: Entry },

    /// Pfad in der Basis, auf den sich die Änderung bezieht (null bei add).
    pub fn basePath(c: Change) ?[]const u8 {
        return switch (c) {
            .add => null,
            .delete => |d| d.old.path,
            .rename => |d| d.old.path,
            .tags => |d| d.old.path,
            .replace => |d| d.old.path,
        };
    }

    /// Zustand nach der Änderung (null bei delete).
    pub fn result(c: Change) ?Entry {
        return switch (c) {
            .delete => null,
            .add => |d| d.new,
            .rename => |d| d.new,
            .tags => |d| d.new,
            .replace => |d| d.new,
        };
    }

    pub fn targetPath(c: Change) ?[]const u8 {
        return if (c.result()) |r| r.path else null;
    }
};

fn byPath(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Vergleicht den aktuellen Stand eines Geräts mit der Basis.
///
/// Zuordnung: gleicher Pfad → dieselbe Datei; danach werden übrig gebliebene
/// Einträge über den `audio_hash` gepaart (→ Umbenennung, kleinster Pfad zuerst).
pub fn changes(gpa: Allocator, base: []const Entry, current: []const Entry) ![]Change {
    var cur_by_path: std.StringHashMapUnmanaged(Entry) = .empty;
    defer cur_by_path.deinit(gpa);
    for (current) |c| try cur_by_path.put(gpa, c.path, c);

    var matched: std.StringHashMapUnmanaged(void) = .empty;
    defer matched.deinit(gpa);
    var unmatched_base: std.ArrayList(Entry) = .empty;
    defer unmatched_base.deinit(gpa);
    var out: std.ArrayList(Change) = .empty;
    errdefer out.deinit(gpa);

    for (base) |b| {
        if (cur_by_path.get(b.path)) |c| {
            try matched.put(gpa, c.path, {});
            if (!std.mem.eql(u8, c.audio_hash, b.audio_hash)) {
                try out.append(gpa, .{ .replace = .{ .old = b, .new = c } });
            } else if (!std.mem.eql(u8, c.tag_hash, b.tag_hash)) {
                try out.append(gpa, .{ .tags = .{ .old = b, .new = c } });
            }
        } else try unmatched_base.append(gpa, b);
    }

    // Übrige aktuelle Einträge, nach Pfad sortiert.
    var rest: std.ArrayList(Entry) = .empty;
    defer rest.deinit(gpa);
    for (current) |c| if (!matched.contains(c.path)) try rest.append(gpa, c);
    std.mem.sort(Entry, rest.items, {}, byPath);
    const used = try gpa.alloc(bool, rest.items.len);
    defer gpa.free(used);
    @memset(used, false);

    for (unmatched_base.items) |b| {
        const hit = for (rest.items, 0..) |c, i| {
            if (!used[i] and std.mem.eql(u8, c.audio_hash, b.audio_hash)) break i;
        } else null;
        if (hit) |i| {
            used[i] = true;
            const c = rest.items[i];
            try out.append(gpa, .{ .rename = .{
                .old = b,
                .new = c,
                .tags_changed = !std.mem.eql(u8, c.tag_hash, b.tag_hash),
            } });
        } else try out.append(gpa, .{ .delete = .{ .old = b } });
    }
    for (rest.items, used) |c, u| if (!u) try out.append(gpa, .{ .add = .{ .new = c } });
    return out.toOwnedSlice(gpa);
}

/// Ein Eintrag in der Inbox des Empfängers.
pub const Proposal = union(enum) {
    /// Änderung der Gegenseite, die lokal angewendet werden kann.
    apply: struct { change: Change },
    /// Beide Seiten haben dieselbe Datei bzw. denselben Zielpfad verändert.
    conflict: struct { local: Change, remote: Change },
};

/// Erzeugt die Inbox für das lokale Gerät aus den Änderungen beider Seiten.
///
/// - Änderungen der Gegenseite, die lokal nichts berühren → `apply`.
/// - Hat das lokale Gerät dieselbe Basis-Datei verändert → `conflict`,
///   außer beide Seiten haben exakt dasselbe getan (dann nichts zu tun).
/// - Wollen beide Seiten unterschiedliche Dateien an denselben Pfad legen
///   → `conflict`.
pub fn proposals(gpa: Allocator, local: []const Change, remote: []const Change) ![]Proposal {
    var by_base: std.StringHashMapUnmanaged(Change) = .empty;
    defer by_base.deinit(gpa);
    var by_target: std.StringHashMapUnmanaged(Change) = .empty;
    defer by_target.deinit(gpa);
    for (local) |c| {
        if (c.basePath()) |p| try by_base.put(gpa, p, c);
        if (c.targetPath()) |p| try by_target.put(gpa, p, c);
    }
    var out: std.ArrayList(Proposal) = .empty;
    errdefer out.deinit(gpa);
    for (remote) |r| {
        const same_base = if (r.basePath()) |p| by_base.get(p) else null;
        const same_target = if (r.targetPath()) |p| by_target.get(p) else null;
        if (same_base orelse same_target) |l| {
            if (!sameEffect(l, r)) try out.append(gpa, .{ .conflict = .{ .local = l, .remote = r } });
        } else try out.append(gpa, .{ .apply = .{ .change = r } });
    }
    return out.toOwnedSlice(gpa);
}

fn sameEffect(a: Change, b: Change) bool {
    const pa = a.basePath();
    const pb = b.basePath();
    if ((pa == null) != (pb == null)) return false;
    if (pa != null and !std.mem.eql(u8, pa.?, pb.?)) return false;
    const ra = a.result();
    const rb = b.result();
    if (ra == null or rb == null) return ra == null and rb == null;
    return ra.?.eql(rb.?);
}

// ───────────────────────────── Tests ───────────────────────────────────────

const t = std.testing;

fn e(path: []const u8, a: []const u8, tg: []const u8) Entry {
    return .{ .path = path, .audio_hash = a, .tag_hash = tg };
}

fn contains(list: []const Change, want: Change) bool {
    for (list) |c| {
        if (std.meta.activeTag(c) != std.meta.activeTag(want)) continue;
        const ok = switch (c) {
            .add => |d| d.new.eql(want.add.new),
            .delete => |d| d.old.eql(want.delete.old),
            .rename => |d| d.old.eql(want.rename.old) and d.new.eql(want.rename.new) and
                d.tags_changed == want.rename.tags_changed,
            .tags => |d| d.old.eql(want.tags.old) and d.new.eql(want.tags.new),
            .replace => |d| d.old.eql(want.replace.old) and d.new.eql(want.replace.new),
        };
        if (ok) return true;
    }
    return false;
}

test "klassifiziert alle Änderungsarten" {
    const base = [_]Entry{
        e("a.mp3", "A", "1"), e("b.mp3", "B", "1"), e("c.mp3", "C", "1"),
        e("d.mp3", "D", "1"), e("e.mp3", "E", "1"), e("f.mp3", "F", "1"),
    };
    const cur = [_]Entry{
        e("a.mp3", "A", "1"), // unverändert
        e("neu/b.mp3", "B", "1"), // umbenannt
        e("c.mp3", "C", "2"), // Tags
        // d gelöscht
        e("e.mp3", "E2", "1"), // Inhalt ersetzt
        e("f2.mp3", "F", "9"), // umbenannt + Tags
        e("g.mp3", "G", "1"), // neu
    };
    const ch = try changes(t.allocator, &base, &cur);
    defer t.allocator.free(ch);
    try t.expectEqual(@as(usize, 6), ch.len);
    try t.expect(contains(ch, .{ .rename = .{ .old = base[1], .new = cur[1], .tags_changed = false } }));
    try t.expect(contains(ch, .{ .tags = .{ .old = base[2], .new = cur[2] } }));
    try t.expect(contains(ch, .{ .delete = .{ .old = base[3] } }));
    try t.expect(contains(ch, .{ .replace = .{ .old = base[4], .new = cur[3] } }));
    try t.expect(contains(ch, .{ .rename = .{ .old = base[5], .new = cur[4], .tags_changed = true } }));
    try t.expect(contains(ch, .{ .add = .{ .new = cur[5] } }));
}

test "Duplikate werden nicht doppelt gepaart" {
    const base = [_]Entry{e("x.mp3", "X", "1")};
    const cur = [_]Entry{ e("z.mp3", "X", "1"), e("y.mp3", "X", "1") };
    const ch = try changes(t.allocator, &base, &cur);
    defer t.allocator.free(ch);
    try t.expectEqual(@as(usize, 2), ch.len);
    try t.expectEqualStrings("y.mp3", ch[0].rename.new.path);
    try t.expectEqualStrings("z.mp3", ch[1].add.new.path);
}

test "Konflikte und gleiche Änderungen" {
    const base = [_]Entry{ e("a.mp3", "A", "1"), e("b.mp3", "B", "1"), e("c.mp3", "C", "1") };
    // lokal: a umbenannt, c Tags geändert
    const local = try changes(t.allocator, &base, &.{ e("a2.mp3", "A", "1"), e("b.mp3", "B", "1"), e("c.mp3", "C", "5") });
    defer t.allocator.free(local);
    // remote: a Tags geändert (Konflikt), b gelöscht (anwendbar), c gleiche Tags (nichts), neu.mp3
    const remote = try changes(t.allocator, &base, &.{ e("a.mp3", "A", "2"), e("c.mp3", "C", "5"), e("neu.mp3", "N", "1") });
    defer t.allocator.free(remote);
    const p = try proposals(t.allocator, local, remote);
    defer t.allocator.free(p);
    try t.expectEqual(@as(usize, 3), p.len);
    try t.expect(p[0] == .conflict and p[0].conflict.remote == .tags);
    try t.expect(p[1] == .apply and p[1].apply.change == .delete);
    try t.expect(p[2] == .apply and p[2].apply.change == .add);
}

test "gleicher Zielpfad ist Konflikt" {
    const local = try changes(t.allocator, &.{}, &.{e("x.mp3", "L", "1")});
    defer t.allocator.free(local);
    const remote = try changes(t.allocator, &.{}, &.{e("x.mp3", "R", "1")});
    defer t.allocator.free(remote);
    const p = try proposals(t.allocator, local, remote);
    defer t.allocator.free(p);
    try t.expect(p[0] == .conflict);
}
