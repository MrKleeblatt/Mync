// Logbuch der App (wie bei Kassenbon): Meldungen, Fehler und Netzverkehr
// seit dem Start, zum Ansehen unter Einstellungen → Info und Updates →
// Logbuch. Nur im Speicher, die ältesten fallen heraus. Zusätzlich steht
// alles auf der Konsole ([ConsoleLog]): Fehler auf stderr, der Rest auf
// stdout – unter systemd liest journalctl es mit.
//
// Widgets zeigen nur einen kurzen Zustand (lädt / erfolgreich /
// fehlgeschlagen, siehe [OpStatus]); Details stehen ausschließlich hier.
import 'dart:async';
import 'dart:collection';
import 'dart:io';

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

  /// Uhrzeit mit Millisekunden, z. B. `16:55:25.081`.
  String get clock {
    String two(int n) => n.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.$ms';
  }

  @override
  String toString() => '$clock $tag $message';
}

/// Schreibt Einträge auf die Konsole, eine Zeile je Eintrag:
///
///     16:55:25.081 INFO   Bibliothek geladen: 0 Titel
///     16:55:41.300 NETZ   GET https://api.github.com/… → 200, 19 kB in 341 ms
///     16:55:25.090 WARN   Musikordner nicht gefunden: /home/…/Music
///     16:57:02.512 FEHLER Update fehlgeschlagen
///                         │ SocketException: …
///
/// Folgezeilen (Fehlertext, Stacktrace) stehen eingerückt unter der Meldung.
/// Im Terminal farbig (außer mit `NO_COLOR`). Unter systemd (`JOURNAL_STREAM`)
/// ohne Uhrzeit – die setzt journald selbst – und mit Syslog-Priorität
/// vorn (`<3>` Fehler, `<4>` Warnung, `<6>` sonst), damit
/// `journalctl -p warning` nur die Probleme zeigt.
class ConsoleLog {
  ConsoleLog({
    void Function(String line)? out,
    void Function(String line)? err,
    bool? journal,
    bool? color,
  }) : _out = out ?? stdout.writeln,
       _err = err ?? stderr.writeln,
       journal = journal ?? Platform.environment.containsKey('JOURNAL_STREAM'),
       color =
           color ??
           (!Platform.environment.containsKey('NO_COLOR') &&
               stdout.hasTerminal &&
               stdout.supportsAnsiEscapes);

  final void Function(String) _out;
  final void Function(String) _err;
  final bool journal;
  final bool color;

  static const _reset = '\x1B[0m';
  static const _dim = '\x1B[2m';

  void write(LogEntry e) {
    final (prio, ansi) = switch (e.level) {
      LogLevel.info => (6, ''),
      LogLevel.network => (6, '\x1B[36m'), // cyan
      LogLevel.warning => (4, '\x1B[33m'), // gelb
      LogLevel.error => (3, '\x1B[1;31m'), // rot, fett
    };
    String paint(String s, String code) =>
        color && code.isNotEmpty ? '$code$s$_reset' : s;
    final head = journal ? '<$prio>' : '${paint(e.clock, _dim)} ';
    final tag = paint(e.tag.padRight(6), ansi);
    final lines = e.message.trimRight().split('\n');
    final indent = journal ? '       ' : '${' ' * 13}       ';
    final buf = StringBuffer('$head$tag ${lines.first}');
    for (final l in lines.skip(1)) {
      buf.write('\n${journal ? '<$prio>' : ''}$indent${paint('│', _dim)} $l');
    }
    (e.level == LogLevel.error ? _err : _out)(buf.toString());
  }
}

class AppLog extends ChangeNotifier {
  AppLog({this.capacity = 2000});
  final int capacity;
  final _entries = ListQueue<LogEntry>();

  /// Gibt jeden neuen Eintrag zusätzlich auf der Konsole aus (in
  /// [captureLogs] gesetzt).
  ConsoleLog? console;

  /// Älteste zuerst.
  List<LogEntry> get entries => List.unmodifiable(_entries);

  int get problems => _entries
      .where((e) => e.level == LogLevel.warning || e.level == LogLevel.error)
      .length;

  void add(LogLevel level, String message) {
    final e = LogEntry(DateTime.now(), level, message);
    _entries.add(e);
    console?.write(e);
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

/// Leitet `debugPrint`, Flutter-Fehler und nicht abgefangene Fehler ins
/// Logbuch und gibt das Logbuch auf der Konsole aus. Auf dem Desktop über
/// stdout/stderr, auf Android über `debugPrint` (landet in logcat).
void captureLogs() {
  final print = debugPrint;
  appLog.console = Platform.isAndroid || Platform.isIOS
      ? ConsoleLog(
          out: (l) => print(l, wrapWidth: null),
          err: (l) => print(l, wrapWidth: null),
          journal: false,
          color: false,
        )
      : ConsoleLog();
  // Ausgegeben wird über das Logbuch, sonst stünde alles doppelt da
  debugPrint = (message, {wrapWidth}) {
    if (message != null) {
      logInfo(message.startsWith('mync: ') ? message.substring(6) : message);
    }
  };
  // Nicht an Flutters eigene Ausgabe weiterreichen: die ginge über
  // debugPrint und stünde als zweiter (Info-)Eintrag im Logbuch
  FlutterError.onError = (details) {
    logError(details.exceptionAsString(), null, details.stack);
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
