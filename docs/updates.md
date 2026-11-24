# Teil-Updates über GitHub-Releases

mync aktualisiert sich unter Linux und Android selbst – und lädt dabei nur,
was sich seit der installierten Version geändert hat (Android: siehe
[unten](#android-teil-updates-der-apk)).

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
   `version: 0.7.0+7`) und die Adresse in `flake.nix` (`inputs.release.url`)
   auf dasselbe Release setzen – die Versionsprüfung lehnt Abweichungen ab.
3. Pull Request nach `master` öffnen. Der Workflow **„Prüfen und bauen“**
   (`.github/workflows/ci.yml`) läuft automatisch:
   - **Version prüfen** (`tools/release/release_check.py`): Den Tag
     `v<version>` darf es noch nicht geben, und die Version muss höher sein
     als der letzte Tag.
   - **Linux:** `zig build test`, Format-Prüfung, `flutter analyze`,
     `flutter test` (gegen den gebauten Kern), `flutter build linux`,
     `nix flake check` der mitgelieferten Flake (`packaging/nix/flake.nix`).
   - **Android:** `flutter build apk` (baut den Zig-Kern über Gradle mit).
   Jeder weitere Push auf die Branch bricht den laufenden Lauf ab und
   startet ihn mit dem neuen Stand neu (eine Prüfung je Pull Request).
4. Nach dem Merge startet **„Release“** (`.github/workflows/release.yml`):
   Version noch einmal prüfen, Linux-App mit Teil-Update und signierte
   APK bauen, die mitgelieferte Nix-Flake festlegen (`flake.lock`) und mit
   `nix flake check` prüfen, Tag `v<version>` auf den Merge-Commit setzen und das Release
   anlegen. Die Änderungsnotizen sind die Commit-Betreffs seit dem letzten
   Tag.
5. **„Branch aufräumen“** (`.github/workflows/cleanup.yml`) löscht nach dem
   Merge die Branch des Pull Requests. Nur geschlossene (nicht gemergte)
   Pull Requests, Branches aus Forks und `master` bleiben bestehen.

Dateien eines Releases:

| Datei | Inhalt |
|---|---|
| `mync-vX.Y.Z-android-arm64.apk` | Android-App |
| `mync-vX.Y.Z-android-arm64.apk.chunks.json` (+ `.sig`) | Bausteinliste der APK für Teil-Updates |
| `mync-linux-x86_64.tar.gz` | Linux-Programm komplett, mit `flake.nix` + `flake.lock` für Nix (`nix run <URL des Tarballs>`) |
| `mync-x86_64.AppImage` | AppImage (libmpv/FFmpeg enthalten), mit eingebetteter Update-Information |
| `mync-x86_64.AppImage.zsync` | Blockliste: AppImageUpdate/Gear Lever laden nur geänderte Teile |
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

## Nix

- **Im Release:** Der Linux-Tarball enthält `flake.nix` (aus
  `packaging/nix/flake.nix`, Version eingesetzt) und `flake.lock`
  (nixpkgs festgelegt); der Workflow prüft beides mit `nix flake check`.
- **Im Repository:** `flake.nix` bindet das Release ihrer Version ein
  (`nix run github:MrKleeblatt/mync`, Tags = Versionen) und bietet
  `nixosModules.default` und `overlays.default`. Vor dem Release gibt es
  dessen Tarball noch nicht – PR- und Release-Workflow prüfen die Flake
  deshalb mit `--override-input release path:stage`.
- **Updates:** In der Nix-Variante setzt der Wrapper `MYNC_NO_SELF_UPDATE`.
  Die App sucht weiter nach neuen Versionen, installiert aber nichts,
  sondern zeigt `nix profile upgrade --refresh mync` (kopierbar). Geprüft:
  `nix profile upgrade` holt den neuen Tarball hinter derselben Adresse;
  `--refresh` umgeht den Zwischenspeicher von bis zu einer Stunde.

## AppImage

`tools/release/make_appimage.sh` legt das Flutter-Bundle unverändert nach
`usr/lib/mync`, bündelt libmpv mit ihren Abhängigkeiten (linuxdeploy) und
entfernt danach wieder, was jedes Desktop-System mitbringt (GLib, GTK-Umfeld,
X11/Wayland, Grafik, D-Bus, Krypto …) – gebündelte Kopien davon kollidieren
sonst mit dem GTK des Systems. Die Werkzeuge haben feste Versionen und werden
vor dem Ausführen per SHA-256 geprüft. Gebaut wird auf Ubuntu 24.04, das
AppImage braucht also ein System mit glibc ≥ 2.39.

Die App erkennt das AppImage (`MYNC_PACKAGED=appimage`) und installiert
nichts selbst – das Abbild ist schreibgeschützt. Sie meldet neue Versionen
und bietet „Release öffnen“ an; Teil-Updates übernehmen AppImageUpdate oder
Gear Lever über die `.zsync`-Datei.

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

## Android: Teil-Updates der APK

Wie in Kassenbon: Android installiert nur ganze, signierte APKs – mync lädt
aber nur den geänderten Teil und setzt die neue APK selbst zusammen.

1. Die Bausteinliste `<apk>.chunks.json` des neuesten Releases laden und
   (mit eingebautem Schlüssel) ihre Signatur prüfen.
2. Die **installierte APK** (`applicationInfo.sourceDir`, ohne Berechtigung
   lesbar) im Zig-Kern in inhaltsabhängige Bausteine zerlegen
   (`chunker.zig`, Gear-Hash, 8–128 KiB – derselbe Algorithmus und dieselben
   Prüfwerte wie Kassenbon; das Release-Skript zerlegt die neue APK mit
   `mync chunk` genauso).
3. Nur die fehlenden Bausteine laden: einzelne HTTP-Ranges auf die
   Release-Datei (GitHub kennt keine Mehrfachbereiche), nahe Bereiche
   zusammengefasst, 4 gleichzeitig. Die Umleitung auf die signierte
   Download-Adresse wird einmal aufgelöst.
4. Neue APK zusammensetzen, Größe und SHA-256 prüfen. Klappt das
   Teil-Update nicht, wird die ganze APK geladen.
5. Beim ersten Mal „Apps aus dieser Quelle zulassen“ (Android öffnet die
   Einstellung), dann den Paketinstaller öffnen – Android fragt
   „Aktualisieren?“.

Neue Rechte dafür: `REQUEST_INSTALL_PACKAGES` und ein `FileProvider` für den
Update-Ordner der App. **Voraussetzung ist ein fester Signaturschlüssel**
(nächster Abschnitt) – sonst lehnt Android jedes Update ab.

## Anmeldung bei GitHub (privates Repository)

Ist das Repository privat, sieht die App ohne Anmeldung keine Releases. In
*Einstellungen → Info* gibt es dafür **GitHub → Anmelden**: mync zeigt einen
Code, öffnet github.com/login/device, man gibt den Code ein und bestätigt
(Device Flow, wie `gh auth login`). mync sieht dabei nie ein Passwort, und in
der App steckt kein Geheimnis. Das Token liegt nur auf dem Gerät
(`github.json` im Datenordner, nicht in Sicherungen) und wird bei Ablehnung
durch GitHub (401) vergessen.

Geladen wird über die API: Datei des Releases suchen, Umleitung auf die
signierte Download-Adresse auflösen, dort ohne Anmeldung laden (auch die
Bereiche für Teil-Updates).

**Einmalig einrichten** (GitHub-App, darf nur Releases lesen):

1. GitHub → *Settings → Developer settings → GitHub Apps → New GitHub App*
   - Name z. B. `mync-updates`, Homepage: die Repository-Adresse
   - *Webhook*: „Active“ abwählen
   - *Enable Device Flow* anhaken
   - *Expire user authorization tokens* **abwählen** (sonst bräuchte das
     Erneuern ein Client-Secret in der App)
   - *Repository permissions → Contents: Read-only* (sonst nichts)
   - *Where can this GitHub App be installed?* „Only on this account“
2. Nach dem Anlegen: *Install App* → nur das Repository `mync` auswählen.
3. Die **Client ID** der App (beginnt mit `Iv`) als Repository-Variable
   `MYNC_GITHUB_CLIENT_ID` hinterlegen (*Settings → Secrets and variables →
   Actions → Variables*). Sie ist nicht geheim; der Release-Workflow baut sie
   in die App ein.

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

- Android: Installieren muss der Nutzer bestätigen (das verlangt Android für
  Apps außerhalb des Play Stores). Updates gibt es nur für arm64-Geräte.
- Der Workflow baut derzeit nur x86_64.
