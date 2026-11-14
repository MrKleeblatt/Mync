//! mync-core: gemeinsamer Kern für die mync-App auf Android und Linux.
//!
//! - [`audiohash`]: Hash über die reinen Audiodaten (ohne Tags)
//! - [`tags`]: formatunabhängige, normalisierte Tags und `tag_hash`
//! - [`manifest`]: inkrementeller Scan der Bibliothek in eine SQLite-DB
//! - [`diff`]: Änderungserkennung gegenüber der Basis und Inbox-Vorschläge

pub mod audiohash;
pub mod diff;
pub mod manifest;
pub mod tags;
