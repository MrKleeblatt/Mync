import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Speichert den Zustand (Warteschlangen, Statistik) als JSON-Datei.
/// Schreibvorgänge werden gebündelt und atomar (temporäre Datei + rename)
/// ausgeführt.
class StateStore {
  StateStore(this.path);

  final String path;
  Timer? _timer;
  Map<String, Object?> Function()? _snapshot;

  Future<Map<String, dynamic>> load() async {
    try {
      final f = File(path);
      if (!await f.exists()) return {};
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Speichert in spätestens [delay] (mehrere Aufrufe werden zusammengefasst).
  void scheduleSave(
    Map<String, Object?> Function() snapshot, {
    Duration delay = const Duration(seconds: 2),
  }) {
    _snapshot = snapshot;
    _timer ??= Timer(delay, () {
      _timer = null;
      unawaited(saveNow());
    });
  }

  /// Schreibt sofort. Gleichzeitige Aufrufe (Timer, App in den Hintergrund,
  /// Beenden) laufen nacheinander – sonst benennt einer die temporäre Datei
  /// um, während der andere sie noch schreibt oder selbst umbenennen will.
  Future<void> saveNow() =>
      _last = _last.then((_) => _write(), onError: (_) => _write());
  Future<void> _last = Future.value();

  Future<void> _write() async {
    _timer?.cancel();
    _timer = null;
    final snap = _snapshot;
    if (snap == null) return;
    final f = File(path);
    await f.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(snap()), flush: true);
    await tmp.rename(path);
  }
}
