import 'package:flutter_test/flutter_test.dart';
import 'package:mync/log.dart';

void main() {
  test('Logbuch: Kapazität, Probleme, Text', () {
    final log = AppLog(capacity: 3);
    log.add(LogLevel.info, 'a');
    log.add(LogLevel.error, 'b');
    log.add(LogLevel.network, 'c');
    log.add(LogLevel.warning, 'd');
    expect(log.entries.map((e) => e.message), ['b', 'c', 'd']);
    expect(log.problems, 2);
    expect(log.text, contains('FEHLER b'));
    log.clear();
    expect(log.entries, isEmpty);
  });

  test('runStatus: kurzer Zustand im Widget, Details im Logbuch', () async {
    appLog.clear();
    final seen = <OpStatus>[];
    final r = await runStatus<int>(
      seen.add,
      () async => 3,
      busy: 'Lade …',
      ok: (n) => '$n geladen',
      failText: 'Laden fehlgeschlagen',
    );
    expect(r, 3);
    expect(seen.map((s) => s.kind), [OpKind.busy, OpKind.ok]);
    expect(seen.last.text, '3 geladen');

    seen.clear();
    final f = await runStatus<int>(
      seen.add,
      () async => throw StateError('kaputt im Detail'),
      busy: 'Lade …',
      ok: (n) => '$n',
      failText: 'Laden fehlgeschlagen',
    );
    expect(f, isNull);
    expect(seen.last.failed, isTrue);
    expect(seen.last.text, isNot(contains('kaputt')));
    expect(appLog.text, contains('kaputt im Detail'));
  });

  group('Konsole', () {
    LogEntry entry(LogLevel l, String m) =>
        LogEntry(DateTime(2026, 11, 25, 16, 55, 25, 81), l, m);

    test(
      'Terminal: Uhrzeit, Art, Folgezeilen eingerückt; Fehler auf stderr',
      () {
        final out = <String>[], err = <String>[];
        final c = ConsoleLog(
          out: out.add,
          err: err.add,
          journal: false,
          color: false,
        );
        c.write(entry(LogLevel.info, 'Bibliothek geladen: 0 Titel'));
        c.write(entry(LogLevel.warning, 'Musikordner fehlt'));
        c.write(
          entry(LogLevel.error, 'Update fehlgeschlagen\nSocketException'),
        );
        expect(out, [
          '16:55:25.081 INFO   Bibliothek geladen: 0 Titel',
          '16:55:25.081 WARN   Musikordner fehlt',
        ]);
        expect(err, [
          '16:55:25.081 FEHLER Update fehlgeschlagen\n'
              '                    │ SocketException',
        ]);
      },
    );

    test('journald: Priorität je Zeile, ohne Uhrzeit', () {
      final out = <String>[], err = <String>[];
      final c = ConsoleLog(out: out.add, err: err.add, journal: true);
      c.write(entry(LogLevel.network, 'GET x → 200'));
      c.write(entry(LogLevel.warning, 'w'));
      c.write(entry(LogLevel.error, 'kaputt\n#0 main'));
      expect(out, ['<6>NETZ   GET x → 200', '<4>WARN   w']);
      expect(err, ['<3>FEHLER kaputt\n<3>       │ #0 main']);
    });

    test('Logbuch gibt jeden Eintrag aus', () {
      final out = <String>[];
      final log = AppLog()
        ..console = ConsoleLog(out: out.add, err: out.add, journal: true);
      log.add(LogLevel.info, 'a');
      expect(out, ['<6>INFO   a']);
    });
  });
}
