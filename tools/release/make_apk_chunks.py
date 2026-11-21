#!/usr/bin/env python3
"""Bausteinliste einer APK für Teil-Updates der Android-App (wie Kassenbon).

Schreibt <apk>.chunks.json neben die APK:
  {"version", "name", "url", "size", "sha256", "chunks": [[hash, länge], …]}
und mit --sign-key die Ed25519-Signatur <apk>.chunks.json.sig. Die App
zerlegt ihre installierte APK genauso (Zig-Kern, chunker.zig) und lädt nur
die fehlenden Bausteine per HTTP-Range aus dem Release.

  make_apk_chunks.py dist/mync-v0.8.0-android-arm64.apk --version 0.8.0 \\
      --repo MrKleeblatt/mync --tag v0.8.0 --mync core/zig-out/bin/mync \\
      [--sign-key key.txt]
"""
import argparse
import json
import os
import subprocess


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("apk")
    ap.add_argument("--version", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--mync", default="mync", help="Pfad zum CLI `mync` (chunk, sign)")
    ap.add_argument("--sign-key", help="Datei mit dem geheimen Ed25519-Seed (hex)")
    a = ap.parse_args()

    out = subprocess.run([a.mync, "chunk", a.apk], check=True, capture_output=True, text=True).stdout
    c = json.loads(out)
    name = os.path.basename(a.apk)
    manifest = {
        "version": a.version,
        "name": name,
        "url": f"https://github.com/{a.repo}/releases/download/{a.tag}/{name}",
        "size": c["size"],
        "sha256": c["sha256"],
        "chunks": c["chunks"],
    }
    path = a.apk + ".chunks.json"
    with open(path, "w") as f:
        json.dump(manifest, f, separators=(",", ":"))
    if a.sign_key:
        subprocess.run([a.mync, "sign", a.sign_key, path], check=True, stdout=subprocess.DEVNULL)
    print(f"{path}: {len(c['chunks'])} Bausteine{' (signiert)' if a.sign_key else ' (UNSIGNIERT)'}")


if __name__ == "__main__":
    main()
