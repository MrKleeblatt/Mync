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
├── app/          # Android-App (Java): Sync-Gegenstelle + Inbox auf dem Handy
├── linux/        # (geplant) Linux-Seite in Python: mync-core, mync-sync, mync-player
├── docs/         # Konzepte und Pläne
└── …             # Gradle-Dateien des Android-Projekts
```

## Grundsatzentscheidungen (Kurzfassung)

- **Handy:** die Android-App in `app/` (Java, minSdk 29) – sie ist *kein*
  Player, sondern nur Sync-Gegenstelle mit Inbox. Abgespielt wird weiter mit
  Musicolet.
- **PC:** Python 3.12+, GTK 4 + libadwaita, GStreamer, mutagen, SQLite.
- **Gemeinsam ist das Protokoll, nicht der Code:** Beide Seiten implementieren
  dasselbe, sprachneutral spezifizierte Sync-Protokoll (HTTPS + JSON) und
  dieselbe Hash-Berechnung. Gemeinsame Testdateien stellen sicher, dass Java
  und Python identische Hashes liefern.
- **Kein Cloud-Dienst:** Synchronisation direkt im Heim-WLAN (optional USB/adb).
- **Musicolet bleibt der Player auf dem Handy.** mync-sync arbeitet nur auf den
  Dateien; Musicolet erkennt Änderungen über seinen normalen Rescan.
- **Dateien sind die Wahrheit:** Tags stehen in den Audiodateien (ID3, Vorbis
  Comments, MP4-Atoms), nicht in einer eigenen Datenbank. So bleiben Musicolet
  und mync-player kompatibel.

## Status

Planungsphase – es gibt noch keinen Code.
