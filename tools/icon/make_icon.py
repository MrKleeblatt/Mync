#!/usr/bin/env python3
"""Erzeugt das mync-Logo in allen Größen aus einer Geometrie.

  python3 tools/icon/make_icon.py          (braucht: pip install cairosvg)

Motiv: fünf Wellenform-Balken (Musik) in einem Ring aus zwei Pfeilbögen
(Sync), Kupfer auf fast schwarzem Grund – passend zum Design „Graphit“.
Ausgabe: packaging/linux/mync.svg, docs/logo.png, Android-Launcher-Icons
(adaptiv + PNG), Android-Benachrichtigungssymbol, Linux-Fenstersymbol.
"""
import math
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RES = os.path.join(ROOT, "app/android/app/src/main/res")

COPPER_HI, COPPER_LO = "#E9B774", "#BF8040"
BG_HI, BG_LO = "#1F2125", "#121316"

# Geometrie im Raster 0..100, Mitte (50, 50)
R = 37.0          # Ringradius
RING_W = 6.2      # Strichstärke Ring
BARS = [17, 31, 44, 27, 15]   # Balkenhöhen
BAR_W, BAR_GAP = 5.6, 3.4


def pt(a, r=R):
    t = math.radians(a)
    return 50 + r * math.cos(t), 50 + r * math.sin(t)


def arc_with_head(a0, a1):
    """Bogen von a0 bis a1 (Grad, im Uhrzeigersinn) mit Pfeilspitze am Ende.

    Die Spitze sitzt genau auf dem Bogenende (Mitte ihrer Grundlinie) und
    zeigt entlang der Tangente weiter im Uhrzeigersinn.
    """
    x0, y0 = pt(a0)
    x1, y1 = pt(a1)
    large = 1 if (a1 - a0) % 360 > 180 else 0
    arc = f"M{x0:.2f} {y0:.2f}A{R} {R} 0 {large} 1 {x1:.2f} {y1:.2f}"
    t = math.radians(a1)
    tx, ty = -math.sin(t), math.cos(t)   # Tangente (Uhrzeigersinn)
    nx, ny = math.cos(t), math.sin(t)    # nach außen
    length, half = 9.0, 6.6
    tip = (x1 + tx * length, y1 + ty * length)
    b1 = (x1 + nx * half, y1 + ny * half)
    b2 = (x1 - nx * half, y1 - ny * half)
    head = f"M{tip[0]:.2f} {tip[1]:.2f}L{b1[0]:.2f} {b1[1]:.2f}L{b2[0]:.2f} {b2[1]:.2f}Z"
    return arc, head


ARCS = [arc_with_head(-165, -38), arc_with_head(15, 142)]


def bars():
    n = len(BARS)
    total = n * BAR_W + (n - 1) * BAR_GAP
    x = 50 - total / 2
    out = []
    for h in BARS:
        out.append((x, 50 - h / 2, BAR_W, h))
        x += BAR_W + BAR_GAP
    return out


def glyph_svg(fill, stroke):
    parts = []
    for arc, head in ARCS:
        parts.append(f'<path d="{arc}" fill="none" stroke="{stroke}" stroke-width="{RING_W}" stroke-linecap="round"/>')
        parts.append(f'<path d="{head}" fill="{fill}" stroke="{fill}" stroke-width="1.2" stroke-linejoin="round"/>')
    for x, y, w, h in bars():
        parts.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{w}" height="{h}" rx="{w / 2}" fill="{fill}"/>')
    return "\n    ".join(parts)


def full_svg(size=256, rounded=True):
    s = size / 100
    bg = (
        f'<rect x="2" y="2" width="96" height="96" rx="{22 if rounded else 0}" fill="url(#bg)"/>'
        '<rect x="2.5" y="2.5" width="95" height="95" rx="21.5" fill="none" stroke="#2C2E33" stroke-width="1"/>'
        if rounded else '<rect width="100" height="100" fill="url(#bg)"/>'
    )
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="{size}" height="{size}">
  <!-- mync – erzeugt von tools/icon/make_icon.py -->
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{BG_HI}"/><stop offset="1" stop-color="{BG_LO}"/>
    </linearGradient>
    <linearGradient id="cu" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{COPPER_HI}"/><stop offset="1" stop-color="{COPPER_LO}"/>
    </linearGradient>
  </defs>
  {bg}
  <g transform="translate(50 50) scale(0.82) translate(-50 -50)">
    {glyph_svg("url(#cu)", "url(#cu)")}
  </g>
</svg>
'''


def vector_paths(color, scale, offset):
    """Android-VectorDrawable-Pfade (Balken als Pfade mit runden Enden)."""
    def tr(d):
        return d  # Transformation erledigt die <group>
    out = []
    for arc, head in ARCS:
        out.append(f'<path android:pathData="{arc}" android:strokeColor="{color}" android:strokeWidth="{RING_W}" android:strokeLineCap="round"/>')
        out.append(f'<path android:pathData="{head}" android:fillColor="{color}" android:strokeColor="{color}" android:strokeWidth="1.2" android:strokeLineJoin="round"/>')
    for x, y, w, h in bars():
        r = w / 2
        d = (f"M{x:.2f} {y + r:.2f}A{r} {r} 0 0 1 {x + w:.2f} {y + r:.2f}"
             f"L{x + w:.2f} {y + h - r:.2f}A{r} {r} 0 0 1 {x:.2f} {y + h - r:.2f}Z")
        out.append(f'<path android:pathData="{d}" android:fillColor="{color}"/>')
    body = "\n        ".join(out)
    return f'''<group android:scaleX="{scale}" android:scaleY="{scale}" android:translateX="{offset}" android:translateY="{offset}">
        {body}
    </group>'''


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def main():
    import cairosvg

    svg = full_svg()
    write(os.path.join(ROOT, "packaging/linux/mync.svg"), svg)
    cairosvg.svg2png(bytestring=svg.encode(), write_to=os.path.join(ROOT, "docs/logo.png"), output_width=512, output_height=512)

    # Android: adaptives Icon (Vordergrund im sicheren Bereich 66/108)
    write(os.path.join(RES, "drawable/ic_launcher_foreground.xml"), f'''<?xml version="1.0" encoding="utf-8"?>
<!-- erzeugt von tools/icon/make_icon.py -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    {vector_paths(COPPER_HI, 0.62, 54 - 31)}
</vector>
''')
    write(os.path.join(RES, "values/ic_launcher_background.xml"), f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#16171A</color>
</resources>
''')
    for name in ("ic_launcher", "ic_launcher_round"):
        write(os.path.join(RES, f"mipmap-anydpi-v26/{name}.xml"), '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
    <monochrome android:drawable="@drawable/ic_launcher_foreground"/>
</adaptive-icon>
''')
    # PNGs für ältere Android-Versionen
    for d, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        cairosvg.svg2png(bytestring=svg.encode(), write_to=os.path.join(RES, f"mipmap-{d}/ic_launcher.png"), output_width=px, output_height=px)
        cairosvg.svg2png(bytestring=svg.encode(), write_to=os.path.join(RES, f"mipmap-{d}/ic_launcher_round.png"), output_width=px, output_height=px)

    # Benachrichtigungssymbol: einfarbig weiß (Android färbt es selbst)
    write(os.path.join(RES, "drawable/ic_stat_mync.xml"), f'''<?xml version="1.0" encoding="utf-8"?>
<!-- erzeugt von tools/icon/make_icon.py -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
    {vector_paths("#FFFFFFFF", 0.24, 0)}
</vector>
''')
    print("Logo erzeugt.")


if __name__ == "__main__":
    main()
