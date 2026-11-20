#!/usr/bin/env bash
# Stellt das Linux-Release zusammen: Flutter-Bundle + flake.nix (Version
# eingesetzt) + Desktop-Eintrag und Symbol.  Aufruf:
#   tools/release/stage_linux.sh <bundle> <version> <ziel>
set -euo pipefail
bundle=$1 version=$2 out=$3
root=$(cd "$(dirname "$0")/../.." && pwd)
rm -rf "$out"
mkdir -p "$out"
cp -a "$bundle"/. "$out"/
sed "s/@VERSION@/$version/g" "$root/packaging/nix/flake.nix" > "$out/flake.nix"
install -Dm644 "$root/packaging/linux/mync.desktop" "$out/share/applications/mync.desktop"
install -Dm644 "$root/packaging/linux/mync.svg" "$out/share/icons/hicolor/scalable/apps/mync.svg"
echo "Release zusammengestellt: $out"
