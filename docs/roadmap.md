# Roadmap

Reihenfolge so gewählt, dass möglichst früh etwas **Nützliches** entsteht:
zuerst der Sync (das eigentliche Problem), dann der Player.

## M0 – Rust-Kern ✅ (erledigt)
- `core/`: `audio_hash` (MP3, FLAC, Ogg Vorbis/Opus, M4A, WAV), normalisierte
  Tags + `tag_hash` (lofty), inkrementeller Manifest-Scan (SQLite) mit
  Umbenennungserkennung, Diff-Engine (add/delete/rename/tags/replace) und
  Inbox-Vorschläge inkl. Konflikten.
- Tests mit echten, per ffmpeg erzeugten Dateien; CLI `mync scan|status|hash`.
- Flutter-App-Gerüst (`app/`) für Linux + Android mit Bibliotheksansicht
  über flutter_rust_bridge.

## M1 – Sync MVP (≈ 3–4 Wochen)
- Basis-Tabelle je Partnergerät, Erst-Sync (Paarung über `audio_hash`).
- HTTPS-Server/Client in Rust, Kopplung per Code, Fingerprint-Pinning.
- Inbox-Bildschirm in Flutter (annehmen/ablehnen/später).
- Anwenden mit `.mync-part`, Papierkorb, Journal/Undo; Tags per lofty schreiben.
- Android: „Zugriff auf alle Dateien“, Foreground-Service, MediaScanner.

## M2 – Inbox-Komfort (≈ 2–3 Wochen)
- Gruppen, Tag-Diff, Vorhören (Streaming vom Partner), „Immer ignorieren“,
  Benachrichtigung auf dem Handy.
- mDNS-Erkennung, QR-Code-Kopplung.
- M3U-Playlists und `.lrc` als synchronisierte Dateitypen.
- Automatischer Sync beim Laden im Heim-WLAN.

## M3 – Player MVP (≈ 4–6 Wochen)
- Ordner/Alben/Künstler/Titel, Suche (FTS5), Wiedergabe mit media_kit, Gapless.
- Mehrere Warteschlangen mit gespeicherter Position, Zustand über Neustarts.
- Tag-Editor (einzeln + mehrfach), Cover, Playlists (M3U).
- MPRIS, Tastenkürzel, Hell/Dunkel.

## M4 – Player 1.0 (≈ 4 Wochen)
- Lyrics (eingebettet + LRC synchron), Equalizer, Sleeptimer, ReplayGain,
  Geschwindigkeit, Statistik/Favoriten, Backup.
- Pfad-Updates für Queues nach Umbenennung durch den Sync.
- Flatpak/AppImage, signierte APK.

## M5 – Komfort (offen)
- Selektiver Sync (nur ausgewählte Ordner aufs Handy).
- Crossfade, LRC-Editor, Umbenennen nach Tag-Muster, Mini-Player.
- Optional: Wiedergabezähler/Favoriten mit Musicolet abgleichen.

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
