import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Ein Hörvorgang: ein Titel wurde (teilweise) gehört.
class PlayEvent {
  PlayEvent({
    required this.startMs,
    required this.path,
    required this.fileId,
    required this.listenedMs,
    required this.durationMs,
    this.byUser = false,
    this.completed = false,
  });

  /// Beginn (Unix-Zeit in ms).
  final int startMs;

  /// Pfad relativ zur Musikwurzel (kann sich durch Umbenennen ändern).
  String path;

  /// Stabile Datei-ID aus dem Manifest (bleibt bei Umbenennungen gleich).
  final String fileId;

  /// Tatsächlich gehörte Zeit (Spulen zählt nicht).
  final int listenedMs;
  final int durationMs;

  /// Vom Nutzer beendet (Weiter, anderer Titel …) statt automatisch.
  final bool byUser;

  /// Bis zum Ende gehört.
  final bool completed;

  DateTime get start => DateTime.fromMillisecondsSinceEpoch(startMs);

  /// Zählt als „gespielt“: bis zum Ende oder mind. 30 s bzw. die Hälfte.
  bool get counted {
    if (completed) return true;
    final need = durationMs > 0 ? min(30000, durationMs ~/ 2) : 30000;
    return listenedMs >= need;
  }

  /// Übersprungen: vom Nutzer beendet, bevor es als gespielt zählt.
  bool get skipped => byUser && !counted;

  Map<String, Object> toJson() => {
    't': startMs,
    'p': path,
    'id': fileId,
    'ms': listenedMs,
    'len': durationMs,
    if (byUser) 'u': 1,
    if (completed) 'c': 1,
  };

  factory PlayEvent.fromJson(Map<String, dynamic> j) => PlayEvent(
    startMs: j['t'] as int,
    path: j['p'] as String,
    fileId: j['id'] as String? ?? '',
    listenedMs: j['ms'] as int? ?? 0,
    durationMs: j['len'] as int? ?? 0,
    byUser: j['u'] == 1,
    completed: j['c'] == 1,
  );
}

/// Hörprotokoll als JSON-Lines-Datei (eine Zeile pro Hörvorgang, nur anhängen).
class ListeningHistory {
  ListeningHistory(this.file);

  final File file;
  final List<PlayEvent> events = [];

  Future<void> load() async {
    events.clear();
    if (!await file.exists()) return;
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        events.add(
          PlayEvent.fromJson(jsonDecode(line) as Map<String, dynamic>),
        );
      } catch (_) {
        // beschädigte Zeile (z. B. Absturz beim Schreiben) überspringen
      }
    }
  }

  Future<void> append(PlayEvent e) async {
    events.add(e);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode(e)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// Nach Umbenennungen: Pfade im Speicher nachziehen (die Datei behält die
  /// alten Pfade, die Zuordnung läuft ohnehin über die file_id).
  void renamePaths(Map<String, String> renames) {
    for (final e in events) {
      final n = renames[e.path];
      if (n != null) e.path = n;
    }
  }
}

/// Misst einen laufenden Hörvorgang anhand der Positionsmeldungen des Players.
class ListeningSession {
  ListeningSession({
    required this.path,
    required this.fileId,
    required this.durationMs,
  }) : startMs = DateTime.now().millisecondsSinceEpoch;

  final String path;
  final String fileId;
  int durationMs;
  final int startMs;
  int listenedMs = 0;
  Duration? _last;

  /// Neue Position; nur kleine Vorwärtsschritte zählen (Sprünge = Spulen).
  void onPosition(Duration pos, {required bool playing, double rate = 1}) {
    final last = _last;
    _last = pos;
    if (!playing || last == null) return;
    final delta = (pos - last).inMilliseconds;
    if (delta > 0 && delta <= 2000 * max(1, rate)) {
      listenedMs += (delta / max(0.25, rate)).round();
    }
  }

  /// Wiedergabe pausiert/fortgesetzt: nächste Meldung nicht als Schritt werten.
  void resetAnchor() => _last = null;

  PlayEvent finish({required bool byUser, bool completed = false}) => PlayEvent(
    startMs: startMs,
    path: path,
    fileId: fileId,
    listenedMs: listenedMs,
    durationMs: durationMs,
    byUser: byUser,
    completed: completed,
  );
}
