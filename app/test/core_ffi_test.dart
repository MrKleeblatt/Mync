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
    final lib = Directory('${tmp.path}/Musik/Björk/Post')
      ..createSync(recursive: true);
    File('../core/testdata/mp3-tagged.mp3')
        .copySync('${lib.path}/02 - Hyperballad.mp3');
    File('../core/testdata/flac-plain.flac')
        .copySync('${lib.path}/ohne-tags.flac');
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
    expect(tracks.first.fields['title'], ['Hyperballad']);
    expect(tracks.first.fields['artist'], ['Björk']);
    expect(tracks.first.fields['track'], ['2']);
    expect(tracks.first.hasLyrics, isTrue);
    expect(tracks.first.fields.containsKey('lyrics'), isFalse);
    expect(tracks.first.durationMs, inInclusiveRange(450, 600));
    expect(tracks.last.fields['title'], isNull);

    // Tags lesen, schreiben und Cover extrahieren
    final abs = '$root/${tracks.first.path}';
    final tags = await readTags(abs);
    expect(tags.writable, isTrue);
    expect(tags.pictures, 1);
    expect(tags.fields['lyrics'], ['We live on a mountain']);
    final written = await writeTags(abs, {
      ...tags.fields,
      'title': ['Neu'],
      'genre': [],
    });
    expect(written.fields['title'], ['Neu']);
    expect(written.fields.containsKey('genre'), isFalse);
    expect(written.pictures, 1);
    expect(await extractCover(abs, '${tmp.path}/cover.img'), isTrue);
    expect(File('${tmp.path}/cover.img').lengthSync(), greaterThan(0));
    // Cover entfernen und als Datei wieder setzen
    final noCover = await writeTags(abs, written.fields, removeCover: true);
    expect(noCover.pictures, 0);
    final withCover = await writeTags(
      abs,
      written.fields,
      coverFile: '${tmp.path}/cover.img',
    );
    expect(withCover.pictures, 1);
    expect(withCover.fields['title'], ['Neu']);
    File('${tmp.path}/kein-bild.txt').writeAsStringSync('kein Bild');
    await expectLater(
      writeTags(abs, {}, coverFile: '${tmp.path}/kein-bild.txt'),
      throwsA(
        isA<MyncCoreException>().having(
          (e) => e.userMessage,
          'userMessage',
          contains('JPEG'),
        ),
      ),
    );

    // Nur die geänderte Datei wird neu eingelesen, die Umbenennung bleibt erkannt
    final again = await scanLibrary(root: root, db: db);
    expect(again.hashed, 1);
    expect(again.added, 0);
    expect((await scanLibrary(root: root, db: db)).hashed, 0);
  }, skip: skip);

  test('Fehler werden als Exception gemeldet', () async {
    expect(
      () => scanLibrary(
        root: '/gibt/es/nicht',
        db: '${Directory.systemTemp.path}/x/m.db',
      ),
      throwsA(isA<MyncCoreException>()),
    );
  }, skip: skip);
}
