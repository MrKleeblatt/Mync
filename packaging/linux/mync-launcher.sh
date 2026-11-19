#!/bin/sh
# Startskript für mync: startet die neueste installierte Version.
#  - Systemversion (Paketverwaltung):  /opt/mync
#  - Selbst aktualisierte Version:     ~/.local/share/mync/current (Teil-Updates)
# Gewinnt die höhere Versionsnummer; bei Gleichstand die Systemversion.
sys_dir=${MYNC_SYSTEM_DIR:-/opt/mync}
user_dir="${XDG_DATA_HOME:-$HOME/.local/share}/mync/current"

if [ -x "$user_dir/mync" ] && [ -f "$user_dir/VERSION" ]; then
  uv=$(cat "$user_dir/VERSION")
  sv=$(cat "$sys_dir/VERSION" 2>/dev/null || echo 0)
  if [ "$uv" != "$sv" ] && [ "$(printf '%s\n%s\n' "$sv" "$uv" | sort -V | tail -n 1)" = "$uv" ]; then
    exec "$user_dir/mync" "$@"
  fi
fi
exec "$sys_dir/mync" "$@"
