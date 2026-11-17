# Sync-Konzept: Handy ⇄ PC mit Bestätigung

## 1. Anforderungen

| # | Anforderung |
|---|---|
| A1 | Audiodateien zwischen Android-Handy (Musicolet) und Linux-PC abgleichen. |
| A2 | **Jede** Änderung muss auf dem **Empfängergerät** vom Nutzer akzeptiert werden. Nichts wird still überschrieben oder gelöscht. |
| A3 | Änderungsarten: Hinzufügen (häufig), Umbenennen/Verschieben (öfter), Tag-Änderung (öfter), Löschen (selten). |
| A4 | Umbenennungen und Tag-Änderungen sollen als solche erkannt werden – nicht als „Datei gelöscht + neue Datei“, und ohne die ganze Datei erneut zu übertragen. |
| A5 | Abgelehnte Änderungen sollen nicht bei jedem Sync erneut nerven. |
| A6 | Funktioniert offline im Heimnetz, ohne Cloud und ohne Konto. |

## 2. Warum nicht einfach Syncthing?

Syncthing ist für die reine Übertragung hervorragend, kennt aber **kein
Freigabe-Konzept pro Änderung**: Ein Ordner ist entweder „Senden & Empfangen“
(alles wird sofort angewendet) oder „Nur empfangen“ (Änderungen landen ohne
Rückfrage). Umbenennungen und Tag-Änderungen werden außerdem nicht semantisch
angezeigt. A2, A4 und A5 sind damit nicht erfüllbar. Gleiches gilt für
FolderSync, rsync o. ä.

Daher: **eigenes, kleines Protokoll** mit einer Freigabe-Oberfläche auf beiden
Geräten. (Syncthing könnte optional als Transportweg für eine
„Posteingang“-Variante dienen, siehe Abschnitt 9.)

## 3. Kernidee

```
 Gerät A (Sender)                                Gerät B (Empfänger)
 ┌──────────────┐  1. Index-Abgleich (Manifest)  ┌──────────────┐
 │ Scanner      │ ─────────────────────────────▶ │ Diff-Engine  │
 │ Manifest-DB  │                                │ Manifest-DB  │
 └──────────────┘                                └──────┬───────┘
                                                        │ 2. Änderungs-
                                                        │    vorschläge
                                                 ┌──────▼───────┐
                                                 │ Freigabe-UI  │  Nutzer:
                                                 │ (Inbox)      │  ✔ / ✘ / später
                                                 └──────┬───────┘
        3. nur benötigte Daten (Dateien / Tags)        │
 ┌──────────────┐ ◀──────────────────────────────────── │
 │ Datei-Server │ ─────────────────────────────▶ ┌──────▼───────┐
 └──────────────┘                                │ Applier      │ 4. atomar anwenden,
                                                 └──────────────┘    Papierkorb, Log
```

1. Jedes Gerät führt ein **Manifest**: eine SQLite-Datenbank mit einem Eintrag
   pro Audiodatei.
2. Beim Sync tauschen die Geräte ihre Manifeste (bzw. die Änderungen seit dem
   letzten gemeinsamen Stand) aus.
3. Der Empfänger berechnet daraus **Änderungsvorschläge** und zeigt sie in
   einer **Inbox** an.
4. Erst nach Bestätigung werden Daten übertragen und Änderungen angewendet.

Der Sync ist **symmetrisch**: Beide Geräte sind abwechselnd Sender und
Empfänger. Ein Sync-Lauf erzeugt auf beiden Seiten je eine Inbox.

## 4. Identität einer Datei – der Schlüssel zu Umbenennung und Tag-Erkennung

Pro Datei werden **zwei Hashes** gespeichert:

| Feld | Berechnung | Ändert sich bei |
|---|---|---|
| `audio_hash` | SHA-256 über die **reinen Audiodaten**: MP3 ohne ID3v2/APEv2/ID3v1, FLAC ohne Metadaten-Blöcke, Ogg ohne Header-Pakete, M4A nur `mdat`, WAV nur `data` (implementiert in `core/src/audiohash.rs`) | nur bei neuem Encoding / anderer Aufnahme |
| `tag_hash` | Hash über die normalisierten Tags (sortierte Schlüssel/Werte) + Cover-Hash | jeder Tag-/Cover-Änderung |
| `path` | relativer Pfad zur Musikwurzel | Umbenennen/Verschieben |

Zusätzlich: `size`, `mtime`, `file_id` (stabile UUID, die mync bei
Erstkontakt vergibt – **nur in der Manifest-DB**, nicht in die Datei
geschrieben, um Dateien nicht ungefragt zu ändern).

Damit lässt sich jede Änderung eindeutig klassifizieren:

| Beobachtung (gegenüber letztem Sync-Stand) | Klassifikation |
|---|---|
| neuer `audio_hash`, kein bekannter Eintrag | **Hinzugefügt** |
| bekannter Eintrag verschwunden, `audio_hash` nirgends mehr vorhanden | **Gelöscht** |
| gleicher `audio_hash`, anderer `path` | **Umbenannt/Verschoben** |
| gleicher `path` + `audio_hash`, anderer `tag_hash` | **Tags geändert** |
| gleicher `audio_hash`, anderer `path` **und** anderer `tag_hash` | **Umbenannt + Tags geändert** (ein Vorschlag, zwei Teile) |
| gleicher `path`, anderer `audio_hash` | **Inhalt ersetzt** (z. B. bessere Qualität) |

Performance: Hashes werden nur neu berechnet, wenn sich `size` oder `mtime`
geändert haben. Ein Rescan einer großen Sammlung kostet dann nur `stat()`-Aufrufe.

## 5. Gemeinsamer Stand („Basis“) und Konflikte

Für einen echten Zwei-Wege-Abgleich braucht jedes Gerät den **letzten
gemeinsam bestätigten Stand** (die *Basis*, wie bei einem 3-Wege-Merge in Git):

- Nach jedem Sync-Lauf speichert jedes Gerät pro `file_id` den Stand, auf den
  sich beide geeinigt haben (`base_path`, `base_audio_hash`, `base_tag_hash`).
- Änderung auf A = Abweichung *A ↔ Basis*. Änderung auf B = Abweichung *B ↔ Basis*.
- Hat nur eine Seite geändert → normaler Vorschlag an die andere Seite.
- Haben **beide** Seiten dieselbe Datei geändert → **Konflikt**, beide Varianten
  werden nebeneinander gezeigt:
  - Tags: feldweiser Vergleich (Titel, Künstler, Album, …), der Nutzer wählt pro
    Feld. Felder, die nur eine Seite geändert hat, werden automatisch
    vorausgewählt (aber nicht ohne Bestätigung angewendet).
  - Pfad: Auswahl „Name von PC“ / „Name vom Handy“.
  - Löschen vs. Ändern: Default-Vorschlag „behalten“.

Beim **allerersten Sync** gibt es keine Basis. Dann werden Dateien über
`audio_hash` gepaart; gleiche Hashes mit unterschiedlichem Pfad/Tags werden als
Konflikt zur Entscheidung gestellt, Dateien nur auf einer Seite als
„Hinzufügen?“-Vorschläge (mit Sammel-Aktion „alle übernehmen“).

## 6. Die Inbox (Freigabe-Oberfläche)

Die Inbox ist auf beiden Geräten identisch aufgebaut:

```
 Eingehende Änderungen vom PC  (37)                     [Alle annehmen] [Alle ablehnen]
 ──────────────────────────────────────────────────────────────────────────────────
 ▾ Hinzugefügt (30)                                     [Gruppe annehmen]
   ☐ Radiohead / In Rainbows / 01 - 15 Step.flac        41 MB   ▶ Vorhören
   …
 ▾ Umbenannt (4)
   ☐ Musik/Unsortiert/track03.mp3 → Musik/Björk/Post/03 - Hyperballad.mp3
 ▾ Tags geändert (2)
   ☐ 03 - Hyperballad.mp3     Album:  "Post (Remaster)" → "Post"
                              Jahr:   –                 → 1995
 ▾ Gelöscht (1)  ⚠
   ☐ Musik/Alt/doppelt.mp3    (landet im mync-Papierkorb, 30 Tage wiederherstellbar)
 ──────────────────────────────────────────────────────────────────────────────────
 Auswahl: [Annehmen] [Ablehnen] [Immer ignorieren] [Später]
```

Regeln:

- **Annehmen** → Änderung wird angewendet, Basis aktualisiert.
- **Ablehnen** → Änderung wird nicht angewendet. Die Datei gilt als
  *divergent*: Die Basis wird auf den Empfängerstand gesetzt, wodurch der
  Empfänger seinerseits dem Sender einen Rückvorschlag macht („auf dem Handy
  heißt die Datei weiterhin X – übernehmen?“). Der Nutzer kann so bewusst
  entscheiden, welche Seite gewinnt.
- **Immer ignorieren** → Eintrag in eine Ignorier-Liste (pro `file_id` +
  Änderungsart, oder per Pfadmuster wie `Podcasts/**`). Erfüllt A5.
- **Später** → bleibt in der Inbox, Basis unverändert.
- Löschungen sind **nie** Teil von „Alle annehmen“, ohne dass ein Warnhinweis
  bestätigt wird.
- Vorhören (Streaming der Datei vom Sender) und Tag-Diff-Ansicht helfen bei der
  Entscheidung.

## 7. Anwenden von Änderungen (sicher und atomar)

| Änderung | Vorgehen auf dem Empfänger |
|---|---|
| Hinzufügen | Datei als `.mync-part` herunterladen → Hash prüfen → atomar umbenennen (`rename`). |
| Umbenennen | Lokales `rename` – **keine Übertragung** nötig. Leere Ordner werden aufgeräumt. |
| Tags | Nur die Tag-Daten (JSON + ggf. Cover) werden übertragen und lokal vom Zig-Kern in die Datei geschrieben. Danach muss `audio_hash` unverändert sein, sonst Rollback. |
| Inhalt ersetzt | wie Hinzufügen, alte Version in den Papierkorb. |
| Löschen | Datei in `.mync-trash/<datum>/…` verschieben (Aufbewahrung konfigurierbar, Standard 30 Tage). |

- Vor jeder schreibenden Aktion wird geprüft, ob die lokale Datei noch dem
  Stand entspricht, auf dem der Vorschlag beruht (sonst → Konflikt statt
  Überschreiben).
- Jede angewendete Aktion wird in einem **Änderungsprotokoll** festgehalten
  (Undo-fähig für Umbenennen/Tags/Löschen).

**Hinweis zu Tags:** Weil Tags lokal neu geschrieben statt kopiert werden,
können sich die Dateien byteweise unterscheiden (Padding, Tag-Version). Das ist
gewollt – verglichen wird über `audio_hash` + normalisierte Tags, nicht über
Byte-Gleichheit.

## 8. Transport und Gerätekopplung

- **Verbindung:** HTTPS (TLS mit selbstsignierten Zertifikaten) im lokalen Netz.
  Geräte finden sich per **mDNS/Zeroconf** (`_mync._tcp`), alternativ IP manuell.
- **Kopplung:** einmalig per **QR-Code** bzw. 6-stelligem Code. Dabei werden die
  Zertifikats-Fingerprints ausgetauscht (Pinning, wie bei Syncthing/KDE Connect).
- **API (Skizze):**
  - `GET  /manifest?since=<seq>` – Manifest-Änderungen seit Sequenznummer
  - `GET  /file/<file_id>` – Datei herunterladen (mit HTTP-Range → Fortsetzen, Vorhören)
  - `GET  /tags/<file_id>` – Tags + Cover als JSON/Binär
  - `POST /sync/session` – Sync-Lauf starten, Ergebnis (angenommen/abgelehnt) melden
- **Fallback USB:** `adb forward` auf denselben Port – gleiches Protokoll, nur
  schneller für den ersten großen Abgleich.

## 9. Wo läuft was? – eine App für beide Geräte

Die Freigabe muss auch **auf dem Handy** erfolgen, also braucht das Handy eine
eigene Komponente. mync ist dafür **eine Flutter-App** (`app/`) für Android
und Linux mit einem gemeinsamen **Kern in Zig** (`core/`):

| Gerät | Rolle der App |
|---|---|
| **Handy** (Android) | Sync-Gegenstelle + Inbox + Benachrichtigung „12 neue Änderungen vom PC“. Abgespielt wird weiter mit Musicolet. |
| **PC** (Linux) | Player + Sync + Inbox |

Weil Scanner, Hash-Berechnung, Diff-Engine und Protokoll in **demselben
Zig-Code** laufen, rechnen beide Geräte garantiert identisch – eine
doppelte Implementierung (und die Gefahr abweichender Hashes) entfällt.

Wer startet den Sync? Der **PC** ist Client und verbindet sich mit dem Handy
(das Handy läuft während des Syncs als Server in einem Foreground-Service).
So muss das Handy nicht dauerhaft im Hintergrund lauschen; gestartet wird
per Knopf in der App, beim Laden im Heim-WLAN (`workmanager`) oder vom PC aus.

Technik:
- **Verschlüsselter Kanal:** Die Zig-Standardbibliothek bringt TLS nur als
  Client mit. Da sich die Geräte ohnehin beim Koppeln kennenlernen, nutzt
  mync stattdessen ein **Noise_XX-Handshake** (X25519, ChaCha20-Poly1305,
  SHA-256 – alles in `std.crypto`) mit beim Koppeln gepinnten statischen
  Schlüsseln. Darin läuft gewöhnliches HTTP/1.1 (`std.http`).
- **Geräteerkennung:** mDNS (`_mync._tcp`), schlanke eigene Implementierung
  über UDP-Multicast (`std.Io.net`).
- **Android-Speicherzugriff:** Für Umbenennen/Löschen/Tag-Schreiben beliebiger
  Audiodateien ist `MANAGE_EXTERNAL_STORAGE` („Zugriff auf alle Dateien“,
  über einen kleinen Platform-Channel in `MainActivity.kt`) am einfachsten – unproblematisch, da die App
  nicht über den Play Store verteilt werden muss (Sideload/F-Droid). Dann
  kann der Zig-Kern direkt mit normalen Dateipfaden arbeiten.
- **Foreground-Service** während des Syncs: `flutter_foreground_task`.
- **Nach dem Anwenden:** Android-MediaScanner für alle geänderten Pfade
  anstoßen (kleiner Platform-Channel zu `MediaScannerConnection.scanFile`),
  damit Musicolet die Änderungen sieht. In Musicolet ggf. „Bibliothek neu
  scannen“.

Verworfene Alternativen: Sync-Kern in Termux (umständlich für den Alltag);
„Posteingang“-Variante mit Syncthing als Transport in einen Staging-Ordner
(doppelter Speicherplatz, schlechtere Erkennung von Umbenennungen).

## 10. Was mit Musicolet-eigenen Daten?

Musicolet speichert Playlists, Warteschlangen, Wiedergabezähler und
Favoriten in seiner eigenen Datenbank, nicht in den Audiodateien.

- **Playlists:** Musicolet kann Playlists als **M3U** exportieren/importieren.
  mync-sync kann einen Ordner `Playlists/` mit `.m3u`-Dateien wie normale
  Dateien synchronisieren (eigene Änderungsart „Playlist geändert“ mit
  Diff der Einträge). mync-player liest/schreibt dieselben M3U-Dateien.
  Pfade in M3U-Dateien werden relativ zur Musikwurzel gespeichert, damit sie
  auf beiden Geräten passen.
- **Wiedergabezähler / Favoriten:** nicht Teil der ersten Versionen. Später
  optional über das Musicolet-Backup (Format muss erst untersucht werden) oder
  über ein Tag (`FMPS_RATING` / `POPM`), falls gewünscht.
- **Lyrics:** `.lrc`-Dateien neben den Audiodateien werden wie Audiodateien
  synchronisiert; eingebettete Lyrics laufen über die Tag-Synchronisation.

## 11. Konfiguration (Beispiel)

```toml
# ~/.config/mync/sync.toml
[library]
root = "~/Musik"
extensions = ["mp3", "flac", "ogg", "opus", "m4a", "wav", "lrc", "m3u"]
ignore = ["**/.thumbnails/**", "Hörbücher/**"]

[trash]
keep_days = 30

[[peer]]
name = "Pixel"
fingerprint = "SHA256:…"
direction = "both"          # both | send-only | receive-only
```

## 12. Datenmodell (SQLite)

```sql
CREATE TABLE file (
  file_id     TEXT PRIMARY KEY,   -- UUID
  path        TEXT UNIQUE NOT NULL,
  size        INTEGER, mtime INTEGER,
  audio_hash  TEXT NOT NULL,
  tag_hash    TEXT NOT NULL,
  tags_json   TEXT,               -- normalisierte Tags für Diffs
  seq         INTEGER NOT NULL,   -- lokale Änderungs-Sequenznummer
  deleted     INTEGER DEFAULT 0
);
CREATE TABLE base (               -- letzter gemeinsamer Stand je Peer
  peer_id TEXT, file_id TEXT,
  path TEXT, audio_hash TEXT, tag_hash TEXT,
  PRIMARY KEY (peer_id, file_id)
);
CREATE TABLE proposal (           -- Inbox
  id INTEGER PRIMARY KEY, peer_id TEXT, file_id TEXT,
  kind TEXT,                      -- add|delete|rename|tags|replace|conflict
  payload_json TEXT, state TEXT   -- pending|accepted|rejected|deferred
);
CREATE TABLE ignore_rule (peer_id TEXT, file_id TEXT, kind TEXT, pattern TEXT);
CREATE TABLE journal (ts INTEGER, action TEXT, details_json TEXT); -- Undo/Log
```
