import 'dart:io';

import '../core/mync_core.dart';
import 'track.dart';

/// Ein Kapitel innerhalb eines Titels.
class Chapter {
  const Chapter(this.start, this.title, {this.end});
  final Duration start;
  final Duration? end;
  final String title;

  @override
  String toString() => '${formatDuration(start)} $title';
}

/// Woher die Kapitel stammen (für die Anzeige).
enum ChapterSource { tags, text }

class ChapterList {
  const ChapterList(this.chapters, this.source);
  final List<Chapter> chapters;
  final ChapterSource source;

  bool get isEmpty => chapters.isEmpty;
  int get length => chapters.length;

  /// Index des Kapitels an [pos] (-1 vor dem ersten).
  int indexAt(Duration pos) {
    var ans = -1;
    for (var i = 0; i < chapters.length; i++) {
      if (chapters[i].start <= pos) {
        ans = i;
      } else {
        break;
      }
    }
    return ans;
  }

  static const empty = ChapterList([], ChapterSource.tags);
}

// ─── Kapitel aus Text (wie in YouTube-Beschreibungen) ──────────────────────

final _ts = r'(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?:[.,](\d{1,3}))?';
final _bullet = r'^\s*(?:[-*•▶►·]|\d{1,3}[.)])?\s*';
// „0:00 Titel“, „[0:00] Titel“, „(0:00) - Titel“, „0:00 - 3:20 Titel“
final _leading = RegExp(
  '$_bullet[\\[(]?$_ts[\\])]?(?:\\s*[-–—]\\s*[\\[(]?$_ts[\\])]?)?\\s*[-–—:|.)]*\\s*(.*)\$',
);
// „Titel - 0:00“, „Titel (0:00)“
final _trailing = RegExp(
  '$_bullet(.*?)\\s*[-–—:|]*\\s*[\\[(]?$_ts[\\])]?\\s*\$',
);

Duration? _dur(String? h, String? m, String? s, String? frac) {
  if (m == null || s == null) return null;
  final sec = int.parse(s);
  final min = int.parse(m);
  if (sec >= 60 || (h != null && min >= 60)) return null;
  final ms = frac == null
      ? 0
      : int.parse(frac.padRight(3, '0').substring(0, 3));
  return Duration(
    hours: h == null ? 0 : int.parse(h),
    minutes: min,
    seconds: sec,
    milliseconds: ms,
  );
}

/// Erkennt Kapitel in freiem Text. Nötig sind mindestens zwei Zeilen mit
/// aufsteigenden Zeitstempeln; Zeilen mit nur Zeitangaben im Fließtext
/// (z. B. „um 12:30 Uhr“ mitten im Satz) werden nicht erkannt.
List<Chapter> parseTextChapters(String? text, {Duration? duration}) {
  if (text == null || text.trim().isEmpty) return const [];
  final out = <Chapter>[];
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.length > 200) continue;
    Duration? start;
    Duration? end;
    String title;
    final m = _leading.firstMatch(line);
    if (m != null) {
      start = _dur(m.group(1), m.group(2), m.group(3), m.group(4));
      end = _dur(m.group(5), m.group(6), m.group(7), m.group(8));
      title = m.group(9) ?? '';
    } else {
      final t = _trailing.firstMatch(line);
      if (t == null) continue;
      title = t.group(1) ?? '';
      start = _dur(t.group(2), t.group(3), t.group(4), t.group(5));
    }
    if (start == null) continue;
    title = title
        .trim()
        .replaceAll(RegExp(r'^[-–—:|.)\s]+|[-–—:|\s]+$'), '')
        .trim();
    if (out.isNotEmpty && start <= out.last.start) continue; // muss aufsteigen
    if (duration != null && duration > Duration.zero && start >= duration) {
      continue;
    }
    out.add(
      Chapter(
        start,
        title.isEmpty ? 'Kapitel ${out.length + 1}' : title,
        end: end,
      ),
    );
  }
  return out.length >= 2 ? out : const [];
}

/// Kapitel aus den Tags; sonst aus Beschreibung/Kommentar oder einer
/// Textdatei neben dem Titel (`<name>.description` von yt-dlp, `<name>.chapters.txt`).
Future<ChapterList> loadChapters(Track t, String absPath) async {
  FileTags? tags;
  try {
    tags = await readTags(absPath);
  } catch (_) {}
  if (tags != null && tags.chapters.length >= 2) {
    return ChapterList(tags.chapters, ChapterSource.tags);
  }
  final duration = t.duration;
  final texts = <String?>[
    tags?.fields['description']?.join('\n'),
    tags?.fields['comment']?.join('\n'),
  ];
  final base = absPath.contains('.')
      ? absPath.substring(0, absPath.lastIndexOf('.'))
      : absPath;
  for (final ext in ['.description', '.chapters.txt', '.txt']) {
    final f = File('$base$ext');
    try {
      if (await f.exists() && await f.length() < 512 * 1024) {
        texts.add(await f.readAsString());
      }
    } catch (_) {}
  }
  for (final text in texts) {
    final c = parseTextChapters(text, duration: duration);
    if (c.isNotEmpty) return ChapterList(c, ChapterSource.text);
  }
  return ChapterList.empty;
}
