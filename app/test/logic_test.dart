import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/library/lrc.dart';
import 'package:mync/library/playlists.dart';
import 'package:mync/player/queue.dart';

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

  group('Playlists', () {
    test('Pfade relativ zur Wurzel, Rundreise über Datei', () async {
      final tmp = await Directory.systemTemp.createTemp('mync_pl');
      addTearDown(() => tmp.delete(recursive: true));
      final root = tmp.path;
      Directory('$root/Björk/Post').createSync(recursive: true);
      File('$root/Björk/Post/a.mp3').writeAsStringSync('');
      final store = PlaylistStore(root);
      await store.write('Test', ['Björk/Post/a.mp3', 'X/b.flac']);
      expect(
        File('$root/Playlists/Test.m3u8').readAsStringSync(),
        '#EXTM3U\n../Björk/Post/a.mp3\n../X/b.flac\n',
      );
      expect(await store.read('Test'), ['Björk/Post/a.mp3', 'X/b.flac']);
      await store.add('Test', ['X/b.flac', 'c.ogg']);
      expect(await store.read('Test'), [
        'Björk/Post/a.mp3',
        'X/b.flac',
        'c.ogg',
      ]);
      await store.rename('Test', 'Neu');
      expect(await store.names(), ['Neu']);
    });

    test('fremde Playlists: absolut, Backslashes, relativ zur Wurzel', () {
      final out = PlaylistStore.parse(
        '#EXTM3U\n#EXTINF:123,Titel\n/musik/A/x.mp3\n..\\B\\y.mp3\nC/z.mp3\n/anderswo/q.mp3\n',
        playlistDir: '/musik/Playlists',
        root: '/musik',
      );
      expect(out, ['A/x.mp3', 'B/y.mp3', 'C/z.mp3']);
    });
  });
}
