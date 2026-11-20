#!/usr/bin/env bash
# Führt einen Befehl aus und versucht es bei einem Fehler bis zu zweimal
# erneut (je 60 s Pause) – für Builds, die Abhängigkeiten aus dem Netz laden
# (Gradle, pub), damit eine kurze Störung eines Servers nicht den ganzen Lauf
# scheitern lässt.
set -u
for attempt in 1 2; do
  "$@" && exit 0
  echo "::warning::Fehlgeschlagen (Versuch $attempt), neuer Versuch in 60 s: $*"
  sleep 60
done
exec "$@"
