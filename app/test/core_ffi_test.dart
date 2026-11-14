// Ruft den Zig-Kern über dart:ffi auf. Vorher bauen:
//   (cd ../core && zig build)
// und mit LD_LIBRARY_PATH=../core/zig-out/lib flutter test ausführen.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/core/mync_core.dart';

bool _coreAvailable() {
  try {
    DynamicLibrary.open('libmync_core.so');
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  final skip = _coreAvailable()
      ? false
      : 'libmync_core.so nicht gefunden (LD_LIBRARY_PATH=../core/zig-out/lib)';

  test('Scan und Titelliste über FFI', () async {
    final tmp = await Directory.systemTemp.createTemp('mync_ffi');
    addTearDown(() => tmp.delete(recursive: true));
    final lib = Directory('${tmp.path}/Musik/Björk/Post')..createSync(recursive: true);
    File('../core/testdata/mp3-tagged.mp3').copySync('${lib.path}/02 - Hyperballad.mp3');
    File('../core/testdata/flac-plain.flac').copySync('${lib.path}/ohne-tags.flac');
    final root = '${tmp.path}/Musik';
    final db = '${tmp.path}/daten/manifest.db';

    final r = await scanLibrary(root: root, db: db);
    expect(r.total, 2);
    expect(r.added, 2);
    expect(r.errors, isEmpty);

    final tracks = await listTracks(root: root, db: db);
    expect(tracks.map((t) => t.path), [
      'Björk/Post/02 - Hyperballad.mp3',
      'Björk/Post/ohne-tags.flac',
    ]);
    expect(tracks.first.title, 'Hyperballad');
    expect(tracks.first.artist, 'Björk');
    expect(tracks.first.track, '2');
    expect(tracks.last.title, isNull);

    final again = await scanLibrary(root: root, db: db);
    expect(again.hashed, 0);
  }, skip: skip);

  test('Fehler werden als Exception gemeldet', () async {
    expect(
      () => scanLibrary(root: '/gibt/es/nicht', db: '${Directory.systemTemp.path}/x/m.db'),
      throwsA(isA<MyncCoreException>()),
    );
  }, skip: skip);
}
