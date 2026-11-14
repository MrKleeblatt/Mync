//! Kommandozeilenwerkzeug zum Testen des Kerns.
//!
//!   mync scan   <musikordner> [db]   Bibliothek ins Manifest einlesen
//!   mync status <musikordner> [db]   Manifest auflisten
//!   mync hash   <datei>...           Hashes und Tags einzelner Dateien zeigen

use anyhow::{bail, Result};
use mync_core::{audiohash::audio_hash, manifest::Manifest, tags::read_tags};
use std::path::{Path, PathBuf};

fn db_path(root: &Path, arg: Option<&String>) -> PathBuf {
    arg.map(PathBuf::from).unwrap_or_else(|| root.join(".mync").join("manifest.db"))
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("scan") | Some("status") if args.len() >= 2 => {
            let root = PathBuf::from(&args[1]);
            let db = db_path(&root, args.get(2));
            if let Some(dir) = db.parent() {
                std::fs::create_dir_all(dir)?;
            }
            let mut m = Manifest::open(&db, &root)?;
            if args[0] == "scan" {
                let r = m.scan()?;
                println!(
                    "{} Dateien, {} neu gehasht, {} neu, {} entfernt, {} Fehler",
                    r.total, r.hashed, r.added, r.removed, r.errors.len()
                );
                for (p, e) in r.errors {
                    eprintln!("  Fehler: {p}: {e}");
                }
            } else {
                for f in m.files()? {
                    let title = f.tags.fields.get("title").map(|v| v.join("; ")).unwrap_or_default();
                    println!("{}  {}  {}  {}", &f.entry.audio_hash[..12], &f.entry.tag_hash[..12], f.entry.path, title);
                }
            }
        }
        Some("hash") if args.len() >= 2 => {
            for a in &args[1..] {
                let p = Path::new(a);
                let (h, kind) = audio_hash(p)?;
                let tags = read_tags(p)?;
                println!("{a}\n  audio_hash ({kind:?}): {h}\n  tag_hash: {}", tags.hash());
                for (k, v) in &tags.fields {
                    println!("  {k}: {}", v.join("; "));
                }
                if !tags.pictures.is_empty() {
                    println!("  Bilder: {}", tags.pictures.len());
                }
            }
        }
        _ => bail!("Aufruf: mync scan|status <musikordner> [db]  |  mync hash <datei>..."),
    }
    Ok(())
}
