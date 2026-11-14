# mync

**mync** = *music sync*. Zwei Bausteine für eine lokale Musiksammlung, die auf
PC (Linux) und Handy (Android, Musicolet) gleich aussehen soll:

1. **mync-sync** – synchronisiert Audiodateien zwischen Handy und PC.
   Jede Änderung (neue Datei, Löschung, Umbenennung, Tag-Änderung) wird dem
   **Empfängergerät als Vorschlag** angezeigt und erst nach Bestätigung durch
   den Nutzer angewendet.
2. **mync-player** – ein Musikplayer für Linux, der den Funktionsumfang von
   Musicolet abbildet (mehrere Warteschlangen, Ordner-Ansicht, Tag-Editor,
   synchronisierte Lyrics, Equalizer, Sleeptimer …) – offline, ohne Konto,
   ohne Werbung.

## Dokumente

| Dokument | Inhalt |
|---|---|
| [docs/sync-konzept.md](docs/sync-konzept.md) | Konzept für die Synchronisation mit Bestätigung auf dem Empfängergerät |
| [docs/player-plan.md](docs/player-plan.md) | Funktions- und Architekturplan für den Linux-Player |
| [docs/roadmap.md](docs/roadmap.md) | Umsetzungsreihenfolge, Meilensteine, offene Fragen |

## Repo-Struktur

```
mync/
├── app/          # Flutter-App (Dart) für Linux und Android
│   └── rust/     # Bridge-Crate zwischen Flutter und dem Rust-Kern
├── core/         # Rust-Kern: Audio-Hash, Tags, Manifest, Diff-Engine, CLI `mync`
└── docs/         # Konzepte und Pläne
```

## Grundsatzentscheidungen (Kurzfassung)

- **Eine App für beide Geräte:** Flutter (Dart) für die Oberfläche auf
  Linux und Android, darunter ein Rust-Kern (`core/`), angebunden über
  flutter_rust_bridge.
- **Handy:** Sync-Gegenstelle + Inbox. Abgespielt wird weiter mit Musicolet.
- **PC:** Player (media_kit/libmpv) + Sync + Inbox.
- **Identischer Kern auf beiden Seiten:** Scanner, Hashes, Tags (lofty),
  Diff-Engine und Sync-Protokoll sind derselbe Rust-Code – beide Geräte
  rechnen garantiert gleich.
- **Kein Cloud-Dienst:** Synchronisation direkt im Heim-WLAN (optional USB/adb).
- **Musicolet bleibt der Player auf dem Handy.** mync-sync arbeitet nur auf den
  Dateien; Musicolet erkennt Änderungen über seinen normalen Rescan.
- **Dateien sind die Wahrheit:** Tags stehen in den Audiodateien (ID3, Vorbis
  Comments, MP4-Atoms), nicht in einer eigenen Datenbank. So bleiben Musicolet
  und mync-player kompatibel.

## Status

- ✅ Rust-Kern `core/` (Meilenstein M0) mit Tests
- ✅ Flutter-App-Gerüst `app/` mit Bibliotheksansicht
- ⏳ Sync-Protokoll und Inbox (M1), danach der Player (M3)

## Entwickeln

```bash
# Rust-Kern testen (für die Formattests wird ffmpeg benötigt)
cd core && cargo test

# Bibliothek einlesen und anzeigen
cargo run --bin mync -- scan ~/Musik
cargo run --bin mync -- status ~/Musik

# App starten (Linux)
cd app && flutter run -d linux
```
