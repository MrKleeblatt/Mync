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

In der Devshell (`nix develop ./dev` oder direnv, siehe README im
Wurzelordner):

```bash
just generate-cert       # Passwort erzeugen (Zwischenablage), ~/.local/share/mync/mync.jks anlegen
just upload-cert         # Secrets in GitHub setzen (vorher `gh auth login`)
just print-cert          # Signatur der gebauten APK zeigen
```

Lokal signiert bauen (optional):

```bash
KEYSTORE_FILE=~/.local/share/mync/mync.jks KEYSTORE_PASSWORD='…' KEY_ALIAS=mync just build-apk
```

### Wichtig

- Den Keystore und das Passwort sicher aufbewahren (z. B. Passwortmanager) und
  **nie** ins Repository legen. Geht der Schlüssel verloren, muss die App vor
  dem nächsten Update deinstalliert werden.
- Eine bisher mit dem Debug-Schlüssel signierte Installation einmal
  deinstallieren und die erste fest signierte APK neu installieren; danach
  klappen die Updates dauerhaft.
