#!/usr/bin/env python3
"""Versionsprüfung für Pull Requests und Releases (nur Standardbibliothek).

Jeder Merge nach master wird ein Release. Deshalb muss jeder Pull Request
die Version in app/pubspec.yaml erhöhen: Es darf den Tag v<version> noch
nicht geben, und die Version muss höher sein als der höchste Tag v*.

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


def check():
    version = app_version()
    tag = "v" + version
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
