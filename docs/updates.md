# Teil-Updates über GitHub-Releases

mync aktualisiert sich unter Linux selbst – und lädt dabei nur die Dateien,
die sich seit der installierten Version geändert haben.

## So funktioniert es

```
Release v0.4.1 (GitHub)                      App (installiert: 0.4.0)
├── update-linux-x86_64.json   ──────────▶  1. Manifest laden, Signatur prüfen
├── update-linux-x86_64.json.sig            2. SHA-256 jeder Datei mit der
├── f-4bc8c6b9….gz  (geändert)                 installierten vergleichen
├── f-419ad60e….gz  (geändert)   ◀──────────  3. nur Fehlendes laden (hier 3 von 19
├── f-f62184ce….gz  (geändert)                 Dateien, 2,9 statt 11,8 MB)
└── mync-linux-x86_64.tar.gz (komplett)     4. alles prüfen, nach
                                               ~/.local/share/mync/versions/0.4.1
unveränderte Dateien → Verweis auf          5. Symlink …/mync/current atomar umstellen
die Kopie in einem früheren Release         6. „Jetzt neu starten“ (oder beim nächsten Start)
```

- **Manifest**: alle Dateien des Programms mit Pfad, SHA-256, Größe, Rechten
  und Download-Adresse. Inhalte werden über ihren Hash adressiert: Eine Datei,
  die schon in einem früheren Release lag, wird nicht erneut hochgeladen.
- **Signatur** (optional, empfohlen): Ed25519 über das Manifest. Ist in der
  App ein öffentlicher Schlüssel eingebaut, werden unsignierte oder falsch
  signierte Updates abgelehnt. Ohne Schlüssel prüft die App „nur“ HTTPS und
  die SHA-256-Prüfsummen.
- **Rückfall**: Die vorherige Version bleibt erhalten; bricht ein Update ab,
  bleibt alles beim Alten (Teilergebnis wird gelöscht).
- **Startskript** `/usr/bin/mync`: startet die höhere Version – das Paket in
  `/opt/mync` oder das Teil-Update in `~/.local/share/mync/current`.
  Aktualisiert pacman das Paket auf eine noch neuere Version, gewinnt wieder
  das Paket.

## Einstellungen in der App

*Einstellungen → Updates*

- **Automatisch nach Updates suchen** – beim Start und alle 6 Stunden (Standard: an)
- **Updates automatisch herunterladen und installieren** – ohne Nachfrage;
  aktiv nach dem nächsten Start (Standard: aus)
- **Jetzt suchen**, Details mit Änderungsnotizen, **Installieren**, **Neu starten**

Ist ein Update verfügbar oder installiert, erscheint zusätzlich eine Leiste
oben im Fenster.

## Ablauf: Pull Request → Prüfung → Merge → Release

Wie bei Kassenbon ist **jeder Merge nach `master` ein Release**:

1. Entwickelt wird auf einem eigenen Branch (z. B. `dev/<thema>`).
2. Im Branch die Version in `app/pubspec.yaml` erhöhen (z. B.
   `version: 0.6.0+6`) – die einzige Stelle, an der die Version steht.
3. Pull Request nach `master` öffnen. Der Workflow **„Prüfen und bauen“**
   (`.github/workflows/ci.yml`) läuft automatisch:
   - **Version prüfen** (`tools/release/release_check.py`): Den Tag
     `v<version>` darf es noch nicht geben, und die Version muss höher sein
     als der letzte Tag.
   - **Linux:** `zig build test`, Format-Prüfung, `flutter analyze`,
     `flutter test` (gegen den gebauten Kern), `flutter build linux`,
     `nix flake check` der mitgelieferten Flake (`packaging/nix/flake.nix`).
   - **Android:** `flutter build apk` (baut den Zig-Kern über Gradle mit).
4. Nach dem Merge startet **„Release“** (`.github/workflows/release.yml`):
   Version noch einmal prüfen, Linux-App mit Teil-Update und signierte
   APK bauen, die mitgelieferte Nix-Flake festlegen (`flake.lock`) und mit
   `nix flake check` prüfen, Tag `v<version>` auf den Merge-Commit setzen und das Release
   anlegen. Die Änderungsnotizen sind die Commit-Betreffs seit dem letzten
   Tag.

Dateien eines Releases:

| Datei | Inhalt |
|---|---|
| `mync-vX.Y.Z-android-arm64.apk` | Android-App |
| `mync-linux-x86_64.tar.gz` | Linux-Programm komplett, mit `flake.nix` + `flake.lock` für Nix (`nix run <URL des Tarballs>`) |
| `update-linux-x86_64.json` (+ `.sig`) | Manifest für Teil-Updates |
| `f-….gz` | nur die geänderten Programmdateien |
| `SHA256SUMS` | Prüfsummen |

Lokal prüfen, ob die Version passt:

```bash
python3 tools/release/release_check.py
```

**Wichtig:** Alte Releases nicht löschen – neuere Manifeste verweisen auf
deren unveränderte Dateien (bis zur Umstellung nach
[teilupdates-plan.md](teilupdates-plan.md)).

## Einstellungen auf GitHub (einmalig)

Die Workflows allein erzwingen nichts; verbindlich wird der Ablauf erst
durch diese Einstellungen unter *Settings*:

- **General:** Default-Branch `master`.
- **Rules → Rulesets** für `master`:
  - kein direkter Push, nur über Pull Requests, kein Force-Push, nicht löschbar;
  - Status-Checks **„Version prüfen“**, **„Linux (Kern, Tests, App)“** und
    **„Android (APK)“** erforderlich, Branch muss aktuell sein;
  - optional: 1 Freigabe erforderlich.
- **Rules → Rulesets** für Tags `v*` (optional): ändern und löschen
  verbieten, GitHub Actions in die Bypass-Liste (der Workflow legt die Tags an).
- **Actions → General:** Workflows aus Forks nur nach Freigabe;
  *Workflow permissions* „Read and write“ (für das Anlegen des Releases).

## Android-Signaturschlüssel (einmalig)

Android installiert ein Update nur, wenn es mit demselben Schlüssel signiert
ist wie die installierte Version. Ohne festen Schlüssel signiert der Workflow
mit einem wechselnden Debug-Schlüssel (mit Warnung).

```bash
keytool -genkeypair -keystore mync.jks -alias mync -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=mync"
```

```bash
base64 -w0 mync.jks | gh secret set KEYSTORE_BASE64
```

```bash
gh secret set KEYSTORE_PASSWORD
```

```bash
gh secret set KEY_ALIAS --body mync
```

`KEY_PASSWORD` nur, wenn es vom Keystore-Passwort abweicht. `mync.jks` gut
aufbewahren und **nicht** ins Repository legen – geht er verloren, muss die
App vor dem nächsten Update deinstalliert werden.

## Signatur einrichten (einmalig)

```bash
mync-core keygen update-key.txt
```

- Inhalt von `update-key.txt` als Repository-**Secret** `MYNC_UPDATE_KEY` anlegen
  (GitHub → Settings → Secrets and variables → Actions), Datei danach löschen.
- Den ausgegebenen öffentlichen Schlüssel als Repository-**Variable**
  `MYNC_UPDATE_PUBKEY` anlegen – der Workflow baut ihn in die App ein.
  Alternativ in `app/lib/update/update_key.dart` eintragen (dann gilt er auch
  für Builds über das PKGBUILD).

## Lokal testen

```bash
python3 tools/release/make_update.py --bundle app/build/linux/x64/release/bundle \
  --version 0.4.1 --previous alt/update-linux-x86_64.json \
  --base-url http://127.0.0.1:8765/neu/ --out neu
```

```bash
MYNC_UPDATE_URL=http://127.0.0.1:8765/neu/update-linux-x86_64.json mync
```

## Grenzen

- Nur Linux. Auf Android gibt es keine Teil-Updates für Apps außerhalb des
  Play Stores; dort wird die APK aus dem Release installiert.
- Der Workflow baut derzeit nur x86_64.
