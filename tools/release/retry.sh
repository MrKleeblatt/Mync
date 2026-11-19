#!/usr/bin/env bash
# Führt einen Befehl aus und versucht es nach einer Pause einmal erneut –
# für Builds, die Abhängigkeiten aus dem Netz laden (Gradle, pub), damit
# eine kurze Störung eines Servers nicht den ganzen Lauf scheitern lässt.
set -u
"$@" && exit 0
echo "::warning::Fehlgeschlagen, neuer Versuch in 30 s: $*"
sleep 30
exec "$@"
