//! mync-core: gemeinsamer Kern für die mync-App auf Android und Linux.
//!
//! - `audiohash`: Hash über die reinen Audiodaten (ohne Tags)
//! - `tags`: formatunabhängige, normalisierte Tags und `tag_hash`
//! - `manifest`: inkrementeller Scan der Bibliothek in eine SQLite-DB
//! - `diff`: Änderungserkennung gegenüber der Basis und Inbox-Vorschläge

pub const audiohash = @import("audiohash.zig");
pub const tags = @import("tags.zig");
pub const diff = @import("diff.zig");
pub const manifest = @import("manifest.zig");
pub const sqlite = @import("sqlite.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("testdata_test.zig");
}
