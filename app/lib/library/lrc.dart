/// Lyrics: unsynchronisiert oder synchronisiert im LRC-Format.
///
/// LRC-Zeilen: `[mm:ss.xx]Text`, mehrere Zeitstempel pro Zeile möglich,
/// `[offset:+/-ms]` verschiebt alle Zeiten.
class Lyrics {
  Lyrics._(this.lines, this.plain);

  /// Synchronisierte Zeilen (sortiert), leer bei unsynchronisierten Lyrics.
  final List<LyricLine> lines;

  /// Unsynchronisierter Text (null bei synchronisierten Lyrics).
  final String? plain;

  bool get synced => lines.isNotEmpty;

  static final _time = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  static final _offset = RegExp(
    r'^\[offset:\s*([+-]?\d+)\]',
    caseSensitive: false,
  );
  static final _meta = RegExp(r'^\[[a-z]+:.*\]$', caseSensitive: false);

  static Lyrics? parse(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    var offset = 0;
    final lines = <LyricLine>[];
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      final off = _offset.firstMatch(line);
      if (off != null) {
        offset = int.parse(off.group(1)!);
        continue;
      }
      final stamps = <Duration>[];
      var rest = line;
      while (true) {
        final m = _time.matchAsPrefix(rest);
        if (m == null) break;
        final frac = m.group(3) ?? '0';
        final ms = int.parse(frac.padRight(3, '0').substring(0, 3));
        stamps.add(
          Duration(
            minutes: int.parse(m.group(1)!),
            seconds: int.parse(m.group(2)!),
            milliseconds: ms,
          ),
        );
        rest = rest.substring(m.end);
      }
      if (stamps.isEmpty) {
        if (_meta.hasMatch(line)) continue; // [ar:…], [ti:…]
        continue;
      }
      for (final s in stamps) {
        lines.add(LyricLine(s, rest.trim()));
      }
    }
    if (lines.isEmpty) return Lyrics._(const [], text.trim());
    // Positiver Offset = Lyrics früher anzeigen
    final shifted = [
      for (final l in lines)
        LyricLine(
          Duration(
            milliseconds: (l.time.inMilliseconds - offset).clamp(0, 1 << 31),
          ),
          l.text,
        ),
    ]..sort((a, b) => a.time.compareTo(b.time));
    return Lyrics._(shifted, null);
  }

  /// Index der aktuellen Zeile zur Position [pos], -1 vor der ersten Zeile.
  int indexAt(Duration pos) {
    var lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time <= pos) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }
}

class LyricLine {
  const LyricLine(this.time, this.text);
  final Duration time;
  final String text;
}
