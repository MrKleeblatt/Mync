// Logbuch der App (wie bei Kassenbon): Meldungen, Fehler und Netzverkehr
// seit dem Start, zum Ansehen unter Einstellungen → Info und Updates →
// Logbuch. Nur im Speicher, die ältesten fallen heraus.
//
// Widgets zeigen nur einen kurzen Zustand (lädt / erfolgreich /
// fehlgeschlagen, siehe [OpStatus]); Details stehen ausschließlich hier.
import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

enum LogLevel { info, network, warning, error }

class LogEntry {
  LogEntry(this.time, this.level, this.message);
  final DateTime time;
  final LogLevel level;
  final String message;

  String get tag => switch (level) {
    LogLevel.info => 'INFO',
    LogLevel.network => 'NETZ',
    LogLevel.warning => 'WARN',
    LogLevel.error => 'FEHLER',
  };

  @override
  String toString() {
    String two(int n) => n.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.$ms '
        '$tag $message';
  }
}

class AppLog extends ChangeNotifier {
  AppLog({this.capacity = 2000});
  final int capacity;
  final _entries = ListQueue<LogEntry>();

  /// Älteste zuerst.
  List<LogEntry> get entries => List.unmodifiable(_entries);

  int get problems => _entries
      .where((e) => e.level == LogLevel.warning || e.level == LogLevel.error)
      .length;

  void add(LogLevel level, String message) {
    _entries.add(LogEntry(DateTime.now(), level, message));
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    // Einträge entstehen auch während des Bildaufbaus (z. B. Fehler beim
    // Zeichnen) – Benachrichtigung deshalb verzögert
    scheduleMicrotask(notifyListeners);
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// Alles als Text, z. B. zum Kopieren.
  String get text => _entries.join('\n');
}

/// Das Logbuch der App.
final appLog = AppLog();

void logInfo(String message) => appLog.add(LogLevel.info, message);
void logNetwork(String message) => appLog.add(LogLevel.network, message);
void logWarning(String message) => appLog.add(LogLevel.warning, message);
void logError(String message, [Object? error, StackTrace? stack]) => appLog.add(
  LogLevel.error,
  [
    message,
    ?error?.toString(),
    if (stack != null) '$stack'.trimRight(),
  ].join('\n'),
);

/// Leitet `debugPrint`, Flutter-Fehler und nicht abgefangene Fehler
/// zusätzlich ins Logbuch.
void captureLogs() {
  final print = debugPrint;
  debugPrint = (message, {wrapWidth}) {
    if (message != null) {
      logInfo(message.startsWith('mync: ') ? message.substring(6) : message);
    }
    print(message, wrapWidth: wrapWidth);
  };
  final onFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    logError(details.exceptionAsString(), null, details.stack);
    onFlutterError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logError('Nicht abgefangener Fehler', error, stack);
    return false; // weiter wie ohne Logbuch
  };
}

// ─── Kurzer Zustand für Widgets ──────────────────────────────────────────

enum OpKind { busy, ok, error }

/// Zustand einer Aktion für die Anzeige im Widget: nur ein kurzer Text,
/// die Details stehen im Logbuch.
class OpStatus {
  const OpStatus(this.kind, this.text);
  const OpStatus.busy(this.text) : kind = OpKind.busy;
  const OpStatus.ok(this.text) : kind = OpKind.ok;
  const OpStatus.error(this.text) : kind = OpKind.error;

  final OpKind kind;
  final String text;

  bool get busy => kind == OpKind.busy;
  bool get failed => kind == OpKind.error;
}

/// Führt [body] aus und meldet den Zustand über [report]: erst „busy“,
/// dann „ok“ oder „error“. Fehler landen mit Details im Logbuch; das Widget
/// bekommt nur [failText]. Liefert das Ergebnis oder null bei Fehler.
Future<T?> runStatus<T>(
  void Function(OpStatus) report,
  Future<T> Function() body, {
  required String busy,
  required String Function(T result) ok,
  required String failText,
  String? logWhat,
}) async {
  report(OpStatus.busy(busy));
  final what = logWhat ?? busy.replaceAll('…', '').trim();
  try {
    final r = await body();
    final msg = ok(r);
    logInfo('$what: $msg');
    report(OpStatus.ok(msg));
    return r;
  } catch (e, st) {
    logError('$what fehlgeschlagen', e, st);
    report(OpStatus.error(failText));
    return null;
  }
}
