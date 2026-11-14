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
├── app/          # Flutter-App (Dart) für Linux und Android, Kern über dart:ffi
├── core/         # Kern in Zig 0.17.1: Audio-Hash, Tags, Manifest, Diff-Engine, CLI `mync`
│   ├── testdata/ # kleine Testdateien aller Formate + erwartete Tags
│   └── vendor/   # SQLite-Amalgamation (C)
└── docs/         # Konzepte und Pläne
```

## Grundsatzentscheidungen (Kurzfassung)

- **Eine App für beide Geräte:** Flutter (Dart) für die Oberfläche auf
  Linux und Android, darunter ein Kern in **Zig 0.17.1** (`core/`), als
  gemeinsame Bibliothek `libmync_core.so` über `dart:ffi` angebunden.
- **Handy:** Sync-Gegenstelle + Inbox. Abgespielt wird weiter mit Musicolet.
- **PC:** Player (media_kit/libmpv) + Sync + Inbox.
- **Identischer Kern auf beiden Seiten:** Scanner, Hashes, Tag-Leser,
  Diff-Engine und Sync-Protokoll sind derselbe Zig-Code – beide Geräte
  rechnen garantiert gleich. Abhängigkeiten: nur die Zig-Standardbibliothek
  und SQLite.
- **Kein Cloud-Dienst:** Synchronisation direkt im Heim-WLAN (optional USB/adb).
- **Musicolet bleibt der Player auf dem Handy.** mync-sync arbeitet nur auf den
  Dateien; Musicolet erkennt Änderungen über seinen normalen Rescan.
- **Dateien sind die Wahrheit:** Tags stehen in den Audiodateien (ID3, Vorbis
  Comments, MP4-Atoms), nicht in einer eigenen Datenbank. So bleiben Musicolet
  und mync-player kompatibel.

## Status

- ✅ Zig-Kern `core/` (Meilenstein M0) mit Tests
- ✅ Flutter-App-Gerüst `app/` mit Bibliotheksansicht
- ⏳ Sync-Protokoll und Inbox (M1), danach der Player (M3)

## Entwickeln

```bash
# Voraussetzungen: Zig 0.17.1, Flutter; für Android zusätzlich das NDK

# Kern bauen und testen
cd core && zig build test

# Bibliothek einlesen und anzeigen
zig build run -- scan ~/Musik
zig build run -- status ~/Musik

# App starten (Linux) – CMake baut den Zig-Kern automatisch mit
cd app && flutter run -d linux

# FFI-Tests der App gegen den gebauten Kern
cd app && LD_LIBRARY_PATH=../core/zig-out/lib flutter test

# Android-Bibliothek von Hand bauen (Gradle macht das beim `flutter build apk`)
cd core && zig build -Dtarget=aarch64-linux-android.24 -Doptimize=ReleaseSafe \
  -Dandroid-ndk=$ANDROID_NDK_HOME

# Testdateien neu erzeugen (ffmpeg + mutagen nötig, Ergebnis ist eingecheckt)
python3 core/tools/make_testdata.py
```
