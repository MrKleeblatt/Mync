# Funktionsstand des Players

Abgleich mit dem Plan in [player-plan.md](player-plan.md).
✅ = umgesetzt und getestet · ◐ = teilweise · ⏳ = offen

## Bibliothek & Navigation
| Funktion | Stand | Anmerkung |
|---|---|---|
| Ordner-Ansicht mit Brotkrumen | ✅ | Hauptansicht; Kontextmenü auch für ganze Ordner (abspielen, mischen, als Nächstes …) |
| Alle Titel, sortierbar (Titel, Künstler, Album, Jahr, Dauer, hinzugefügt, Datei) | ✅ | |
| Suche über Titel, Künstler, Album, Pfad – findet auch Ordner | ✅ | Strg+F |
| Kurze Titel ausblenden | ✅ | Einstellungen |
| Ansichten nach Album, Künstler, Genre, Komponist | – | bewusst entfernt (nicht benötigt) |
| Playlists, Favoriten | – | bewusst entfernt; dafür Statistik-Listen |

## Statistik & Vorschläge
| Funktion | Stand | Anmerkung |
|---|---|---|
| Hörprotokoll | ✅ | `history.jsonl`: was, wann, wie lange (Spulen zählt nicht), übersprungen |
| „Am meisten gehört“ – dieser/letzter Monat, Jahr, gesamt | ✅ | abspielen, mischen, als neue Warteschlange |
| Hörzeit nach Tageszeit und Wochentag | ✅ | Diagramme mit Tooltip, auch als Tabelle |
| Meistgehörte Ordner | ✅ | |
| Vorschläge | ✅ | lange nicht gehört, Unbekanntes aus Lieblingsordnern, mehr vom Künstler, passend zur Tageszeit, neu hinzugefügt; oft Übersprungenes bleibt außen vor |

## Kapitel
| Funktion | Stand | Anmerkung |
|---|---|---|
| Kapitel aus Tags | ✅ | MP3 (ID3 CHAP), FLAC/Ogg/Opus (CHAPTERxxx), M4A/M4B (chpl) |
| Kapitel aus Text wie bei YouTube | ✅ | aus Beschreibung/Kommentar oder `<name>.description` (yt-dlp), `<name>.chapters.txt` |
| Springen | ✅ | Kapitelliste, vor/zurück, Bild ↑/↓, Marken auf dem Fortschrittsbalken |

## Wiedergabe & Warteschlangen
| Funktion | Stand | Anmerkung |
|---|---|---|
| **Mehrere Warteschlangen**, jede mit eigener Position | ✅ | Wechsel setzt exakt dort fort, wo die Warteschlange stand |
| Als Nächstes / ans Ende / in neue Warteschlange | ✅ | ohne Unterbrechung des laufenden Titels |
| Umsortieren (Ziehen), Entfernen, Mischen, Leeren, Umbenennen | ✅ | |
| Fortsetzen nach Neustart | ✅ | Zustand in `state.json` (atomar gespeichert) |
| Wiederholen aus / Warteschlange / Titel | ✅ | je Warteschlange |
| Lückenlose Wiedergabe | ✅ | mpv `gapless-audio` |
| Spulen | ✅ | Knöpfe und ←/→, Schrittweite 5–60 s einstellbar, Umschalt+←/→ = 1 min |
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
| Teil-Updates über GitHub-Releases | ✅ | siehe [updates.md](updates.md); auf Wunsch automatisch |
| Sync mit dem Handy | ⏳ | Meilenstein M1 (Kern-Diff-Engine ist fertig) |

## Tastenkürzel
| Taste | Aktion |
|---|---|
| Leertaste | Abspielen / Pause |
| Strg + → / ← | Nächster / vorheriger Titel |
| → / ← | Spulen (Schrittweite einstellbar) |
| Umschalt + → / ← | 1 min vor / zurück |
| Bild ↑ / Bild ↓ | Vorheriges / nächstes Kapitel |
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
