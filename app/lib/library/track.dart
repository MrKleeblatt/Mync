import '../core/mync_core.dart';

/// Ein Titel der Bibliothek mit bequemen Zugriffen auf die Tags.
class Track {
  Track(this.info);

  final TrackInfo info;

  String get path => info.path;
  String get fileId => info.fileId;
  TagFields get fields => info.fields;

  String? _first(String k) {
    final v = info.fields[k];
    return (v == null || v.isEmpty) ? null : v.first;
  }

  String get fileName => path.split('/').last;
  String get baseName {
    final n = fileName;
    final dot = n.lastIndexOf('.');
    return dot > 0 ? n.substring(0, dot) : n;
  }

  /// Ordner relativ zur Musikwurzel ('' = Wurzel).
  String get folder {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  String get extension {
    final dot = fileName.lastIndexOf('.');
    return dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  }

  String get title => _first('title') ?? baseName;
  bool get hasTitle => _first('title') != null;

  /// Alle Künstler (Mehrfachwerte und „;“-getrennte Werte aufgeteilt).
  List<String> get artists => _split(info.fields['artist']);
  String get artist =>
      artists.isEmpty ? 'Unbekannter Künstler' : artists.join(', ');

  String? get album => _first('album');
  String get albumOrUnknown => album ?? 'Unbekanntes Album';

  /// Album-Künstler, sonst der erste Künstler.
  String get albumArtist {
    final aa = _split(info.fields['albumartist']);
    if (aa.isNotEmpty) return aa.join(', ');
    return artists.isEmpty ? 'Unbekannter Künstler' : artists.first;
  }

  List<String> get genres => _split(info.fields['genre']);
  List<String> get composers => _split(info.fields['composer']);
  String? get date => _first('date');
  int? get year {
    final d = date;
    if (d == null || d.length < 4) return null;
    return int.tryParse(d.substring(0, 4));
  }

  int? get trackNo => int.tryParse(_first('track') ?? '');
  int? get discNo => int.tryParse(_first('disc') ?? '');
  Duration get duration =>
      Duration(milliseconds: info.durationMs < 0 ? 0 : info.durationMs);
  DateTime get added => DateTime.fromMillisecondsSinceEpoch(info.addedMs);

  /// Schlüssel, der ein Album eindeutig macht (gleicher Name, anderer Künstler = anderes Album).
  String get albumKey =>
      '${albumArtist.toLowerCase()}\u0000${albumOrUnknown.toLowerCase()}';

  /// Text für die Suche (klein geschrieben).
  late final String searchText = [
    title,
    ...artists,
    album ?? '',
    albumArtist,
    ...genres,
    ...composers,
    path,
  ].join('\n').toLowerCase();

  static List<String> _split(List<String>? values) {
    if (values == null) return const [];
    final out = <String>[];
    for (final v in values) {
      for (final p in v.split(';')) {
        final t = p.trim();
        if (t.isNotEmpty && !out.contains(t)) out.add(t);
      }
    }
    return out;
  }
}

/// „3:07“ bzw. „1:02:03“
String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// Sortiert Titel eines Albums: Disc, Track, Dateiname.
int compareAlbumOrder(Track a, Track b) {
  final d = (a.discNo ?? 1).compareTo(b.discNo ?? 1);
  if (d != 0) return d;
  final t = (a.trackNo ?? 1 << 20).compareTo(b.trackNo ?? 1 << 20);
  if (t != 0) return t;
  return a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());
}

int compareText(String a, String b) =>
    a.toLowerCase().compareTo(b.toLowerCase());
