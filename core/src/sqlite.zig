//! Schlanke Anbindung an SQLite (Amalgamation in `vendor/sqlite`).
//! Es werden nur die benötigten C-Funktionen deklariert.

const std = @import("std");

const sqlite3 = opaque {};
const stmt_t = opaque {};
/// Destruktor-Argument als Ganzzahl deklariert, damit SQLITE_TRANSIENT (-1)
/// übergeben werden kann – auf allen Zielplattformen zeigergroß.
const transient: isize = -1;

extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern fn sqlite3_close_v2(db: ?*sqlite3) c_int;
extern fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
extern fn sqlite3_exec(db: ?*sqlite3, sql: [*:0]const u8, cb: ?*anyopaque, arg: ?*anyopaque, err: ?*?[*:0]u8) c_int;
extern fn sqlite3_prepare_v2(db: ?*sqlite3, sql: [*]const u8, n: c_int, stmt: *?*stmt_t, tail: ?*?[*]const u8) c_int;
extern fn sqlite3_finalize(stmt: ?*stmt_t) c_int;
extern fn sqlite3_reset(stmt: ?*stmt_t) c_int;
extern fn sqlite3_step(stmt: ?*stmt_t) c_int;
extern fn sqlite3_bind_text(stmt: ?*stmt_t, i: c_int, text: [*]const u8, n: c_int, d: isize) c_int;
extern fn sqlite3_bind_int64(stmt: ?*stmt_t, i: c_int, v: i64) c_int;
extern fn sqlite3_column_text(stmt: ?*stmt_t, i: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: ?*stmt_t, i: c_int) c_int;
extern fn sqlite3_column_int64(stmt: ?*stmt_t, i: c_int) i64;

const OK = 0;
const ROW = 100;
const DONE = 101;
const OPEN_READWRITE = 0x02;
const OPEN_CREATE = 0x04;
const OPEN_FULLMUTEX = 0x10000;

pub const Error = error{Sqlite};

pub const Db = struct {
    handle: ?*sqlite3,

    pub fn open(path: [:0]const u8) Error!Db {
        var h: ?*sqlite3 = null;
        if (sqlite3_open_v2(path.ptr, &h, OPEN_READWRITE | OPEN_CREATE | OPEN_FULLMUTEX, null) != OK) {
            std.log.err("SQLite: {s}", .{sqlite3_errmsg(h)});
            _ = sqlite3_close_v2(h);
            return error.Sqlite;
        }
        return .{ .handle = h };
    }

    pub fn close(db: Db) void {
        _ = sqlite3_close_v2(db.handle);
    }

    pub fn exec(db: Db, sql: [:0]const u8) Error!void {
        if (sqlite3_exec(db.handle, sql.ptr, null, null, null) != OK) return db.fail();
    }

    pub fn prepare(db: Db, sql: []const u8) Error!Stmt {
        var s: ?*stmt_t = null;
        if (sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &s, null) != OK) return db.fail();
        return .{ .handle = s, .db = db };
    }

    fn fail(db: Db) Error {
        std.log.err("SQLite: {s}", .{sqlite3_errmsg(db.handle)});
        return error.Sqlite;
    }
};

pub const Stmt = struct {
    handle: ?*stmt_t,
    db: Db,

    pub fn deinit(s: Stmt) void {
        _ = sqlite3_finalize(s.handle);
    }

    pub fn reset(s: Stmt) void {
        _ = sqlite3_reset(s.handle);
    }

    /// Bindet Parameter 1…n: Strings ([]const u8) und Ganzzahlen.
    pub fn bind(s: Stmt, args: anytype) Error!void {
        inline for (args, 1..) |a, i| {
            const T = @TypeOf(a);
            const rc = switch (@typeInfo(T)) {
                .int, .comptime_int => sqlite3_bind_int64(s.handle, i, @intCast(a)),
                else => blk: {
                    const str: []const u8 = a;
                    break :blk sqlite3_bind_text(s.handle, i, str.ptr, @intCast(str.len), transient);
                },
            };
            if (rc != OK) return s.db.fail();
        }
    }

    /// true = neue Zeile verfügbar, false = fertig.
    pub fn step(s: Stmt) Error!bool {
        return switch (sqlite3_step(s.handle)) {
            ROW => true,
            DONE => false,
            else => s.db.fail(),
        };
    }

    /// Führt eine Anweisung ohne Ergebniszeilen aus und setzt sie zurück.
    pub fn run(s: Stmt, args: anytype) Error!void {
        defer s.reset();
        try s.bind(args);
        while (try s.step()) {}
    }

    /// Text der Spalte – gültig bis zum nächsten step/reset.
    pub fn text(s: Stmt, col: c_int) []const u8 {
        const p = sqlite3_column_text(s.handle, col) orelse return "";
        return p[0..@intCast(sqlite3_column_bytes(s.handle, col))];
    }

    pub fn int(s: Stmt, col: c_int) i64 {
        return sqlite3_column_int64(s.handle, col);
    }
};
