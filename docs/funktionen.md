# Funktionsstand des Players

Abgleich mit dem Plan in [player-plan.md](player-plan.md).
✅ = umgesetzt und getestet · ◐ = teilweise · ⏳ = offen

## Bibliothek & Navigation
| Funktion | Stand | Anmerkung |
|---|---|---|
| Ordner-Ansicht mit Brotkrumen | ✅ | Kontextmenü auch für ganze Ordner |
| Alben (Raster mit Covern), Künstler, Album-Künstler, Genres | ✅ | Mehrere Künstler (Mehrfachwerte oder „;“) werden getrennt |
| Komponisten-Ansicht | ⏳ | Daten sind da (`Library.composers`), Tab fehlt noch |
| Alle Titel, sortierbar (Titel, Künstler, Album, Jahr, Dauer, hinzugefügt, Datei) | ✅ | |
| Suche über Titel, Künstler, Album, Genre, Komponist, Pfad | ✅ | Strg+F; zeigt Künstler, Alben und Titel |
| Kurze Titel ausblenden | ✅ | Einstellungen |
| Mehrere Bibliotheksordner, Ordner ausschließen | ⏳ | Ein Musikordner; Ordner mit „.“ am Anfang werden übersprungen |
| Favoriten, zuletzt hinzugefügt, meistgespielt, zuletzt gespielt | ✅ | Favoriten = `Playlists/Favoriten.m3u8` |

## Wiedergabe & Warteschlangen
| Funktion | Stand | Anmerkung |
|---|---|---|
| **Mehrere Warteschlangen**, jede mit eigener Position | ✅ | Wechsel setzt exakt dort fort, wo die Warteschlange stand |
| Als Nächstes / ans Ende / in neue Warteschlange | ✅ | ohne Unterbrechung des laufenden Titels |
| Umsortieren (Ziehen), Entfernen, Mischen, Leeren, Umbenennen | ✅ | |
| Fortsetzen nach Neustart | ✅ | Zustand in `state.json` (atomar gespeichert) |
| Wiederholen aus / Warteschlange / Titel | ✅ | je Warteschlange |
| Lückenlose Wiedergabe | ✅ | mpv `gapless-audio` |
| Geschwindigkeit | ✅ | 0,5–2× |
| ReplayGain (Titel/Album) | ✅ | |
| Überblenden (Crossfade) | ⏳ | |
| Lesezeichen für Hörbücher (Position je Datei) | ⏳ | Position je Warteschlange gibt es schon |
| Tonhöhe, Balance | ⏳ | |

## Tags, Lyrics, Cover
| Funktion | Stand | Anmerkung |
|---|---|---|
| **Tag-Editor** einzeln und für mehrere Dateien | ◐ | Schreiben für **MP3 und FLAC**; Ogg/Opus/M4A/WAV nur lesen |
| Cover anzeigen (eingebettet oder `cover.jpg`/`folder.jpg` …) | ✅ | |
| Cover ändern/entfernen | ⏳ | Cover bleiben beim Tag-Schreiben erhalten |
| Eingebettete Lyrics anzeigen und bearbeiten | ✅ | |
| Synchronisierte Lyrics (`.lrc` daneben oder eingebettet) | ✅ | mitlaufend, Zeile antippen springt dorthin |
| LRC-Editor, Umbenennen nach Tag-Muster | ⏳ | |

## Playlists
| Funktion | Stand | Anmerkung |
|---|---|---|
| Playlists anlegen, umbenennen, löschen, Titel hinzufügen | ✅ | `.m3u8` in `Playlists/` des Musikordners → synchronisierbar |
| Fremde M3U lesen (absolut, relativ, Windows-Pfade) | ✅ | |
| Warteschlange als Playlist speichern | ✅ | |

## Klang, Steuerung, System
| Funktion | Stand | Anmerkung |
|---|---|---|
| Equalizer (10 Bänder, Presets) | ✅ | mpv-Filter mit automatischer Vorabsenkung gegen Übersteuern |
| Sleeptimer (nach Zeit mit Ausblenden, nach Titelende) | ✅ | |
| MPRIS (Medientasten, GNOME/KDE-Mediensteuerung, `playerctl`) | ✅ | |
| Tastenkürzel | ✅ | greifen nicht beim Tippen in Textfeldern |
| Hell/Dunkel | ✅ | |
| Backup & Wiederherstellen | ⏳ | Daten liegen in `~/.local/share/com.github.mrkleeblatt.mync/` |
| Mini-Player-Fenster | ⏳ | |
| Sync mit dem Handy | ⏳ | Meilenstein M1 (Kern-Diff-Engine ist fertig) |

## Tastenkürzel
| Taste | Aktion |
|---|---|
| Leertaste | Abspielen / Pause |
| Strg + → / ← | Nächster / vorheriger Titel |
| → / ← | 10 s vor / zurück |
| Strg + ↑ / ↓ | Lauter / leiser |
| Strg + R | Wiederholen umschalten |
| Strg + S | Warteschlange mischen |
| Strg + F | Suche |
| F5 | Bibliothek neu einlesen |
| Esc | Wiedergabebildschirm schließen |

## Wie getestet
- Zig-Kern: `zig build test` (Hashes, Tag-Lesen/-Schreiben für alle Testdateien,
  Gegenprobe mit mutagen und ffmpeg, Dauer gegen ffprobe).
- App: `flutter test` (Warteschlangen-Logik, LRC-Parser, Playlists, FFI gegen den echten Kern).
- Oberfläche: unter Xvfb mit xdotool bedient (Abspielen, Warteschlangen wechseln,
  Als Nächstes, Tag-Editor, Lyrics, Equalizer, Neustart mit Fortsetzen) und
  MPRIS mit `playerctl` geprüft. Ohne Soundkarte – die Tonausgabe selbst ist
  noch auf einem echten Rechner zu prüfen.
