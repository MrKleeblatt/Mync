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
}
