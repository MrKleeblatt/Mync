//! Schnittstelle zwischen Flutter und dem Rust-Kern (`core/`).
//!
//! Hält bewusst nur einfache Datentypen, damit flutter_rust_bridge daraus
//! Dart-Klassen erzeugen kann.

use mync_core::manifest::Manifest;
use std::path::{Path, PathBuf};

/// Ergebnis eines Bibliotheks-Scans.
pub struct ScanSummary {
    pub total: u32,
    pub hashed: u32,
    pub added: u32,
    pub removed: u32,
    pub errors: Vec<String>,
}

/// Ein Titel der Bibliothek, wie die Oberfläche ihn anzeigt.
pub struct TrackInfo {
    pub file_id: String,
    pub path: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub track: Option<String>,
}

fn open(root: &str, db: &str) -> anyhow::Result<Manifest> {
    let db = PathBuf::from(db);
    if let Some(dir) = db.parent() {
        std::fs::create_dir_all(dir)?;
    }
    Manifest::open(&db, Path::new(root))
}

/// Durchsucht den Musikordner `root` und aktualisiert das Manifest `db`.
pub fn scan_library(root: String, db: String) -> anyhow::Result<ScanSummary> {
    if !Path::new(&root).is_dir() {
        anyhow::bail!("Ordner nicht gefunden: {root}");
    }
    let mut m = open(&root, &db)?;
    let r = m.scan()?;
    Ok(ScanSummary {
        total: r.total as u32,
        hashed: r.hashed as u32,
        added: r.added as u32,
        removed: r.removed as u32,
        errors: r.errors.into_iter().map(|(p, e)| format!("{p}: {e}")).collect(),
    })
}

/// Liefert alle Titel aus dem Manifest, sortiert nach Pfad.
pub fn list_tracks(root: String, db: String) -> anyhow::Result<Vec<TrackInfo>> {
    let m = open(&root, &db)?;
    let first = |f: &mync_core::tags::Tags, k: &str| f.fields.get(k).map(|v| v.join("; "));
    Ok(m.files()?
        .into_iter()
        .map(|f| TrackInfo {
            title: first(&f.tags, "title"),
            artist: first(&f.tags, "artist"),
            album: first(&f.tags, "album"),
            track: first(&f.tags, "track"),
            file_id: f.file_id,
            path: f.entry.path,
        })
        .collect())
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
