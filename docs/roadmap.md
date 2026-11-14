# Roadmap

Reihenfolge so gewählt, dass möglichst früh etwas **Nützliches** entsteht:
zuerst der Sync (das eigentliche Problem), dann der Player.

## M0 – Protokoll & Grundlage (≈ 1–2 Wochen)
- Hash-Definition und Tag-Normalisierung festschreiben; `docs/testvektoren/` anlegen.
- `linux/mync_core`: Scanner (`stat`-basiertes Inkrement), `audio_hash`/`tag_hash`
  für MP3, FLAC, Ogg/Opus, M4A, Manifest-DB, CLI `mync scan`, `mync status`.
- Android `app/`: auf Java 17 anheben, Berechtigung „Zugriff auf alle Dateien“,
  Musikordner wählen, Scanner + Hashes (jaudiotagger) – gleiche Ergebnisse
  wie Python auf den Testvektoren.

## M1 – Sync MVP (≈ 3–4 Wochen)
- Diff-Engine mit Basis (3-Wege), Klassifikation add/delete/rename/tags/replace/conflict
  – auf beiden Seiten.
- Android: HTTPS-Server im Foreground-Service, Kopplung per Code,
  Fingerprint-Pinning; einfache Inbox-Liste (annehmen/ablehnen).
- PC: Client + Inbox als CLI (`mync inbox`, `mync accept 3 5 7`, `mync reject …`).
- Anwenden mit `.mync-part`, Papierkorb, Journal/Undo; MediaScanner anstoßen.

## M2 – Inbox-Komfort (≈ 2–3 Wochen)
- Android-Inbox: Gruppen, Tag-Diff, Vorhören, „Immer ignorieren“, Benachrichtigung.
- PC: Web-UI für die Inbox (lokal, z. B. Starlette + HTML/JS).
- mDNS-Erkennung (`NsdManager` / zeroconf), QR-Code-Kopplung.
- M3U-Playlists und `.lrc` als synchronisierte Dateitypen.
- Automatischer Sync beim Laden im Heim-WLAN (WorkManager).

## M3 – Player MVP (≈ 4–6 Wochen)
- GTK-4-App: Ordner/Alben/Künstler/Titel, Suche, Wiedergabe mit Gapless.
- Mehrere Warteschlangen mit gespeicherter Position, Zustand über Neustarts.
- Tag-Editor (einzeln + mehrfach), Cover, Playlists (M3U).
- MPRIS, Tastenkürzel, Hell/Dunkel.

## M4 – Player 1.0 (≈ 4 Wochen)
- Lyrics (eingebettet + LRC synchron), Equalizer, Sleeptimer, ReplayGain,
  Geschwindigkeit, Statistik/Favoriten, Backup.
- Sync-Inbox im Player integriert; Pfad-Updates für Queues nach Umbenennung.
- Flatpak-Paket.

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
