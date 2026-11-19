#!/usr/bin/env python3
"""Erzeugt die Testdateien in core/testdata/ (einmalig, Ergebnis ist eingecheckt).

Benötigt: ffmpeg, Python-Paket mutagen.
Pro Format entstehen drei Dateien mit identischen Audiodaten:
  <fmt>-plain.<ext>    ohne Tags
  <fmt>-tagged.<ext>   Tags + Cover
  <fmt>-retagged.<ext> andere Tags, sehr lange Lyrics (Ogg: Kommentar über mehrere Seiten)
Die erwarteten Werte stehen in testdata/expected.json.
"""
import base64, hashlib, json, pathlib, shutil, subprocess, sys
from mutagen.id3 import ID3, TIT2, TPE1, TALB, TPE2, TCOM, TCON, TDRC, TRCK, TPOS, COMM, USLT, APIC
from mutagen.flac import FLAC, Picture
from mutagen.oggvorbis import OggVorbis
from mutagen.oggopus import OggOpus
from mutagen.mp4 import MP4, MP4Cover
from mutagen.wave import WAVE
from mutagen.id3 import TXXX, CHAP, CTOC, CTOCFlags

OUT = pathlib.Path(__file__).resolve().parent.parent / "testdata"
# 1×1-PNG als Cover
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

TAGGED = dict(title="Hyperballad", artist="Björk", album="Post", albumartist="Björk",
              composer="Björk Guðmundsdóttir", genre="Pop", date="1995",
              track="2", tracktotal="11", disc="1", disctotal="1",
              comment="Testkommentar", lyrics="We live on a mountain")
RETAGGED = dict(title="Hyperballad (Remaster)", artist="Björk", album="Post",
                track="3", lyrics="la " * 30000)

FORMATS = {
    "mp3": ("mp3", ["-c:a", "libmp3lame", "-b:a", "32k"]),
    "flac": ("flac", []),
    "vorbis": ("ogg", ["-c:a", "libvorbis", "-q:a", "0"]),
    "opus": ("opus", ["-c:a", "libopus", "-b:a", "16k"]),
    "m4a": ("m4a", ["-c:a", "aac", "-b:a", "32k"]),
    "wav": ("wav", ["-c:a", "pcm_s16le"]),
}


def ffmpeg(path, extra):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
                    "sine=frequency=440:duration=0.5:sample_rate=22050",
                    "-ac", "1", "-map_metadata", "-1", "-fflags", "+bitexact",
                    *extra, str(path)], check=True)


def vorbis_tags(t, d, picture):
    m = {"title": "TITLE", "artist": "ARTIST", "album": "ALBUM", "albumartist": "ALBUMARTIST",
         "composer": "COMPOSER", "genre": "GENRE", "date": "DATE", "track": "TRACKNUMBER",
         "tracktotal": "TRACKTOTAL", "disc": "DISCNUMBER", "disctotal": "DISCTOTAL",
         "comment": "COMMENT", "lyrics": "LYRICS"}
    for k, v in d.items():
        t[m[k]] = [v]
    if picture is not None:
        t["METADATA_BLOCK_PICTURE"] = [base64.b64encode(picture.write()).decode()]


def flac_picture():
    p = Picture()
    p.type, p.mime, p.data, p.width, p.height, p.depth = 3, "image/png", PNG, 1, 1, 24
    return p


def id3_frames(tag, d, cover):
    tag.delall("TXXX")
    for cls, k in [(TIT2, "title"), (TPE1, "artist"), (TALB, "album"), (TPE2, "albumartist"),
                   (TCOM, "composer"), (TCON, "genre"), (TDRC, "date")]:
        if k in d:
            tag.add(cls(encoding=3, text=d[k]))
    if "track" in d:
        tag.add(TRCK(encoding=3, text=d["track"] + ("/" + d["tracktotal"] if "tracktotal" in d else "")))
    if "disc" in d:
        tag.add(TPOS(encoding=3, text=d["disc"] + ("/" + d["disctotal"] if "disctotal" in d else "")))
    if "comment" in d:
        tag.add(COMM(encoding=1, lang="deu", desc="", text=d["comment"]))  # UTF-16
    if "lyrics" in d:
        tag.add(USLT(encoding=3, lang="deu", desc="", text=d["lyrics"]))
    if cover:
        tag.add(APIC(encoding=3, mime="image/png", type=3, desc="Cover", data=PNG))


def apply(fmt, path, d, cover, variant):
    if fmt == "mp3":
        t = ID3()
        id3_frames(t, d, cover)
        # tagged: ID3v2.4, retagged: ID3v2.3 + ID3v1
        if variant == "tagged":
            t.save(path, v2_version=4)
        else:
            t.save(path, v2_version=3, v1=2)
    elif fmt == "wav":
        f = WAVE(path)
        f.add_tags()
        id3_frames(f.tags, d, cover)
        f.save()
    elif fmt == "flac":
        f = FLAC(path)
        vorbis_tags(f, d, None)
        if cover:
            f.add_picture(flac_picture())
        f.save()
    elif fmt in ("vorbis", "opus"):
        f = (OggVorbis if fmt == "vorbis" else OggOpus)(path)
        vorbis_tags(f, d, flac_picture() if cover else None)
        f.save()
    elif fmt == "m4a":
        f = MP4(path)
        m = {"title": "\xa9nam", "artist": "\xa9ART", "album": "\xa9alb", "albumartist": "aART",
             "composer": "\xa9wrt", "genre": "\xa9gen", "date": "\xa9day", "comment": "\xa9cmt",
             "lyrics": "\xa9lyr"}
        for k, v in d.items():
            if k in m:
                f[m[k]] = [v]
        if "track" in d:
            f["trkn"] = [(int(d["track"]), int(d.get("tracktotal", 0)))]
        if "disc" in d:
            f["disk"] = [(int(d["disc"]), int(d.get("disctotal", 0)))]
        if cover:
            f["covr"] = [MP4Cover(PNG, imageformat=MP4Cover.FORMAT_PNG)]
        f.save()


CHAPTERS = [(0, "Einleitung"), (150, "Hauptteil – Ärger"), (320, "Schluss")]
# Beschreibung wie bei YouTube (yt-dlp bettet sie als description ein)
DESCRIPTION = """Live-Mitschnitt vom Sommerfest.

Kapitel:
0:00 Begrüßung
0:12 Erstes Lied – Morgenrot
1:05:30 Zugabe
"""


def ffmeta(path):
    lines = [";FFMETADATA1"]
    for i, (start, title) in enumerate(CHAPTERS):
        end = CHAPTERS[i + 1][0] if i + 1 < len(CHAPTERS) else 500
        lines += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={start}", f"END={end}", f"title={title}"]
    path.write_text("\n".join(lines) + "\n")


def chapter_files(expected):
    """Dateien mit Kapiteln: MP3 (ID3 CHAP/CTOC), M4A (chpl), Opus/Vorbis/FLAC (CHAPTERxxx)."""
    meta = OUT / "_chapters.ffmeta"
    ffmeta(meta)
    for fmt, ext, extra in [("mp3", "mp3", ["-c:a", "libmp3lame", "-b:a", "32k", "-id3v2_version", "4"]),
                            ("m4a", "m4a", ["-c:a", "aac", "-b:a", "32k"]),
                            ("opus", "opus", ["-c:a", "libopus", "-b:a", "16k"])]:
        p = OUT / f"{fmt}-chapters.{ext}"
        # ohne -fflags +bitexact, sonst verwirft ffmpeg die Kapiteltitel
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
                        "sine=frequency=440:duration=0.5:sample_rate=22050", "-i", str(meta),
                        "-map", "0", "-map_chapters", "1", "-ac", "1",
                        *extra, str(p)], check=True)
        expected["files"][p.name] = {"group": f"chapters-{fmt}", "fields": {}, "pictures": 0,
                                     "chapters": CHAPTERS, "skip_fields": True}
    for fmt, ext, extra, cls in [("vorbis", "ogg", ["-c:a", "libvorbis", "-q:a", "0"], OggVorbis),
                                 ("flac", "flac", [], FLAC)]:
        p = OUT / f"{fmt}-chapters.{ext}"
        ffmpeg(p, extra)
        f = cls(str(p))
        for i, (start, title) in enumerate(CHAPTERS):
            ms = start
            f[f"CHAPTER{i:03d}"] = [f"00:00:{ms // 1000:02d}.{ms % 1000:03d}"]
            f[f"CHAPTER{i:03d}NAME"] = [title]
        f.save()
        expected["files"][p.name] = {"group": f"chapters-{fmt}", "fields": {}, "pictures": 0, "chapters": CHAPTERS}
    meta.unlink()
    # Beschreibungstexte (für die Kapitelerkennung aus Text)
    d = OUT / "m4a-description.m4a"
    shutil.copy(OUT / "m4a-plain.m4a", d)
    f = MP4(str(d)); f["desc"] = [DESCRIPTION.splitlines()[0]]; f["ldes"] = [DESCRIPTION]; f.save()
    expected["files"][d.name] = {"group": "m4a", "fields": {"description": DESCRIPTION.strip()}, "pictures": 0}
    d = OUT / "mp3-description.mp3"
    shutil.copy(OUT / "mp3-plain.mp3", d)
    t = ID3(); t.add(TXXX(encoding=3, desc="description", text=DESCRIPTION)); t.save(str(d), v2_version=4)
    expected["files"][d.name] = {"group": "mp3", "fields": {"description": DESCRIPTION.strip()}, "pictures": 0}
    d = OUT / "opus-description.opus"
    shutil.copy(OUT / "opus-plain.opus", d)
    f = OggOpus(str(d)); f["DESCRIPTION"] = [DESCRIPTION]; f.save()
    expected["files"][d.name] = {"group": "opus", "fields": {"description": DESCRIPTION.strip()}, "pictures": 0}


def main():
    OUT.mkdir(exist_ok=True)
    expected = {"files": {}}
    for fmt, (ext, extra) in FORMATS.items():
        plain = OUT / f"{fmt}-plain.{ext}"
        ffmpeg(plain, extra)
        expected["files"][plain.name] = {"group": fmt, "fields": {}, "pictures": 0}
        for variant, d, cover in [("tagged", TAGGED, True), ("retagged", RETAGGED, False)]:
            p = OUT / f"{fmt}-{variant}.{ext}"
            shutil.copy(plain, p)
            apply(fmt, str(p), d, cover, variant)
            # Lange Werte als Hash ablegen (normalisiert: Leerraum am Rand entfernt)
            fields = {k: (v if len(v) <= 200 else
                          "sha256:" + hashlib.sha256(v.strip().encode()).hexdigest())
                      for k, v in d.items()}
            expected["files"][p.name] = {"group": fmt, "fields": fields, "pictures": 1 if cover else 0}
    chapter_files(expected)
    (OUT / "expected.json").write_text(json.dumps(expected, ensure_ascii=False, indent=1) + "\n")
    print("ok:", ", ".join(sorted(x.name for x in OUT.iterdir())))


if __name__ == "__main__":
    sys.exit(main())
