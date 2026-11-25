# mync

Musik-Sync zwischen Handy und PC mit Bestätigung, plus Musicolet-artiger Player

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Android-Signaturschlüssel (einmalig)

Android installiert ein Update nur, wenn es mit demselben Schlüssel signiert
ist wie die installierte Version. `android/app/build.gradle.kts` signiert mit
einem festen Schlüssel, sobald `KEYSTORE_FILE` gesetzt ist – sonst mit dem
wechselnden Debug-Schlüssel.

### 1. Schlüssel erzeugen (NixOS, ohne installiertes `keytool`)

`keytool` gehört zum JDK; die Nix-Shell stellt es nur für diesen Befehl
bereit. Zuerst ein zufälliges Passwort erzeugen (32 Zeichen, nur Buchstaben
und Ziffern – braucht nichts außer der Shell) und sofort im Passwortmanager
speichern:

```bash
export KEYSTORE_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
printf %s "$KEYSTORE_PASSWORD" | xclip -selection clipboard
```

Das Passwort liegt jetzt in der Zwischenablage (X11; unter Wayland
`wl-copy` statt `xclip -selection clipboard`) und lässt sich direkt in den
Passwortmanager einfügen. Danach die Zwischenablage leeren, z. B. mit
`printf '' | xclip -selection clipboard`.

Dann den Keystore **außerhalb** des Repositorys anlegen; `keytool` liest das
Passwort aus der Variablen, statt nachzufragen:

```bash
cd ~
nix shell nixpkgs#jdk -c keytool -genkeypair -keystore mync.jks -alias mync \
  -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=mync" \
  -storepass:env KEYSTORE_PASSWORD
```

Ohne Flakes geht dasselbe mit `nix-shell -p jdk --run 'keytool …'`.
Keystore- und Schlüssel-Passwort sind dabei gleich.

### 2. In GitHub hinterlegen

Der Workflow „Release“ liest den Schlüssel aus Repository-Secrets (in
derselben Shell wie oben, damit `KEYSTORE_PASSWORD` noch gesetzt ist):

```bash
cd ~/Projects/mync
base64 -w0 ~/mync.jks | gh secret set KEYSTORE_BASE64
printf %s "$KEYSTORE_PASSWORD" | gh secret set KEYSTORE_PASSWORD
gh secret set KEY_ALIAS --body mync
```

`KEY_PASSWORD` nur setzen, wenn es vom Keystore-Passwort abweicht. Ohne `gh`:
GitHub → *Settings → Secrets and variables → Actions → New repository secret*.

### 3. Lokal signiert bauen (optional)

```bash
export KEYSTORE_FILE=~/mync.jks KEYSTORE_PASSWORD='…' KEY_ALIAS=mync
flutter build apk --split-per-abi
```

Prüfen, womit eine APK signiert ist:

```bash
nix shell nixpkgs#apksigner -c apksigner verify --print-certs build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

### Wichtig

- `mync.jks` und das Passwort sicher aufbewahren (z. B. Passwortmanager) und
  **nie** ins Repository legen. Geht der Schlüssel verloren, muss die App vor
  dem nächsten Update deinstalliert werden.
- Eine bisher mit dem Debug-Schlüssel signierte Installation einmal
  deinstallieren und die erste fest signierte APK neu installieren; danach
  klappen die Updates dauerhaft.
