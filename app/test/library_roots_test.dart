// Braucht den Zig-Kern (LD_LIBRARY_PATH=../core/zig-out/lib).
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/core/mync_core.dart';
import 'package:mync/library/library.dart';
import 'package:mync/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

bool _core() {
  try {
    DynamicLibrary.open('libmync_core.so');
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  test('Mehrere Musikordner und Ausschlüsse', () async {
    final tmp = await Directory.systemTemp.createTemp('mync_roots');
    addTearDown(() => tmp.delete(recursive: true));
    void put(String rel, String fixture) {
      final f = File('${tmp.path}/$rel')..parent.createSync(recursive: true);
      File('../core/testdata/$fixture').copySync(f.path);
    }

    put('Musik/Rock/a.mp3', 'mp3-tagged.mp3');
    put('Musik/Rock/b.wav', 'wav-plain.wav');
    put('Musik/Hörproben/c.flac', 'flac-plain.flac');
    put('Musik/Hörbücher/x.opus', 'opus-plain.opus'); // Namenskollision
    put('Platte2/Hörbücher/Buch/k1.opus', 'opus-chapters.opus');
    put('Platte2/Hörbücher/Buch/k2.m4a', 'm4a-plain.m4a');

    SharedPreferences.setMockInitialValues({});
    final s = await AppSettings.forTest(
      '${tmp.path}/daten',
      '${tmp.path}/cache',
    );
    await s.setMusicDir('${tmp.path}/Musik');
    await s.setExtraMusicDirs(['${tmp.path}/Platte2/Hörbücher']);
    await s.setExcludes(['*.wav', 'Hörproben']);
    final lib = Library(s);
    // Wie in der App hängt etwas Unübertragbares an der Bibliothek (dort der
    // Player); der Scan im Hintergrund-Isolate darf es nicht mitnehmen.
    final port = ReceivePort();
    addTearDown(port.close);
    lib.onRenamed = (_) => port.sendPort.send(1);
    await lib.load();
    await lib.refresh();

    expect(lib.tracks.map((t) => t.path), [
      'Hörbücher (2)/Buch/k1.opus',
      'Hörbücher (2)/Buch/k2.m4a',
      'Hörbücher/x.opus',
      'Rock/a.mp3',
    ]);
    expect(
      lib.abs('Hörbücher (2)/Buch/k1.opus'),
      '${tmp.path}/Platte2/Hörbücher/Buch/k1.opus',
    );
    expect(lib.abs('Rock/a.mp3'), '${tmp.path}/Musik/Rock/a.mp3');
    expect(lib.subfolders('').map((e) => e.$1), contains('Hörbücher (2)'));

    // Ausschluss aufheben → Dateien erscheinen
    await s.setExcludes([]);
    while (lib.scanning) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await lib.refresh();
    expect(lib.tracks.length, 6);
    // Audio-Hashes (für den Sync) entstehen im Hintergrund
    await lib.ensureHashed();
    expect(await pendingHashes(s.manifestDb), isEmpty);
    expect(lib.hashProgress, isNull);
    lib.dispose();
  }, skip: _core() ? false : 'libmync_core.so fehlt');
}
