# Plan: mync-Player – ein Musicolet-artiger Player für Linux

## 1. Ziel

Ein lokaler, werbefreier Offline-Player für Linux, der sich wie Musicolet
anfühlt: dateibasiert, schnell, mehrere Warteschlangen, keine Pflicht zu einer
„perfekt getaggten“ Bibliothek. Er teilt sich Musikordner, Tags, Lyrics und
M3U-Playlists mit dem Handy (siehe [sync-konzept.md](sync-konzept.md)).

> **Hinweis:** Die Funktionsliste unten orientiert sich am bekannten
> Funktionsumfang von Musicolet. Bitte mit der eigenen Musicolet-Version
> abgleichen und fehlende Lieblingsfunktionen ergänzen.

## 2. Funktionsumfang (Musicolet → mync-player)

Priorität: **P1** = MVP, **P2** = Version 1.0, **P3** = später.

### Bibliothek & Navigation
| Funktion (Musicolet) | Umsetzung in mync-player | Prio |
|---|---|---|
| Ordner-Ansicht (echte Verzeichnisstruktur) | Baumansicht der Musikwurzel(n) | P1 |
| Alben, Künstler, Album-Künstler, Genres, Komponisten | Gruppierte Ansichten aus Tags; mehrere Künstler per Trenner (`;`, `/`, `feat.`) aufspaltbar | P1 |
| Alle Titel mit Sortierung | Liste, sortierbar nach Titel/Künstler/Album/Jahr/Dauer/Hinzugefügt/Dateiname | P1 |
| Suche | Volltextsuche über Tags und Pfade, „Suchen während Tippen“ | P1 |
| Mehrere Bibliotheksordner, Ordner ausschließen | Einstellung, Ausschlussmuster | P1 |
| Kurze Dateien ausblenden (z. B. < 30 s) | Filter in Einstellungen | P2 |
| Zuletzt hinzugefügt / Meistgespielt / Zuletzt gespielt | Automatische Listen aus Statistik-DB | P2 |
| Favoriten | Herz-Markierung, als Playlist `Favoriten.m3u` speicherbar (sync-fähig) | P2 |

### Wiedergabe & Warteschlangen
| Funktion | Umsetzung | Prio |
|---|---|---|
| **Mehrere Warteschlangen** (Musicolet: bis zu 20, jede merkt sich Position) | Tabs/Seitenleiste mit beliebig vielen Queues; jede speichert Titel, aktuellen Index und Position in Sekunden | P1 |
| Titel „als Nächstes spielen“ / „ans Ende“ / „in neue Warteschlange“ | Kontextmenü + Tastenkürzel | P1 |
| Warteschlange umsortieren (Drag & Drop), Einträge entfernen | `ReorderableListView` | P1 |
| Wiedergabe fortsetzen, wo man aufgehört hat (auch nach Neustart) | Zustand in SQLite, regelmäßig gesichert | P1 |
| Wiederholen (aus/alle/eins), Zufallswiedergabe | Pro Warteschlange | P1 |
| Lückenlose Wiedergabe (Gapless) | media_kit/mpv `gapless-audio` | P1 |
| Überblenden (Crossfade) | zwei Pipelines + Lautstärkerampe | P3 |
| Wiedergabegeschwindigkeit / Tonhöhe | mpv `speed` + `scaletempo2`, Tonhöhe per `rubberband`-Filter | P2 |
| Lesezeichen / Position merken bei langen Dateien (Hörbücher) | Position pro Datei speichern ab konfigurierbarer Länge | P2 |
| ReplayGain | mpv `replaygain=track|album` | P2 |

### Tags, Lyrics, Cover
| Funktion | Umsetzung | Prio |
|---|---|---|
| **Tag-Editor** (einzeln und mehrere Dateien gleichzeitig) | Dialog mit Feldern Titel, Künstler, Album, Album-Künstler, Komponist, Genre, Jahr, Track-/CD-Nr., Kommentar; Mehrfachbearbeitung zeigt „<verschiedene>“ | P1 |
| Cover anzeigen / ändern / entfernen | Eingebettetes Cover + `cover.jpg`/`folder.jpg` im Ordner | P1 |
| Eingebettete Lyrics | Anzeige im Wiedergabebildschirm; Bearbeiten im Tag-Editor (`USLT`/`LYRICS`) | P2 |
| **Synchronisierte Lyrics (LRC)** | `.lrc` neben der Datei oder eingebettet (`SYLT`/LRC-Text); mitlaufende Zeile, Klick springt zur Zeit | P2 |
| LRC-Editor (Zeitstempel beim Abspielen setzen) | einfacher Editor mit „Zeitstempel setzen“-Taste | P3 |
| Dateien umbenennen nach Tag-Muster | `%artist%/%album%/%track% - %title%` | P3 |

### Playlists
| Funktion | Umsetzung | Prio |
|---|---|---|
| Playlists anlegen/bearbeiten | Gespeichert als `.m3u8` im Ordner `Playlists/` der Musikwurzel → wird mit dem Handy synchronisiert | P1 |
| Import/Export M3U | nativ, da Speicherformat | P1 |
| Warteschlange als Playlist speichern | Kontextmenü | P1 |

### Klang & Steuerung
| Funktion | Umsetzung | Prio |
|---|---|---|
| Equalizer (Bänder + Presets), Bass-Boost | mpv-Audiofilter `superequalizer`; Presets in Config | P2 |
| Balance | `audiopanorama` | P3 |
| Sleeptimer (nach Zeit oder nach Titel/Warteschlangen-Ende) | Timer mit sanftem Ausblenden | P2 |
| Headset-/Medientasten | über **MPRIS** (Desktop leitet Medientasten weiter) | P1 |
| Mehrfachdruck-Gesten (2× = weiter, 3× = zurück) | Musicolet-Feature; am PC über konfigurierbare Tastenkürzel abgebildet | P3 |
| Systemintegration (Benachrichtigung, Sperrbildschirm, Panel-Widget) | MPRIS2 D-Bus-Schnittstelle | P1 |
| Mini-Player / Kompaktmodus | kleines, schwebendes Fenster | P3 |
| Tastenkürzel | Leertaste, Pfeiltasten, Strg+F etc., konfigurierbar | P1 |

### Sonstiges
| Funktion | Umsetzung | Prio |
|---|---|---|
| Offline, keine Werbung, kein Konto | Grundprinzip | P1 |
| Hell/Dunkel-Design, Akzentfarbe | Material 3, folgt dem Systemdesign (hell/dunkel) | P1 |
| Backup & Wiederherstellen (Einstellungen, Queues, Statistik) | Export als ZIP | P2 |
| Wiedergabestatistik | Zähler, zuletzt gespielt; optional in Tag `PCNT`/`FMPS_PLAYCOUNT` schreiben | P2 |
| **Sync-Inbox integriert** | eigener Bereich „Sync“ mit Inbox aus mync-sync | P2 |

## 3. Technische Architektur

Eine **Flutter-App** (Dart) für Linux und Android, darunter ein Kern in
**Zig 0.17.1** (`core/`), als gemeinsame Bibliothek `libmync_core.so` über
`dart:ffi` angebunden. Auf dem PC ist die App Player + Sync + Inbox; auf dem
Handy zunächst nur Sync + Inbox (Musicolet bleibt der Player) – der
Player-Teil wäre dort aber ohne Mehraufwand ebenfalls lauffähig.

```
┌──────────────────────────── Flutter-App (Dart) ─────────────────────────────┐
│ Ordner | Alben | Künstler | … | Warteschlangen | Wiedergabe | Sync-Inbox    │
│ Wiedergabe: media_kit (libmpv)  ·  MPRIS: package:dbus (nur Linux)          │
├─────────────────── dart:ffi  (C-ABI, JSON-Ergebnisse) ──────────────────────┤
│ Zig-Kern `core/` → libmync_core.so                                          │
│ audiohash · tags (eigene Leser/Schreiber) · manifest (SQLite, FTS5)         │
│ diff/Inbox · Sync-Protokoll (std.http über Noise-verschlüsselten Kanal)     │
│ mDNS (std.Io.net, UDP-Multicast) · Dateiwächter (inotify)                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Stack
| Bereich | Wahl | Begründung |
|---|---|---|
| Oberfläche | **Flutter** (Dart), Material 3, adaptives Layout | eine UI-Codebasis für Linux-Desktop und Android |
| Kernlogik | **Zig 0.17.1** (`core/`) | kleine, schnelle native Bibliothek ohne Laufzeit; Scanner, Hashes, Tags und Sync laufen auf beiden Geräten mit *exakt demselben Code*; Cross-Kompilierung für alle Android-ABIs eingebaut |
| Brücke | `dart:ffi` + C-ABI (`mync_*`-Funktionen, JSON) | keine Code-Generierung nötig; lange Aufrufe laufen in `Isolate.run` |
| Audio | **media_kit** (libmpv) | alle Formate, Gapless (`gapless-audio`), ReplayGain, Tempo, EQ über mpv-Audiofilter (`lavfi`-`equalizer`/`superequalizer`) |
| Tags | **eigene Zig-Implementierung** | Lesen: ID3v2.2–2.4, ID3v1, Vorbis Comments (FLAC/Ogg), MP4 `ilst`, WAV – fertig. Schreiben folgt in M1 (wird gegen mutagen getestet) |
| Datenbank | **SQLite** (Amalgamation in `core/vendor`, + FTS5 für Suche) | eine Datei, kein Server, identisch auf beiden Geräten |
| Kryptografie | `std.crypto` (X25519, ChaCha20-Poly1305, SHA-256) | Verschlüsselung des Sync-Kanals ohne Fremdbibliothek |
| Dateiüberwachung | inotify (Linux/Android) | Bibliothek aktualisiert sich bei Änderungen sofort |
| Desktop-Integration | MPRIS2 mit `package:dbus` | Medientasten, GNOME/KDE-Mediensteuerung, KDE Connect |
| Android-Integration | `audio_service` (falls Player auf dem Handy), MediaScanner per Platform-Channel | Benachrichtigung, Sperrbildschirm |
| Paketierung | **Flatpak** + AppImage (Linux), APK (Android, Sideload/F-Droid) | läuft auf jeder Distribution |

**Build:** Unter Linux ruft CMake (`app/linux/CMakeLists.txt`) `zig build`
auf und legt die Bibliothek ins Bundle. Für Android baut ein Gradle-Task
(`app/android/app/build.gradle.kts`) den Kern für arm64-v8a, armeabi-v7a
und x86_64 gegen die libc des NDK (`-Dandroid-ndk=…`) und legt ihn als
`jniLibs` ab.

Präzedenzfall: *Harmonoid* ist ein Flutter-Musikplayer auf Basis von
media_kit für Linux/Windows/Android – der Ansatz ist also erprobt.

### Warum nicht einen bestehenden Player nehmen?
Strawberry, Quod Libet, Lollypop, Rhythmbox, Amberol decken Teile ab, aber
keiner bietet **mehrere unabhängige Warteschlangen mit gemerkter Position**,
die Ordner-zentrierte Bedienung von Musicolet **und** eine integrierte
Sync-Inbox. Ein Plugin für Quod Libet wäre eine mögliche Abkürzung, schränkt
aber das UI-Konzept stark ein – daher eigener Player.

### Datenhaltung
- **library.db** – Index (abgeleitet, jederzeit neu aufbaubar):
  `track(id, path, mtime, size, duration, title, artist, album, albumartist,
  composer, genre, year, track_no, disc_no, has_lyrics, has_lrc, cover_id)`,
  FTS5-Tabelle für Suche. Nutzt denselben Scanner wie der Sync (Zig-Kern `core/`).
- **state.db** – Nutzerzustand (sichern!):
  `queue(id, name, position_index, position_ms, repeat, shuffle)`,
  `queue_item(queue_id, ord, track_path)`, `stats(path, play_count, last_played)`,
  `bookmark(path, position_ms)`, `settings(key, value)`.
- **Dateien** – Tags, Cover, LRC, M3U: die eigentliche Wahrheit, synchronisiert
  per mync-sync.

Tracks werden in Queues/Playlists über den **relativen Pfad** referenziert.
Benennt mync-sync eine Datei um, informiert es den Player (gemeinsames
Journal), damit Queues und Statistik auf den neuen Pfad umgeschrieben werden.

## 4. Oberfläche (Skizze)

```
┌────────────┬──────────────────────────────────────────┬──────────────────────┐
│ Ordner     │  Björk › Post                            │ Warteschlangen  [+]  │
│ Alben      │  ┌────┐ Post · 1995 · 11 Titel           │ ● Q1 Abend    12/40  │
│ Künstler   │  │ ▣  │ [▶ Abspielen] [⤮ Zufall] [+Q]    │ ○ Q2 Joggen    3/25  │
│ Genres     │  └────┘                                  │ ○ Q3 Hörbuch  1:12:03│
│ Komponisten│  01 Army of Me              3:54         │ ──────────────────── │
│ Playlists  │  02 Hyperballad             5:21  ♥      │ ▸ 03 Hyperballad     │
│ ────────── │  03 The Modern Things       4:10         │   04 It's Oh So Quiet│
│ Sync (3)   │  …                                       │   …                  │
├────────────┴──────────────────────────────────────────┴──────────────────────┤
│ ▣ Hyperballad – Björk   ⏮ ⏯ ⏭   ━━━━━━●──────── 2:01 / 5:21   🔁 ⤮  🎚 🕒 ♪ │
└──────────────────────────────────────────────────────────────────────────────┘
```
🎚 = Equalizer, 🕒 = Sleeptimer, ♪ = Lyrics-Ansicht (mitlaufend bei LRC).
Auf schmalen Fenstern (adaptives Flutter-Layout) klappen Seitenleiste und
Queue-Spalte ein – nützlich auch für Linux-Tablets.

## 5. Projektstruktur

```
mync/
├── app/                      # Flutter-App (Linux + Android)
│   ├── lib/
│   │   ├── main.dart
│   │   ├── core/mync_core.dart   # dart:ffi-Anbindung an libmync_core.so
│   │   ├── screens/          # library, queues, now_playing, sync_inbox, settings
│   │   └── player/           # media_kit-Anbindung, Queue-Manager
│   ├── linux/CMakeLists.txt  # baut den Zig-Kern mit
│   ├── android/app/build.gradle.kts  # baut den Zig-Kern je ABI mit
│   └── test/                 # Widget- und FFI-Tests
├── core/                     # Zig-Kern (reine Logik, ohne Flutter testbar)
│   ├── build.zig
│   ├── src/
│   │   ├── audiohash.zig  tags.zig  ogg.zig  diff.zig
│   │   ├── manifest.zig  sqlite.zig  source.zig
│   │   ├── ffi.zig           # C-ABI für dart:ffi
│   │   ├── main.zig          # CLI: mync scan|status|hash
│   │   └── testdata_test.zig # Tests mit echten Dateien
│   ├── testdata/             # Testdateien (ffmpeg + mutagen) + expected.json
│   ├── tools/make_testdata.py
│   └── vendor/sqlite/        # SQLite-Amalgamation
└── docs/
```
