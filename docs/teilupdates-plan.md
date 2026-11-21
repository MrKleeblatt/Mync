# Plan: Teil-Updates nach dem Vorbild von Kassenbon

> **Stand:** Android ist umgesetzt (Schritte 1, 3 ohne Wiederaufnahme, 5, 6 –
> siehe [updates.md](updates.md#android-teil-updates-der-apk)). Linux nutzt
> weiter das Manifest mit geänderten Dateien (Schritte 2 und 4 offen).

Stand heute (siehe [updates.md](updates.md)): Unter Linux lädt mync nur
**geänderte Dateien** (Manifest mit SHA-256 je Datei, unveränderte Dateien
verweisen auf frühere Releases). Zwei Schwächen:

1. Eine einzige geänderte große Datei wird ganz geladen. Praktisch ändert sich
   bei jedem Release `lib/libapp.so` (der kompilierte Dart-Code, mehrere MB)
   – also wird fast immer der größte Teil geladen.
2. **Android hat gar keine Teil-Updates**: Android installiert nur ganze,
   signierte APKs.

Kassenbon (`MrKleeblatt/kassenbon`, `app/lib/delta.dart`,
`backend/src/chunker.zig`, `app/lib/platform/installer_io.dart`) löst genau
das: Die **installierte APK** wird in inhaltsabhängige Bausteine zerlegt, die
neue APK auf dieselbe Weise; geladen werden nur die fehlenden Bausteine, die
neue APK wird Byte für Byte zusammengesetzt, per SHA-256 geprüft und dann ganz
normal an den Paketinstaller übergeben. Android sieht eine vollständige,
korrekt signierte APK – heruntergeladen wurde aber nur der geänderte Teil.

Diesen Ansatz übernimmt mync, mit zwei Unterschieden: Es gibt keinen eigenen
Server (Kassenbon hat `/app/ranges`), sondern nur GitHub-Releases. Und mync
nutzt ihn auch für Linux.

## 1. Bausteine: Content-Defined Chunking wie in Kassenbon

Übernommen unverändert, damit die Logik bewährt ist:

- **Gear-Hash** mit 256 Zufallszahlen aus splitmix64 (eigener Startwert, z. B.
  `"MYNC-CDC"` statt `"KASSENBO"`), Schnitt, wenn `h & (2^15 − 1) == 0`.
- Bausteingröße **mindestens 8 KiB, höchstens 128 KiB**, im Mittel ≈ 40 KiB.
- Baustein-ID = die ersten 16 Byte von SHA-256 (hex).
- Weil die Schnitte vom Inhalt abhängen, verschiebt eine Einfügung nur die
  Bausteine in ihrer Nähe; alles danach wird wiedererkannt (in Kassenbons Test:
  5 KB Änderung in 300 KB → weniger als ⅓ zu laden).

**Unterschied:** In Kassenbon gibt es den Chunker doppelt (Zig im Server, Dart
in der App) und Prüfwerte halten beide gleich. In mync gibt es nur **eine**
Implementierung, im Zig-Kern (`core/src/chunker.zig`):

- FFI `mync_chunk_file(path)` → `[[hash, offset, length], …]` (für die App, im Isolate)
- CLI `mync chunk <datei>` → dasselbe als JSON (für das Release-Skript)
- Tests mit festen Prüfwerten (Kassenbons `testData()`: 300 000 Byte aus
  splitmix64, Startwert 42) – so ist der Algorithmus auch gegen Kassenbon
  abgesichert.

## 2. Was im Release liegt

Für jede Zielplattform ein **Paket** (eine große Datei) plus eine signierte
Bausteinliste:

| Datei | Inhalt |
|---|---|
| `mync-vX.Y.Z-android-arm64.apk` | die APK (signiert mit festem Schlüssel, siehe 5.) |
| `mync-vX.Y.Z-android-arm64.apk.chunks.json` (+ `.sig`) | Bausteinliste der APK |
| `mync-vX.Y.Z-linux-x86_64.pack` | alle Programmdateien unkomprimiert hintereinander |
| `update-linux-x86_64.json` (+ `.sig`) | Manifest: Dateien (Pfad, Rechte, SHA-256, Größe) und je Datei ihre Bausteine mit Lage im `.pack` |
| `mync-linux-x86_64.tar.gz` | wie bisher, für Neuinstallation und als Rückfall |

Bausteinliste (Format wie Kassenbons `Manifest`, ergänzt um Version und Datei-URL):

```json
{
  "version": "0.6.0",
  "name": "mync-v0.6.0-android-arm64.apk",
  "url": "https://github.com/MrKleeblatt/mync/releases/download/v0.6.0/mync-v0.6.0-android-arm64.apk",
  "size": 31457280,
  "sha256": "…",
  "chunks": [["2c12667d4ab2cedc82508ad421eb578f", 15101], …]
}
```

Signiert wird mit dem schon vorhandenen Ed25519-Schlüssel
(`MYNC_UPDATE_KEY`, `core/src/sign.zig`). Die App lehnt unsignierte Listen ab,
sobald ein öffentlicher Schlüssel eingebaut ist – wie bisher beim Linux-Manifest.

Warum unter Linux ein `.pack` statt vieler Einzeldateien: Ranges gehen nur
innerhalb einer Datei, und ein einziges Paket erspart hunderte
Release-Assets. Das bisherige Verweisen auf alte Releases entfällt damit –
**alte Releases dürfen dann gelöscht werden**, weil das Gegenstück zur neuen
Version immer die *installierte* Version auf dem Gerät ist, nicht ein altes
Release.

## 3. Laden: einzelne HTTP-Ranges von GitHub

Kassenbon schickt alle Bereiche in einem POST an den eigenen Server. GitHub
kann das nicht. Geprüft (18.11.2026):

- `Range: bytes=0-15` auf eine Release-Datei → **206**, nach Umleitung zu
  `release-assets.githubusercontent.com` (signierte URL, ca. 1 h gültig).
- mehrere Bereiche in einer Anfrage (`bytes=0-3,100-103`) → **501**.

Also:

1. Release-URL **einmal** auflösen (Umleitung folgen, die signierte URL merken;
   läuft sie ab → neu auflösen).
2. Fehlende Bausteine wie bei Kassenbon (`plan()`) zu zusammenhängenden
   Bereichen verbinden. Zusätzlich **Lücken bis 64 KiB mitladen**, wenn das
   Anfragen spart (vorhandene Bytes im Lückenbereich werden verworfen).
3. Höchstens **4 Anfragen gleichzeitig**, jede Antwort wird gegen die
   erwartete Länge und danach jeder Baustein gegen seinen Hash geprüft.
4. Abbruch und Wiederaufnahme: geladene Bausteine landen in
   `updates/<version>/chunks/<hash>`; ein erneuter Versuch lädt nur, was fehlt.
5. Rückfall wie bei Kassenbon: Klappt das Teil-Update nicht, die ganze Datei
   laden (mit Fortschrittsanzeige).

## 4. Zusammensetzen und Installieren

**Android** (wie `installer_io.dart`):

1. Pfad der installierten APK über den Kanal `mync/storage`
   (`applicationInfo.sourceDir`) – lesbar ohne Berechtigung.
2. `mync_chunk_file` darauf → vorhandene Bausteine; fehlende laden (3.).
3. Neue APK zusammensetzen, Größe und SHA-256 gegen die signierte Liste prüfen.
4. In `cacheDir/updates/` schreiben, alte Dateien dort löschen.
5. `canRequestPackageInstalls()` prüfen; sonst
   `ACTION_MANAGE_UNKNOWN_APP_SOURCES` öffnen und den Nutzer bitten,
   „Apps aus dieser Quelle zulassen“ einzuschalten.
6. `ACTION_VIEW` mit `FileProvider`-URI (`<package>.updates`) → Android fragt
   wie gewohnt „Aktualisieren?“. Neue Rechte: `REQUEST_INSTALL_PACKAGES`,
   `<provider>` mit `res/xml/update_paths.xml`.

„Automatisch installieren“ heißt auf Android: automatisch **herunterladen**
und den Installer anbieten – ohne Bestätigung installieren darf eine normale
App nicht.

**Linux**:

1. Für jede installierte Datei der aktuellen Version die Bausteine bilden
   (einmal je Version, Ergebnis in `versions/<v>/.chunks.json` zwischenspeichern).
2. Jede Datei der neuen Version aus vorhandenen Bausteinen (irgendeiner Datei)
   plus geladenen Bausteinen zusammensetzen, SHA-256 je Datei prüfen.
3. Dann wie bisher: nach `versions/<neu>/`, Symlink `current` atomar
   umstellen, alte Version als Rückfall behalten.

## 5. Release-Workflow

- **APK bauen und signieren**: `flutter build apk --split-per-abi`,
  Schlüssel aus den Secrets `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`,
  `KEY_ALIAS` (wie in Kassenbons `deploy/release.md`, inkl. `just
  app-keygen`-artigem Hilfsskript). Ohne festen Schlüssel kann Android kein
  Update installieren – das ist Voraussetzung, nicht Kür.
- `tools/release/make_update.py` umbauen: ruft `mync chunk` auf, schreibt
  `.pack`, Manifeste und Bausteinlisten, signiert sie.
- Upload aller Dateien wie bisher mit `gh release upload`.
- **versionCode**: Flutter addiert bei `--split-per-abi` 2000 für arm64; die
  App rechnet das wie Kassenbons `buildNumberWithoutAbi` heraus, damit der
  Versionsvergleich stimmt.

## 6. Tests

- Zig: Prüfwerte des Chunkers (Bausteinlängen für `testData()`), Plan und
  Zusammensetzen mit Einfügung/Löschung/Änderung, falsche Daten → Fehler.
- Dart: Range-Planung mit Lückenfüllung, Wiederaufnahme, Rückfall auf ganze
  Datei; ein lokaler HTTP-Server im Test liefert 206/501 wie GitHub.
- Ende-zu-Ende: zwei echte Builds hintereinander (z. B. nur ein Text
  geändert) → gemessen, wie viel geladen wird; Ziel: unter 20 % der APK.
- Android-Emulator: Installer-Ablauf mit festem Testschlüssel.

## 7. Reihenfolge und Aufwand

| Schritt | Inhalt | Aufwand |
|---|---|---|
| 1 | `chunker.zig` + FFI + CLI + Prüfwerte | 0,5 Tag |
| 2 | `make_update.py`: `.pack`, Bausteinlisten, Signatur | 0,5 Tag |
| 3 | Dart: Planen, Range-Laden mit Lücken/Parallelität/Wiederaufnahme | 1 Tag |
| 4 | Linux: Zusammensetzen aus Bausteinen, bisherige Installation weiterverwenden | 0,5 Tag |
| 5 | Android: Kanal (APK-Pfad, Installer, FileProvider), Einstellungen | 1 Tag |
| 6 | Workflow: APK signieren, hochladen; Secrets dokumentieren | 0,5 Tag |
| 7 | Messung mit zwei echten Releases, Doku `updates.md` | 0,5 Tag |

**Vorab von Ihnen zu klären:** Signaturschlüssel für die APK anlegen und als
Secrets hinterlegen (einmalig; ohne festen Schlüssel kein Android-Update),
und ob alte Releases nach der Umstellung gelöscht werden dürfen.
