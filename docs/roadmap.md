# Roadmap

Reihenfolge so gewählt, dass möglichst früh etwas **Nützliches** entsteht:
zuerst der Sync (das eigentliche Problem), dann der Player.

## M0 – Kern ✅ (erledigt, in Zig 0.17.1)
- `core/`: `audio_hash` (MP3, FLAC, Ogg Vorbis/Opus/FLAC, M4A, WAV),
  eigene Tag-Leser (ID3v2.2–2.4, ID3v1, Vorbis Comments, MP4, WAV) mit
  normalisierten Feldern + `tag_hash`, inkrementeller Manifest-Scan (SQLite)
  mit Umbenennungserkennung, Diff-Engine (add/delete/rename/tags/replace)
  und Inbox-Vorschläge inkl. Konflikten.
- C-ABI (`mync_scan`, `mync_list_tracks`, …) für `dart:ffi`; CLI `mync scan|status|hash`.
- Tests mit eingecheckten Testdateien aller Formate (erzeugt mit ffmpeg,
  getaggt mit mutagen als unabhängiger Referenz), FFI-Test in Flutter.
- Build für Linux und Android (arm64-v8a, armeabi-v7a, x86_64 über das NDK).
- Flutter-App-Gerüst (`app/`) mit Bibliotheksansicht.

## M1 – Sync MVP (≈ 4–5 Wochen)
- Basis-Tabelle je Partnergerät, Erst-Sync (Paarung über `audio_hash`).
- Tag-**Schreiben** im Zig-Kern (ID3v2.4, Vorbis Comments inkl. Ogg-Neuumbruch,
  FLAC-Blöcke mit Padding, MP4 `ilst` inkl. `stco`-Korrektur) – Tests gegen mutagen.
- Noise_XX-verschlüsselter Kanal + HTTP, Kopplung per Code, Schlüssel-Pinning.
- Inbox-Bildschirm in Flutter (annehmen/ablehnen/später).
- Anwenden mit `.mync-part`, Papierkorb, Journal/Undo.
- Android: „Zugriff auf alle Dateien“, Foreground-Service, MediaScanner.

## M2 – Inbox-Komfort (≈ 2–3 Wochen)
- Gruppen, Tag-Diff, Vorhören (Streaming vom Partner), „Immer ignorieren“,
  Benachrichtigung auf dem Handy.
- mDNS-Erkennung, QR-Code-Kopplung.
- M3U-Playlists und `.lrc` als synchronisierte Dateitypen.
- Automatischer Sync beim Laden im Heim-WLAN.

## M3 – Player MVP ✅ (erledigt)
- Ordner/Alben/Künstler/Genres/Titel, Suche, Wiedergabe mit media_kit, lückenlos.
- Mehrere Warteschlangen mit gespeicherter Position, Zustand über Neustarts.
- Tag-Editor (einzeln + mehrfach) für MP3/FLAC, Cover-Anzeige, Playlists (M3U8).
- MPRIS, Tastenkürzel, Hell/Dunkel.

## M4 – Player 1.0 (größtenteils erledigt)
- ✅ Lyrics (eingebettet + LRC synchron), Equalizer, Sleeptimer, ReplayGain,
  Geschwindigkeit, Statistik, Favoriten.
- ✅ Pfad-Updates für Warteschlangen nach Umbenennungen (Scan erkennt sie über die file_id).
- ✅ Arch-PKGBUILD; ⏳ Flatpak/AppImage, signierte APK.
- ⏳ Tag-Schreiben für Ogg Vorbis/Opus, M4A, WAV.
- ⏳ Cover im Tag-Editor ändern/entfernen, Komponisten-Tab, mehrere Musikordner,
  Backup/Wiederherstellen.

## M5 – Komfort (offen)
- Selektiver Sync (nur ausgewählte Ordner aufs Handy).
- Crossfade, LRC-Editor, Umbenennen nach Tag-Muster, Mini-Player-Fenster,
  Lesezeichen für Hörbücher.

## Offene Fragen an den Nutzer
1. Wie groß ist die Sammlung (Anzahl Dateien, GB)? Passt alles aufs Handy,
   oder soll das Handy nur eine **Teilmenge** bekommen (z. B. ausgewählte Ordner)?
   → Dann bräuchte es „selektiven Sync“ (Ordner pro Gerät auswählen).
2. Welche Formate kommen vor (nur MP3 oder auch FLAC/Opus/M4A)?
3. Liegt die Musik auf dem Handy im internen Speicher oder auf einer SD-Karte?
4. Welche Musicolet-Funktionen sind am wichtigsten – fehlt etwas in
   [player-plan.md](player-plan.md)?
5. Sollen Playlists und Favoriten mitsynchronisiert werden?
6. Desktop-Umgebung am PC (GNOME, KDE, …)? Beeinflusst Feinschliff der Oberfläche.
