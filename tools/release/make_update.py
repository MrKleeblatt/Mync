#!/usr/bin/env python3
"""Erzeugt die Update-Dateien für ein GitHub-Release (nur Python-Standardbibliothek).

Ausgabe in --out:
  update-<platform>.json      Manifest: alle Dateien des Programms mit SHA-256,
                              Größe, Rechten und Download-Adresse
  update-<platform>.json.sig  Ed25519-Signatur des Manifests (mit --sign-key)
  f-<sha256[:20]>.gz          NUR die Dateien, deren Inhalt neu ist (Teil-Update)
  mync-<platform>.tar.gz      vollständiges Programm (für Neuinstallationen)

Unveränderte Dateien verweisen auf die Kopie in einem früheren Release
(aus --previous). So lädt jedes Release nur hoch, was sich geändert hat,
und die App lädt nur herunter, was ihr fehlt.

Beispiel (GitHub Actions):
  make_update.py --bundle app/build/linux/x64/release/bundle --version 0.4.1 \\
      --repo mrkleeblatt/mync --previous prev/update-linux-x86_64.json \\
      --sign-key key.txt --signer core/zig-out/bin/mync --out dist
"""
import argparse
import gzip
import hashlib
import json
import os
import subprocess
import sys
import tarfile
import time


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def gzip_file(src, dst):
    # mtime=0: gleiche Eingabe ergibt gleiche Ausgabe
    with open(src, "rb") as f, open(dst, "wb") as out:
        with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=0, compresslevel=9) as gz:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                gz.write(chunk)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bundle", required=True, help="Flutter-Bundle-Verzeichnis (…/release/bundle)")
    ap.add_argument("--version", required=True)
    ap.add_argument("--platform", default="linux-x86_64")
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo", default="mrkleeblatt/mync")
    ap.add_argument("--tag", help="Release-Tag (Standard: v<version>)")
    ap.add_argument("--base-url", help="Download-Adresse der Assets dieses Releases (Standard: GitHub)")
    ap.add_argument("--previous", help="Manifest des vorigen Releases")
    ap.add_argument("--sign-key", help="Datei mit dem geheimen Ed25519-Seed (hex)")
    ap.add_argument("--signer", default="mync", help="Pfad zum CLI `mync` (für `mync sign`)")
    ap.add_argument("--notes", default="", help="Release-Notizen (werden in der App angezeigt)")
    a = ap.parse_args()

    tag = a.tag or f"v{a.version}"
    base = a.base_url or f"https://github.com/{a.repo}/releases/download/{tag}/"
    if not base.endswith("/"):
        base += "/"
    os.makedirs(a.out, exist_ok=True)

    # Bereits veröffentlichte Inhalte (sha256 → Adresse)
    known = {}
    if a.previous and os.path.exists(a.previous):
        with open(a.previous) as f:
            prev = json.load(f)
        for e in prev.get("files", []):
            known[e["sha256"]] = (e["url"], e["gz_size"])

    files, new_blobs, new_bytes, total_bytes = [], 0, 0, 0
    for root, _dirs, names in os.walk(a.bundle):
        for n in names:
            full = os.path.join(root, n)
            if os.path.islink(full):
                continue
            rel = os.path.relpath(full, a.bundle).replace(os.sep, "/")
            digest = sha256(full)
            size = os.path.getsize(full)
            mode = 0o755 if os.access(full, os.X_OK) else 0o644
            if digest in known:
                url, gz_size = known[digest]
            else:
                blob = f"f-{digest[:20]}.gz"
                dst = os.path.join(a.out, blob)
                if not os.path.exists(dst):
                    gzip_file(full, dst)
                    new_blobs += 1
                    new_bytes += os.path.getsize(dst)
                url, gz_size = base + blob, os.path.getsize(dst)
                known[digest] = (url, gz_size)
            total_bytes += gz_size
            files.append({"path": rel, "sha256": digest, "size": size, "mode": mode,
                          "url": url, "gz_size": gz_size})
    files.sort(key=lambda e: e["path"])

    manifest = {
        "format": 1,
        "version": a.version,
        "tag": tag,
        "platform": a.platform,
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "notes": a.notes,
        "files": files,
    }
    mpath = os.path.join(a.out, f"update-{a.platform}.json")
    with open(mpath, "w") as f:
        json.dump(manifest, f, ensure_ascii=False, separators=(",", ":"), sort_keys=True)

    if a.sign_key:
        subprocess.run([a.signer, "sign", a.sign_key, mpath], check=True, stdout=subprocess.DEVNULL)

    # Vollständiges Archiv (Ordner „mync/“)
    tpath = os.path.join(a.out, f"mync-{a.platform}.tar.gz")
    with tarfile.open(tpath, "w:gz") as tar:
        tar.add(a.bundle, arcname="mync")

    print(f"Version {a.version}: {len(files)} Dateien, davon {new_blobs} neu "
          f"({new_bytes / 1e6:.1f} MB von {total_bytes / 1e6:.1f} MB komprimiert)")
    print(f"Manifest: {mpath}{' (signiert)' if a.sign_key else ' (UNSIGNIERT)'}")


if __name__ == "__main__":
    sys.exit(main())
