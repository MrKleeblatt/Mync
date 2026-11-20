#!/usr/bin/env python3
"""Versionsprüfung für Pull Requests und Releases (nur Standardbibliothek).

Jeder Merge nach master wird ein Release. Deshalb muss jeder Pull Request
die Version in app/pubspec.yaml erhöhen: Es darf den Tag v<version> noch
nicht geben, und die Version muss höher sein als der höchste Tag v*.
Außerdem muss die Flake im Repository (flake.nix) auf genau dieses Release
verweisen.

  release_check.py            prüfen (Exit-Code 1 bei Fehler)
  release_check.py --tag      prüfen und den Tag ausgeben, z. B. v0.6.0
  release_check.py --notes    Änderungen seit dem letzten Tag (Markdown)

Braucht die Tags im Klon (GitHub Actions: fetch-depth: 0).
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], check=True, capture_output=True, text=True).stdout


def parse(v):
    m = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", v.strip())
    return tuple(int(x) for x in m.groups()) if m else None


def app_version():
    with open(os.path.join(ROOT, "app", "pubspec.yaml"), encoding="utf-8") as f:
        for line in f:
            m = re.match(r"version:\s*([0-9]+\.[0-9]+\.[0-9]+)(\+\d+)?\s*$", line)
            if m:
                return m.group(1)
    sys.exit("app/pubspec.yaml: keine Zeile „version: X.Y.Z+N“ gefunden")


def tags():
    out = []
    for t in git("tag", "--list", "v*").split():
        p = parse(t)
        if p:
            out.append((p, t))
    return sorted(out)


def flake_release_tag():
    """Release, auf das die Flake im Repository verweist (inputs.release.url)."""
    path = os.path.join(ROOT, "flake.nix")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        m = re.search(r"/releases/download/(v[0-9.]+)/", f.read())
    return m.group(1) if m else None


def check():
    version = app_version()
    tag = "v" + version
    flake_tag = flake_release_tag()
    if flake_tag is not None and flake_tag != tag:
        sys.exit(f"flake.nix verweist auf {flake_tag}, app/pubspec.yaml hat {version} – "
                 f"bitte die Adresse in flake.nix (inputs.release.url) anpassen.")
    existing = tags()
    if any(t == tag for _, t in existing):
        sys.exit(f"Den Tag {tag} gibt es schon – bitte die Version in app/pubspec.yaml erhöhen.")
    if existing and parse(version) <= existing[-1][0]:
        sys.exit(f"Version {version} ist nicht höher als der letzte Tag {existing[-1][1]}.")
    return tag, (existing[-1][1] if existing else None)


def notes(previous):
    rng = f"{previous}..HEAD" if previous else "HEAD"
    lines = git("log", rng, "--no-merges", "--pretty=format:%s").splitlines()
    if not lines:
        return "Keine Änderungen."
    return "\n".join(f"- {s}" for s in lines)


def main():
    tag, previous = check()
    if "--tag" in sys.argv:
        print(tag)
    elif "--notes" in sys.argv:
        print(notes(previous))
    else:
        print(f"{tag} ist neu" + (f" (letzter Tag: {previous})" if previous else " (erstes Release)"))


if __name__ == "__main__":
    main()
