import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/library/lrc.dart';
import 'package:mync/player/player_controller.dart';
import 'package:mync/player/queue.dart';
import 'package:mync/update/update_service.dart';

PlayQueue q(List<String> items, {int index = 0}) =>
    PlayQueue(id: 'q', name: 'Q', items: [...items], index: index);

void main() {
  group('PlayQueue', () {
    test('playNext fügt nach dem aktuellen Titel ein', () {
      final x = q(['a', 'b', 'c'], index: 1)..playNext(['x', 'y']);
      expect(x.items, ['a', 'b', 'x', 'y', 'c']);
      expect(x.current, 'b');
    });

    test('removeAt hält den aktuellen Titel', () {
      final x = q(['a', 'b', 'c', 'd'], index: 2)..removeAt(0);
      expect(x.current, 'c');
      x.removeAt(1); // aktueller entfernt → nächster rückt nach
      expect(x.items, ['b', 'd']);
      expect(x.current, 'd');
      x.removeAt(1); // letzter entfernt
      expect(x.current, 'b');
    });

    test('move verschiebt und verfolgt den aktuellen Index', () {
      final x = q(['a', 'b', 'c', 'd'], index: 1)..move(1, 3);
      expect(x.items, ['a', 'c', 'd', 'b']);
      expect(x.index, 3);
      x.move(0, 3); // a hinter b → b rückt nach vorn
      expect(x.items, ['c', 'd', 'b', 'a']);
      expect(x.current, 'b');
      x.move(3, 0);
      expect(x.items, ['a', 'c', 'd', 'b']);
      expect(x.current, 'b');
    });

    test('shuffle setzt den aktuellen Titel an den Anfang', () {
      final x = q(List.generate(20, (i) => '$i'), index: 7)..shuffle(Random(1));
      expect(x.index, 0);
      expect(x.current, '7');
      expect(x.items.toSet().length, 20);
    });

    test('nextIndex beachtet den Wiederholmodus', () {
      final x = q(['a', 'b'], index: 1);
      x.repeat = QueueRepeat.off;
      expect(x.nextIndex(), isNull);
      x.repeat = QueueRepeat.all;
      expect(x.nextIndex(), 0);
      x.repeat = QueueRepeat.one;
      expect(x.nextIndex(), 1);
      expect(x.nextIndex(manual: true), 0);
    });

    test('JSON-Rundreise', () {
      final x = q(['a', 'b'], index: 1)
        ..positionMs = 1234
        ..repeat = QueueRepeat.one;
      final y = PlayQueue.fromJson(x.toJson());
      expect(y.items, ['a', 'b']);
      expect(y.index, 1);
      expect(y.positionMs, 1234);
      expect(y.repeat, QueueRepeat.one);
    });

    test('renamePath', () {
      final x = q(['a', 'b', 'a']);
      expect(x.renamePath('a', 'neu/a'), isTrue);
      expect(x.items, ['neu/a', 'b', 'neu/a']);
    });
  });

  group('Lyrics', () {
    test('LRC mit mehreren Zeitstempeln und Offset', () {
      final l = Lyrics.parse(
        '[ar:Björk]\n[offset:+500]\n[00:01.00][00:05.50]Refrain\n[00:03.2]Strophe\n',
      )!;
      expect(l.synced, isTrue);
      expect(l.lines.map((e) => e.text), ['Refrain', 'Strophe', 'Refrain']);
      expect(l.lines[0].time, const Duration(milliseconds: 500));
      expect(l.lines[1].time, const Duration(milliseconds: 2700));
      expect(l.indexAt(Duration.zero), -1);
      expect(l.indexAt(const Duration(seconds: 3)), 1);
      expect(l.indexAt(const Duration(seconds: 60)), 2);
    });

    test('unsynchronisierter Text', () {
      final l = Lyrics.parse('Zeile 1\nZeile 2')!;
      expect(l.synced, isFalse);
      expect(l.plain, 'Zeile 1\nZeile 2');
      expect(Lyrics.parse('  '), isNull);
    });
  });

  test('Versionsvergleich für Updates', () {
    expect(compareVersions('0.4.1', '0.4.0'), greaterThan(0));
    expect(compareVersions('0.10.0', '0.9.9'), greaterThan(0));
    expect(compareVersions('1.0.0', '1.0.0+7'), 0);
    expect(compareVersions('0.4', '0.4.0'), 0);
    expect(compareVersions('0.3.9', '0.4.0'), lessThan(0));
  });

  test('Auswahl „Als Nächstes“: hinter den laufenden, Reihenfolge bleibt', () {
    List<String> apply(List<String> items, int current, List<int> sel) {
      final q = PlayQueue(id: 't', name: 't')
        ..items.addAll(items)
        ..index = current;
      for (final (from, to) in PlayerController.planMoveAfter(
        items.length,
        current,
        sel,
      )) {
        q.move(from, to);
      }
      expect(q.items[q.index], items[current]); // läuft weiter
      return q.items;
    }

    final x = ['a', 'b', 'c', 'd', 'e', 'f'];
    expect(apply(x, 1, [4, 5]), ['a', 'b', 'e', 'f', 'c', 'd']);
    expect(apply(x, 3, [0, 5]), ['b', 'c', 'd', 'a', 'f', 'e']);
    expect(apply(x, 2, [0, 2, 4]), ['b', 'c', 'a', 'e', 'd', 'f']);
    // doppelte Pfade
    expect(apply(['a', 'x', 'b', 'x'], 0, [3]), ['a', 'x', 'x', 'b']);
  });
}
