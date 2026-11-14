//! Prüft mit echten, per ffmpeg erzeugten Dateien: Tag-Änderungen lassen den
//! `audio_hash` unverändert, ändern aber den `tag_hash`; der Manifest-Scan
//! erkennt Umbenennungen.

use lofty::config::WriteOptions;
use lofty::prelude::*;
use lofty::tag::{ItemKey, Tag};
use mync_core::audiohash::{audio_hash, HashKind};
use mync_core::diff::{changes, Change};
use mync_core::manifest::{hash_file, Manifest};
use std::path::Path;
use std::process::Command;

fn ffmpeg(out: &Path, extra: &[&str]) -> bool {
    let ok = Command::new("ffmpeg")
        .args(["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2"])
        .args(extra)
        .arg(out)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !ok {
        eprintln!("ffmpeg nicht verfügbar – Test für {} übersprungen", out.display());
    }
    ok
}

fn set_tags(p: &Path, title: &str, long_text: bool) {
    let mut f = lofty::read_from_path(p).unwrap();
    if f.primary_tag().is_none() {
        f.insert_tag(Tag::new(f.primary_tag_type()));
    }
    let t = f.primary_tag_mut().unwrap();
    t.insert_text(ItemKey::TrackTitle, title.into());
    t.insert_text(ItemKey::TrackArtist, "Testkünstler".into());
    if long_text {
        // groß genug, dass der Ogg-Kommentar-Header über mehrere Seiten geht
        t.insert_text(ItemKey::Lyrics, "la ".repeat(40_000));
    }
    f.save_to_path(p, WriteOptions::default()).unwrap();
}

fn check(ext: &str, extra: &[&str], kind: HashKind) {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join(format!("t.{ext}"));
    if !ffmpeg(&p, extra) {
        return;
    }
    let (a0, k) = audio_hash(&p).unwrap();
    assert_eq!(k, kind);
    let (e0, _) = hash_file(&p).unwrap();

    set_tags(&p, "Erster Titel", false);
    let (e1, t1) = hash_file(&p).unwrap();
    assert_eq!(e1.audio_hash, a0, "{ext}: audio_hash nach Tagging verändert");
    assert_ne!(e1.tag_hash, e0.tag_hash, "{ext}: tag_hash unverändert");
    assert_eq!(t1.fields["title"], vec!["Erster Titel".to_string()]);

    set_tags(&p, "Zweiter Titel", true);
    let (e2, _) = hash_file(&p).unwrap();
    assert_eq!(e2.audio_hash, a0, "{ext}: audio_hash nach großem Tag verändert");
    assert_ne!(e2.tag_hash, e1.tag_hash);
}

#[test]
fn mp3() {
    check("mp3", &["-c:a", "libmp3lame", "-write_xing", "0"], HashKind::Mp3);
}
#[test]
fn flac() {
    check("flac", &[], HashKind::Flac);
}
#[test]
fn ogg_vorbis() {
    check("ogg", &["-c:a", "libvorbis"], HashKind::Ogg);
}
#[test]
fn opus() {
    check("opus", &["-c:a", "libopus"], HashKind::Ogg);
}
#[test]
fn m4a() {
    check("m4a", &["-c:a", "aac"], HashKind::Mp4);
}
#[test]
fn wav() {
    check("wav", &[], HashKind::Wav);
}

#[test]
fn scan_erkennt_umbenennung_mit_tag_aenderung() {
    let lib = tempfile::tempdir().unwrap();
    let db = tempfile::tempdir().unwrap();
    let a = lib.path().join("Unsortiert/track03.mp3");
    std::fs::create_dir_all(a.parent().unwrap()).unwrap();
    if !ffmpeg(&a, &["-c:a", "libmp3lame"]) {
        return;
    }
    std::fs::write(lib.path().join("liste.m3u"), "Unsortiert/track03.mp3\n").unwrap();

    let mut m = Manifest::open(&db.path().join("m.db"), lib.path()).unwrap();
    let r = m.scan().unwrap();
    assert_eq!((r.total, r.added), (2, 2), "{r:?}");
    let base = m.entries().unwrap();
    let id_before = m.files().unwrap().into_iter().find(|f| f.entry.path.ends_with(".mp3")).unwrap().file_id;

    // Umbenennen + taggen
    let b = lib.path().join("Björk/Post/03 - Hyperballad.mp3");
    std::fs::create_dir_all(b.parent().unwrap()).unwrap();
    std::fs::rename(&a, &b).unwrap();
    set_tags(&b, "Hyperballad", false);

    let r = m.scan().unwrap();
    assert_eq!((r.added, r.removed), (0, 0), "{r:?}");
    let files = m.files().unwrap();
    let f = files.iter().find(|f| f.entry.path.ends_with(".mp3")).unwrap();
    assert_eq!(f.file_id, id_before, "file_id muss bei Umbenennung erhalten bleiben");

    let ch = changes(&base, &m.entries().unwrap());
    assert_eq!(ch.len(), 1, "{ch:#?}");
    match &ch[0] {
        Change::Rename { old, new, tags_changed } => {
            assert_eq!(old.path, "Unsortiert/track03.mp3");
            assert_eq!(new.path, "Björk/Post/03 - Hyperballad.mp3");
            assert!(tags_changed);
        }
        other => panic!("Umbenennung erwartet, nicht {other:?}"),
    }

    // Zweiter Scan ohne Änderungen hasht nichts neu
    let r = m.scan().unwrap();
    assert_eq!(r.hashed, 0);
}
