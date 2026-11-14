//! Manifest: SQLite-Datenbank mit einem Eintrag pro Datei der Musikbibliothek.
//!
//! Der Scan ist inkrementell: Hashes werden nur neu berechnet, wenn sich
//! Größe oder Änderungszeit einer Datei geändert haben.

use crate::audiohash::audio_hash;
use crate::diff::Entry;
use crate::tags::{read_tags, Tags};
use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;
use walkdir::WalkDir;

pub const EXTENSIONS: &[&str] = &[
    "mp3", "flac", "ogg", "oga", "opus", "m4a", "m4b", "mp4", "aac", "wav", "lrc", "m3u", "m3u8",
];

/// Ordner, die der Scan überspringt (eigener Papierkorb, versteckte Ordner).
fn skip_dir(name: &str) -> bool {
    name.starts_with('.')
}

pub struct Manifest {
    conn: Connection,
    root: PathBuf,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ScanReport {
    pub total: usize,
    pub hashed: usize,
    pub added: usize,
    pub removed: usize,
    pub errors: Vec<(String, String)>,
}

#[derive(Debug, Clone)]
pub struct FileRow {
    pub file_id: String,
    pub entry: Entry,
    pub tags: Tags,
    pub size: u64,
    pub mtime_ns: i64,
}

impl Manifest {
    pub fn open(db: &Path, root: &Path) -> Result<Self> {
        let conn = Connection::open(db).with_context(|| format!("Datenbank {}", db.display()))?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             CREATE TABLE IF NOT EXISTS file (
               file_id    TEXT PRIMARY KEY,
               path       TEXT UNIQUE NOT NULL,
               size       INTEGER NOT NULL,
               mtime_ns   INTEGER NOT NULL,
               audio_hash TEXT NOT NULL,
               tag_hash   TEXT NOT NULL,
               tags_json  TEXT NOT NULL,
               seq        INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
        )?;
        Ok(Self { conn, root: root.to_path_buf() })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn next_seq(&self) -> Result<i64> {
        let cur: i64 = self
            .conn
            .query_row("SELECT value FROM meta WHERE key='seq'", [], |r| r.get::<_, String>(0))
            .optional()?
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        self.conn.execute(
            "INSERT INTO meta(key,value) VALUES('seq',?1) ON CONFLICT(key) DO UPDATE SET value=?1",
            [(cur + 1).to_string()],
        )?;
        Ok(cur + 1)
    }

    pub fn files(&self) -> Result<Vec<FileRow>> {
        let mut st = self.conn.prepare(
            "SELECT file_id,path,audio_hash,tag_hash,tags_json,size,mtime_ns FROM file ORDER BY path",
        )?;
        let rows = st.query_map([], |r| {
            let tags_json: String = r.get(4)?;
            Ok(FileRow {
                file_id: r.get(0)?,
                entry: Entry { path: r.get(1)?, audio_hash: r.get(2)?, tag_hash: r.get(3)? },
                tags: serde_json::from_str(&tags_json).unwrap_or_default(),
                size: r.get::<_, i64>(5)? as u64,
                mtime_ns: r.get(6)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn entries(&self) -> Result<Vec<Entry>> {
        Ok(self.files()?.into_iter().map(|f| f.entry).collect())
    }

    /// Durchsucht die Bibliothek und aktualisiert das Manifest.
    ///
    /// Eine verschobene Datei (gleicher `audio_hash`, neuer Pfad) behält ihre
    /// `file_id`, damit Warteschlangen, Statistik usw. ihr folgen können.
    pub fn scan(&mut self) -> Result<ScanReport> {
        let mut report = ScanReport::default();
        let known: HashMap<String, FileRow> =
            self.files()?.into_iter().map(|f| (f.entry.path.clone(), f)).collect();
        let mut seen: HashMap<String, ()> = HashMap::new();
        let mut fresh: Vec<FileRow> = Vec::new();

        let walker = WalkDir::new(&self.root).follow_links(true).into_iter().filter_entry(|e| {
            e.depth() == 0 || !(e.file_type().is_dir() && skip_dir(&e.file_name().to_string_lossy()))
        });
        for ent in walker {
            let ent = match ent {
                Ok(e) => e,
                Err(e) => {
                    report.errors.push((String::new(), e.to_string()));
                    continue;
                }
            };
            if !ent.file_type().is_file() || !has_known_ext(ent.path()) {
                continue;
            }
            let rel = rel_path(&self.root, ent.path());
            report.total += 1;
            seen.insert(rel.clone(), ());
            let md = ent.metadata()?;
            let size = md.len();
            let mtime_ns = md
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_nanos() as i64);
            if let Some(k) = known.get(&rel)
                && k.size == size && k.mtime_ns == mtime_ns {
                    continue; // unverändert
                }
            report.hashed += 1;
            match hash_file(ent.path()) {
                Ok((entry_hashes, tags)) => fresh.push(FileRow {
                    file_id: String::new(),
                    entry: Entry { path: rel, ..entry_hashes },
                    tags,
                    size,
                    mtime_ns,
                }),
                Err(e) => report.errors.push((rel, format!("{e:#}"))),
            }
        }

        let tx = self.conn.transaction()?;
        let mut vanished: Vec<&FileRow> =
            known.values().filter(|k| !seen.contains_key(&k.entry.path)).collect();
        for row in &vanished {
            tx.execute("DELETE FROM file WHERE file_id=?1", [&row.file_id])?;
        }
        tx.commit()?;

        for mut row in fresh {
            let seq = self.next_seq()?;
            // Bestehende Datei am selben Pfad → gleiche file_id behalten.
            let mut id = known.get(&row.entry.path).map(|k| k.file_id.clone());
            // Sonst: verschwundene Datei mit gleichem Audio → Umbenennung.
            if id.is_none() {
                if let Some(i) = vanished.iter().position(|v| v.entry.audio_hash == row.entry.audio_hash) {
                    id = Some(vanished.remove(i).file_id.clone());
                } else {
                    report.added += 1;
                }
            }
            row.file_id = id.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
            self.conn.execute(
                "INSERT INTO file(file_id,path,size,mtime_ns,audio_hash,tag_hash,tags_json,seq)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8)
                 ON CONFLICT(file_id) DO UPDATE SET path=?2,size=?3,mtime_ns=?4,
                   audio_hash=?5,tag_hash=?6,tags_json=?7,seq=?8",
                params![
                    row.file_id,
                    row.entry.path,
                    row.size as i64,
                    row.mtime_ns,
                    row.entry.audio_hash,
                    row.entry.tag_hash,
                    serde_json::to_string(&row.tags)?,
                    seq
                ],
            )?;
        }
        report.removed = vanished.len();
        Ok(report)
    }
}

fn has_known_ext(p: &Path) -> bool {
    p.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
}

/// Relativer Pfad mit `/` als Trenner – auf allen Geräten gleich.
pub fn rel_path(root: &Path, p: &Path) -> String {
    p.strip_prefix(root)
        .unwrap_or(p)
        .components()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}

/// Berechnet `audio_hash`, Tags und `tag_hash` einer Datei.
pub fn hash_file(p: &Path) -> Result<(Entry, Tags)> {
    let (audio, _) = audio_hash(p)?;
    let tags = read_tags(p)?;
    Ok((Entry { path: String::new(), audio_hash: audio, tag_hash: tags.hash() }, tags))
}
