[private]
default:
    @just --list

[group("Entwicklung")]
build-core:
    cd core && zig build

[group("Entwicklung")]
test:
    cd core && zig build test && zig build
    cd app && LD_LIBRARY_PATH=../core/zig-out/lib flutter test

[group("Entwicklung")]
run *args:
    cd app && flutter run -d linux {{ args }}

[group("Android")]
build-apk:
    cd app && flutter build apk --split-per-abi

[group("Android")]
print-cert apk="app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk":
    apksigner verify --print-certs {{ apk }}

[group("Android")]
generate-cert file="~/.local/share/mync/mync.jks":
    #!/usr/bin/env bash
    set -euo pipefail
    file={{ file }}
    file=${file/#\~/$HOME}
    if [ -e "$file" ]; then
        echo "$file gibt es schon – nicht überschreiben, sonst lassen sich keine Updates mehr installieren." >&2
        exit 1
    fi
    KEYSTORE_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)
    export KEYSTORE_PASSWORD
    mkdir -p "$(dirname "$file")"
    keytool -genkeypair -keystore "$file" -alias mync -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=mync" -storepass:env KEYSTORE_PASSWORD
    printf %s "$KEYSTORE_PASSWORD" | xclip -selection clipboard
    echo "$file angelegt. Das Passwort liegt in der Zwischenablage: im Passwortmanager speichern,"
    echo "dann mit \`just upload-cert\` in GitHub hinterlegen."

[group("Android")]
upload-cert file="~/.local/share/mync/mync.jks":
    #!/usr/bin/env bash
    set -euo pipefail
    file={{ file }}
    file=${file/#\~/$HOME}
    base64 -w0 "$file" | gh secret set KEYSTORE_BASE64
    gh secret set KEYSTORE_PASSWORD
    gh secret set KEY_ALIAS --body mync

# Version prüfen wie im Pull Request: neuer als der letzte Tag, Flake verweist auf das Release
[group("CI/CD")]
release-check:
    python3 tools/release/release_check.py

# Änderungen seit dem letzten Tag (Markdown)
[group("CI/CD")]
release-notes:
    python3 tools/release/release_check.py --notes

# Schutzregeln des Repos auf GitHub (eingerichtet werden sie von Hand, siehe docs/updates.md)
[group("Forge")]
forge-show:
    gh ruleset list
