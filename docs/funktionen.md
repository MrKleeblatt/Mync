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
| Mehrere Musikordner | ✅ | weitere Ordner erscheinen als eigene Ordner in der Bibliothek; der Hauptordner wird mit dem Handy abgeglichen |
| Ausschlüsse | ✅ | Muster wie `*.wav`, `Hörproben`, `Podcasts/**/*.mp3` |
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
| Überblenden (Crossfade) | ✅ | 2–12 s, gleiche Leistung; nicht bei Hörbüchern, wahlweise nicht innerhalb eines Albums |
| Position je Datei (Hörbücher) | ✅ | ab einstellbarer Länge (Standard 20 min), auch über Warteschlangen hinweg; Anzeige „gemerkt / Länge“ |
| Tonhöhe, Balance | ✅ | ±6 Halbtöne (rubberband), Balance links/rechts |
| **Applaus überspringen** | ✅ | erkennt Applaus am Anfang und Ende (Live-Aufnahmen), Knopf „Applaus überspringen“ oder automatisch (Einstellungen) |
| Visualisierung | ✅ | Wellenform des Titels hinter der Zeitleiste, bewegt sich mit dem Pegel; Applaus hinterlegt; abschaltbar |

## Tags, Lyrics, Cover
| Funktion | Stand | Anmerkung |
|---|---|---|
| **Tag-Editor** einzeln und für mehrere Dateien | ✅ | MP3, FLAC, Ogg Vorbis, Opus, M4A/M4B, WAV; Audiodaten werden per Hash geprüft |
| Cover anzeigen (eingebettet oder `cover.jpg`/`folder.jpg` …) | ✅ | |
| Cover ändern/entfernen | ✅ | JPEG/PNG, alle Formate |
| Eingebettete Lyrics anzeigen und bearbeiten | ✅ | |
| Synchronisierte Lyrics (`.lrc` daneben oder eingebettet) | ✅ | mitlaufend, Zeile antippen springt dorthin |
| LRC-Editor | ✅ | beim Hören je Zeile Eingabetaste drücken; speichern als `.lrc` oder in die Tags |
| Umbenennen nach Tag-Muster | ✅ | z. B. `/{albumartist}/{album}/{track} {title}`, mit Vorschau; Lyrics/Kapiteldateien wandern mit |

## Klang, Steuerung, System
| Funktion | Stand | Anmerkung |
|---|---|---|
| Equalizer | – | entfernt (nicht benötigt); Balance und ReplayGain unter „Klang“ |
| Sleeptimer (nach Zeit mit Ausblenden, nach Titelende) | ✅ | |
| MPRIS (Medientasten, GNOME/KDE-Mediensteuerung, `playerctl`) | ✅ | |
| Tastenkürzel | ✅ | greifen nicht beim Tippen in Textfeldern |
| Hell/Dunkel | ✅ | |
| Sicherung & Wiederherstellen | ✅ | eine `.mync-backup`-Datei: Einstellungen, Warteschlangen, Statistik, Positionen, wahlweise Kopplungen |
| Mini-Player-Fenster | ✅ | Strg+M, klein und immer im Vordergrund (Linux; unter Wayland je nach Compositor) |
| Teil-Updates über GitHub-Releases | ✅ | siehe [updates.md](updates.md); auf Wunsch automatisch |
| Sync mit dem Handy | ✅ | siehe unten und [sync-konzept.md](sync-konzept.md) |

## Sync mit dem Handy
mync läuft auf PC und Handy; abgeglichen wird der Hauptmusikordner.

1. **Koppeln (einmalig):** Auf einem Gerät unter *Sync* „Kopplung erlauben“,
   auf dem anderen „Gerät suchen“ (oder Adresse eingeben). Beide zeigen einen
   6-stelligen Code – stimmt er überein, auf beiden bestätigen.
2. **Abgleichen:** „Jetzt abgleichen“. Beide Geräte lesen ein und zeigen ihre
   **Inbox**: neue Dateien, Umbenennungen/Verschiebungen, geänderte Tags,
   ersetzte Aufnahmen, Löschungen und Konflikte – jeweils mit *Annehmen*,
   *Nicht jetzt* oder *Immer ignorieren*. Löschungen werden nur einzeln oder
   ausdrücklich mit angenommen.
3. **Anwenden:** Umbenennungen ohne Übertragung, Tags nach Möglichkeit direkt
   geschrieben, sonst die Datei übertragen (SHA-256-geprüft). Gelöschtes
   landet 30 Tage in `.mync-trash/`. Auf Android wird danach der MediaScanner
   angestoßen, damit Musicolet die Änderungen sieht.
4. **Fertig:** Der gemeinsame Stand wird gespeichert – nicht Angenommenes
   erscheint beim nächsten Mal wieder.

Verbindung: TCP im Heimnetz (Port 47788, Suche per UDP 47789),
Ende-zu-Ende verschlüsselt (X25519 + ChaCha20-Poly1305); fremde Geräte ohne
Kopplung werden abgelehnt.

## Wie die Analyse funktioniert
![Wellenform mit erkanntem Applaus](screenshots/visualisierung.png)

Für jeden laufenden und den nächsten Titel dekodiert eine eigene, stumme
mpv-Instanz im Hintergrund (`ao=pcm`, so schnell wie möglich):

- **Wellenform:** Betrag des Signals auf 200 Hz geglättet (Hüllkurve) →
  480 Balken und ein Pegelverlauf mit 20 Werten/s. Eine 25-min-Datei
  braucht etwa 3 s.
- **Applaus:** die ersten und letzten 60 s mit 16 kHz. Je Block von 64 ms
  wird verglichen, ob die Feinstruktur des Spektrums zum vorigen Block
  passt: Bei Musik bleiben Töne und Obertöne an ihrer Stelle (auch bei
  verzerrten Gitarren), bei Applaus ist sie jedes Mal zufällig. Überwiegt
  das in jeder Sekunde, ist es Applaus (mindestens 2 s, Stille davor/danach
  wird übersprungen; reines Rauschen ohne Übergang zu Musik zählt nicht).

Ergebnisse liegen im Cache (`…/analysis/`) und bleiben beim Umbenennen und
Taggen gültig.

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
| Strg + M | Mini-Player ein/aus |
| Im LRC-Editor: Eingabe / Rücktaste / ↑↓ / −+ | Zeit setzen / zurück / Zeile wählen / 0,1 s verschieben |

## Wie getestet
- Zig-Kern: `zig build test` (Hashes, Tag-Lesen/-Schreiben für alle Testdateien,
  Gegenprobe mit mutagen und ffmpeg, Dauer gegen ffprobe).
- App: `flutter test` (Warteschlangen-Logik, LRC-Parser und -Format, Umbenennungsmuster,
  Statistik, Sync-Kanal und kompletter Sync zweier Geräte, mehrere Musikordner,
  Sicherung, FFI gegen den echten Kern).
- Tag-Schreiben: für jede Testdatei bitgleiche PCM-Dekodierung (ffmpeg) vor und
  nach dem Schreiben, Ergebnis mit mutagen gelesen; faststart-M4A und lange
  Opus/Vorbis-Dateien mehrfach umgetaggt.
- Oberfläche: unter Xvfb mit xdotool bedient (Abspielen, Warteschlangen wechseln,
  Als Nächstes, Tag-Editor mit Cover, Lyrics und LRC-Editor, Umbenennen,
  Klang, Überblenden, Hörbuch-Position, Mini-Player, Sync zwischen zwei
  Fenstern, Neustart mit Fortsetzen) und
  MPRIS mit `playerctl` geprüft. Ohne Soundkarte – die Tonausgabe selbst ist
  noch auf einem echten Rechner zu prüfen.
