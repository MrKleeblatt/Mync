import 'history.dart';

enum StatsRange {
  thisMonth('Dieser Monat'),
  lastMonth('Letzter Monat'),
  thisYear('Dieses Jahr'),
  all('Gesamt');

  const StatsRange(this.label);
  final String label;

  /// Zeitraum [von, bis) für [now].
  (DateTime, DateTime) bounds(DateTime now) => switch (this) {
    StatsRange.thisMonth => (
      DateTime(now.year, now.month),
      DateTime(now.year, now.month + 1),
    ),
    StatsRange.lastMonth => (
      DateTime(now.year, now.month - 1),
      DateTime(now.year, now.month),
    ),
    StatsRange.thisYear => (DateTime(now.year), DateTime(now.year + 1)),
    StatsRange.all => (DateTime(1970), DateTime(9999)),
  };
}

/// Statistik eines Titels in einem Zeitraum.
class TrackStat {
  TrackStat(this.fileId, this.path);
  final String fileId;
  String path;
  int plays = 0;
  int skips = 0;
  int listenedMs = 0;
  int lastMs = 0;
}

class FolderStat {
  FolderStat(this.folder);
  final String folder;
  int plays = 0;
  int listenedMs = 0;
}

class StatsSummary {
  StatsSummary(this.range);
  final StatsRange range;
  int listenedMs = 0;
  int plays = 0;
  int skips = 0;
  final Set<String> _tracks = {};
  final Set<int> _days = {};
  List<TrackStat> top = const [];
  List<FolderStat> topFolders = const [];

  /// Hörzeit (ms) je Stunde 0–23 und je Wochentag (0 = Montag).
  final List<int> byHour = List.filled(24, 0);
  final List<int> byWeekday = List.filled(7, 0);

  int get distinctTracks => _tracks.length;
  int get activeDays => _days.length;
}

String _folderOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

/// Schlüssel eines Titels: file_id, sonst Pfad (ältere Einträge).
String trackKey(PlayEvent e) => e.fileId.isNotEmpty ? e.fileId : e.path;

/// Wertet das Hörprotokoll für einen Zeitraum aus.
StatsSummary summarize(
  Iterable<PlayEvent> events,
  StatsRange range, {
  DateTime? now,
  int topCount = 50,
}) {
  final (from, to) = range.bounds(now ?? DateTime.now());
  final s = StatsSummary(range);
  final tracks = <String, TrackStat>{};
  final folders = <String, FolderStat>{};
  for (final e in events) {
    final t = e.start;
    if (t.isBefore(from) || !t.isBefore(to)) continue;
    s.listenedMs += e.listenedMs;
    s.byHour[t.hour] += e.listenedMs;
    s.byWeekday[t.weekday - 1] += e.listenedMs;
    if (e.listenedMs > 0) s._days.add(t.year * 1000 + t.month * 40 + t.day);
    final ts = tracks.putIfAbsent(
      trackKey(e),
      () => TrackStat(e.fileId, e.path),
    );
    ts.path = e.path; // neuester Pfad
    ts.listenedMs += e.listenedMs;
    if (e.startMs > ts.lastMs) ts.lastMs = e.startMs;
    final fs = folders.putIfAbsent(
      _folderOf(e.path),
      () => FolderStat(_folderOf(e.path)),
    );
    fs.listenedMs += e.listenedMs;
    if (e.counted) {
      s.plays++;
      ts.plays++;
      fs.plays++;
      s._tracks.add(trackKey(e));
    } else if (e.skipped) {
      s.skips++;
      ts.skips++;
    }
  }
  s.top =
      (tracks.values.where((t) => t.plays > 0).toList()..sort((a, b) {
            final c = b.plays.compareTo(a.plays);
            return c != 0 ? c : b.listenedMs.compareTo(a.listenedMs);
          }))
          .take(topCount)
          .toList();
  s.topFolders =
      (folders.values.where((f) => f.listenedMs > 0).toList()
            ..sort((a, b) => b.listenedMs.compareTo(a.listenedMs)))
          .take(10)
          .toList();
  return s;
}

/// Gesamtzahl gespielter Wiedergaben und letzte Wiedergabe eines Titels.
(int plays, int? lastMs) playsOf(
  Iterable<PlayEvent> events,
  String fileId,
  String path,
) {
  var plays = 0;
  int? last;
  for (final e in events) {
    if (!(e.fileId.isNotEmpty ? e.fileId == fileId : e.path == path)) continue;
    if (e.counted) plays++;
    if (e.listenedMs > 0 && (last == null || e.startMs > last)) {
      last = e.startMs;
    }
  }
  return (plays, last);
}

/// „1 h 23 min“, „12 min“, „45 s“
String formatListening(int ms) {
  final m = ms ~/ 60000;
  if (m >= 60) return '${m ~/ 60} h ${m % 60} min';
  if (m >= 1) return '$m min';
  return '${ms ~/ 1000} s';
}
