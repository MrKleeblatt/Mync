import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/core/music_fs.dart';

void main() {
  const tree =
      'content://com.android.externalstorage.documents/tree/primary%3AMusic';

  test('Orte in einer Ordnerfreigabe zerlegen', () {
    expect(MusicFs.isTree('$tree/A/x.mp3'), isTrue);
    expect(MusicFs.isTree('/home/u/Musik/x.mp3'), isFalse);
    expect(MusicFs.split('$tree/A/b c/x.mp3'), (tree, 'A/b c/x.mp3'));
    expect(MusicFs.split(tree), (tree, ''));
    expect(MusicFs.split('$tree/'), (tree, ''));
    expect(MusicFs.parent('$tree/A/x.mp3'), '$tree/A');
    expect(MusicFs.parent('$tree/x.mp3'), tree);
    expect(MusicFs.parent(tree), tree);
  });

  test('Lesbare Namen und Abspiel-URIs', () {
    expect(MusicFs.describe(tree), 'Interner Speicher/Music');
    expect(
      MusicFs.describe(
        'content://com.android.externalstorage.documents/tree/1A2B-3C4D%3AH%C3%B6rb%C3%BCcher',
      ),
      'SD-Karte/Hörbücher',
    );
    expect(MusicFs.describe('/home/u/Musik'), '/home/u/Musik');
    expect(
      MusicFs.mediaUri('$tree/A/x y.mp3'),
      '$tree/document/primary%3AMusic%2FA%2Fx%20y.mp3',
    );
    // Wurzel eines Speichers („primary:“)
    expect(
      MusicFs.mediaUri(
        'content://com.android.externalstorage.documents/tree/primary%3A/x.mp3',
      ),
      'content://com.android.externalstorage.documents/tree/primary%3A/document/primary%3Ax.mp3',
    );
    expect(MusicFs.mediaUri('/m/x y.mp3'), 'file:///m/x%20y.mp3');
  });

  test('Lokale Dateien: schreiben, umbenennen, auflisten, löschen', () async {
    final dir = await Directory.systemTemp.createTemp('mync-fs');
    addTearDown(() => dir.delete(recursive: true));
    final a = '${dir.path}/A/x.lrc';
    await MusicFs.writeString(a, 'hallo');
    expect(await MusicFs.exists(a), isTrue);
    expect(await MusicFs.readString(a), 'hallo');
    expect(await MusicFs.tryReadString('${dir.path}/fehlt.lrc'), isNull);
    await MusicFs.rename(a, '${dir.path}/B/y.lrc');
    expect(await MusicFs.exists(a), isFalse);
    final names = [for (final c in await MusicFs.list('${dir.path}/B')) c.name];
    expect(names, ['y.lrc']);
    await MusicFs.writeString('${dir.path}/C/z.lrc', '');
    await expectLater(
      MusicFs.rename('${dir.path}/B/y.lrc', '${dir.path}/C/z.lrc'),
      throwsA(isA<FileSystemException>()),
    );
    await MusicFs.delete('${dir.path}/B/y.lrc');
    await MusicFs.delete('${dir.path}/B');
    expect(await MusicFs.isDir('${dir.path}/B'), isFalse);
    final r = await MusicFs.withWritePath(
      '${dir.path}/C/z.lrc',
      (p) async => p,
    );
    expect(r, '${dir.path}/C/z.lrc'); // lokal: kein Umweg über eine Kopie
  });
}
