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

Eine **Flutter-App** (Dart) für Linux und Android, darunter ein **Rust-Kern**
(`core/`), angebunden über *flutter_rust_bridge*. Auf dem PC ist die App
Player + Sync + Inbox; auf dem Handy zunächst nur Sync + Inbox (Musicolet
bleibt der Player) – der Player-Teil wäre dort aber ohne Mehraufwand
ebenfalls lauffähig.

```
┌──────────────────────────── Flutter-App (Dart) ─────────────────────────────┐
│ Ordner | Alben | Künstler | … | Warteschlangen | Wiedergabe | Sync-Inbox    │
│ Zustand: Riverpod   ·   Wiedergabe: media_kit (libmpv)                      │
├──────────────────────── flutter_rust_bridge (FFI) ──────────────────────────┤
│ Rust-Kern `core/`                                                           │
│ audiohash · tags (lofty) · manifest/Index (rusqlite, FTS5) · diff/Inbox     │
│ sync-Server/Client (axum + rustls) · mDNS (mdns-sd) · notify (Dateiwächter) │
│ MPRIS2 (mpris-server/zbus, nur Linux)                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Stack
| Bereich | Wahl | Begründung |
|---|---|---|
| Oberfläche | **Flutter** (Dart), Material 3, adaptives Layout | eine UI-Codebasis für Linux-Desktop und Android |
| Kernlogik | **Rust** (`core/`) | schnell, sicher; Scanner, Hashes, Sync und Tags laufen auf beiden Geräten mit *exakt demselben Code* |
| Brücke | flutter_rust_bridge 2 | generiert typsichere Dart-Bindings, Streams für Fortschritt |
| Audio | **media_kit** (libmpv) | alle Formate, Gapless (`gapless-audio`), ReplayGain, Tempo, EQ über mpv-Audiofilter (`lavfi`-`equalizer`/`superequalizer`) |
| Tags | **lofty** (Rust) | liest/schreibt ID3v2/v1, Vorbis Comments, MP4, APE, FLAC-Pictures |
| Datenbank | SQLite über rusqlite (+ FTS5 für Suche) | eine Datei, kein Server, identisch auf beiden Geräten |
| Dateiüberwachung | `notify` (inotify) | Bibliothek aktualisiert sich bei Änderungen sofort |
| Desktop-Integration | MPRIS2 via Rust-Crate `mpris-server` | Medientasten, GNOME/KDE-Mediensteuerung, KDE Connect |
| Android-Integration | `audio_service` (falls Player auf dem Handy), MediaScanner per Platform-Channel | Benachrichtigung, Sperrbildschirm |
| Paketierung | **Flatpak** + AppImage (Linux), APK (Android, Sideload/F-Droid) | läuft auf jeder Distribution |

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
  FTS5-Tabelle für Suche. Nutzt denselben Scanner wie der Sync (Rust-Kern `core/`).
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
│   │   ├── screens/          # library, queues, now_playing, sync_inbox, settings
│   │   ├── player/           # media_kit-Anbindung, Queue-Manager
│   │   └── src/rust/         # generierte Bindings (flutter_rust_bridge)
│   ├── rust/                 # Bridge-Crate: dünne API-Schicht über `core`
│   ├── rust_builder/         # Cargokit: baut Rust automatisch beim `flutter build`
│   ├── linux/  android/
│   └── pubspec.yaml
├── core/                     # Rust-Kern (reine Logik, ohne Flutter testbar)
│   ├── src/{audiohash,tags,manifest,diff}.rs
│   ├── src/bin/mync.rs       # CLI zum Testen: mync scan|status|hash
│   └── tests/                # Formattests mit echten Dateien (ffmpeg)
└── docs/
```
