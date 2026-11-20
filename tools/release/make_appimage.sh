#!/usr/bin/env bash
# Baut das AppImage aus dem Flutter-Bundle.
#   tools/release/make_appimage.sh <bundle> <version> <ausgabeordner>
#
# - Bundle unverändert unter usr/lib/mync (Flutter sucht lib/ und data/
#   neben dem Programm)
# - libmpv samt Abhängigkeiten über linuxdeploy (GTK, glibc, Grafiktreiber
#   kommen vom System, wie bei AppImages üblich)
# - Update-Information für GitHub-Releases + .zsync: AppImageUpdate, Gear
#   Lever usw. laden beim Aktualisieren nur geänderte Blöcke
#
# Die Werkzeuge haben feste Versionen und werden vor dem Ausführen per
# SHA-256 geprüft (Ablage: $TOOLS, Standard .appimage-tools/). Läuft ohne
# FUSE (APPIMAGE_EXTRACT_AND_RUN).
set -euo pipefail
bundle=$(realpath "$1") version=$2 out=$(realpath -m "$3")
root=$(cd "$(dirname "$0")/../.." && pwd)
tools=${TOOLS:-$root/.appimage-tools}
repo=${GITHUB_REPOSITORY:-MrKleeblatt/mync}
export APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64

# Name, Adresse, SHA-256
LINUXDEPLOY=(linuxdeploy
  https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20250213-2/linuxdeploy-x86_64.AppImage
  4648f278ab3ef31f819e67c30d50f462640e5365a77637d7e6f2ad9fd0b4522a)
APPIMAGETOOL=(appimagetool
  https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
  ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0)

fetch() {
  local name=$1 url=$2 sum=$3 file="$tools/$1"
  if [ ! -f "$file" ] || ! echo "$sum  $file" | sha256sum -c --status; then
    curl -fsSL -o "$file.part" "$url"
    echo "$sum  $file.part" | sha256sum -c --status ||
      { echo "Prüfsumme von $name stimmt nicht – Abbruch"; rm -f "$file.part"; exit 1; }
    mv "$file.part" "$file"
  fi
  chmod +x "$file"
}
mkdir -p "$tools" "$out"
fetch "${LINUXDEPLOY[@]}"
fetch "${APPIMAGETOOL[@]}"

libmpv=$(ldconfig -p | awk '/libmpv\.so\.2 .*x86-64/ {print $NF; exit}')
[ -n "$libmpv" ] || { echo "libmpv.so.2 nicht gefunden (apt install libmpv-dev)"; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
app=$work/mync.AppDir
mkdir -p "$app/usr/lib/mync" "$app/usr/share/applications" \
  "$app/usr/share/icons/hicolor/scalable/apps"
# libmpv und ihre Abhängigkeiten nach usr/lib (ohne die Systembibliotheken
# der linuxdeploy-Ausschlussliste) – bevor Desktop-Eintrag und Symbol im
# AppDir liegen, sonst verlangt linuxdeploy ein Programm in usr/bin
"$tools/linuxdeploy" --appdir "$app" --library "$libmpv" > "$work/linuxdeploy.log" 2>&1 ||
  { cat "$work/linuxdeploy.log"; exit 1; }
rm -f "$app/AppRun"
# Was jedes Desktop-System selbst mitbringt, wieder entfernen: GTK lädt
# sonst die gebündelten GLib/Cairo/Pango/X11/Wayland-Kopien und kollidiert
# mit seiner eigenen, neueren Fassung. Übrig bleiben libmpv, FFmpeg und
# die Codec-Bibliotheken.
for pat in \
  'libglib-2.0' 'libgio-2.0' 'libgobject-2.0' 'libgmodule-2.0' 'libgthread-2.0' \
  'libffi' 'libpcre2-' 'libmount' 'libblkid' 'libselinux' \
  'libcairo' 'libpango' 'libpixman-1' 'libgdk_pixbuf-2.0' 'librsvg-2' \
  'libharfbuzz' 'libfontconfig' 'libfreetype' 'libfribidi' 'libthai' 'libdatrie' \
  'libgraphite2' 'libicu' 'libxml2' \
  'libX' 'libxcb' 'libwayland-' 'libxkbcommon' 'libdecor-0' 'libdrm' 'libgbm' \
  'libEGL' 'libGL' 'libvulkan' 'libOpenCL' 'libepoxy' \
  'libdbus-1' 'libsystemd' 'libudev' 'libcap.' 'libapparmor' \
  'libpulse' 'libasyncns' 'libasound' \
  'libgcrypt' 'libgpg-error' 'libgnutls' 'libnettle' 'libhogweed' 'libtasn1' \
  'libp11-kit' 'libidn2' 'libunistring' 'libkrb5' 'libgssapi_krb5' \
  'libk5crypto' 'libkeyutils' 'libcom_err' 'libssl' 'libcrypto' \
  'libtinfo' 'libncursesw' 'libz.' 'libbz2' 'liblzma' 'libzstd' 'liblz4' \
  'libstdc++' 'libgcc_s'; do
  rm -f "$app/usr/lib/$pat"*
done

# media_kit versucht zuerst „libmpv.so“ – ohne diesen Link nähme es eine
# libmpv des Systems (oder fände auf Systemen ohne libmpv gar keine)
[ -f "$app/usr/lib/libmpv.so.2" ] || { echo "libmpv wurde nicht gebündelt"; exit 1; }
ln -sf libmpv.so.2 "$app/usr/lib/libmpv.so"

cp -a "$bundle"/. "$app/usr/lib/mync/"
echo "$version" > "$app/usr/lib/mync/VERSION"
install -m644 "$root/packaging/linux/mync.desktop" "$app/usr/share/applications/mync.desktop"
install -m644 "$root/packaging/linux/mync.svg" "$app/usr/share/icons/hicolor/scalable/apps/mync.svg"
cp "$root/packaging/linux/mync.desktop" "$root/packaging/linux/mync.svg" "$app/"
cp "$root/docs/logo.png" "$app/.DirIcon"


cat > "$app/AppRun" <<'RUN'
#!/bin/sh
# Start des AppImage: gebündelte Bibliotheken (libmpv …) zuerst, Programm
# aus usr/lib/mync. MYNC_PACKAGED sagt der App, dass sie sich nicht selbst
# aktualisieren kann (das AppImage ist schreibgeschützt).
HERE=$(dirname "$(readlink -f "$0")")
export LD_LIBRARY_PATH="$HERE/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export MYNC_PACKAGED=appimage
exec "$HERE/usr/lib/mync/mync" "$@"
RUN
chmod +x "$app/AppRun"

name=mync-x86_64.AppImage
(cd "$out" && VERSION=$version "$tools/appimagetool" --no-appstream \
  -u "gh-releases-zsync|${repo%%/*}|${repo##*/}|latest|$name.zsync" \
  "$app" "$out/$name")
ls -la "$out/$name" "$out/$name.zsync"
