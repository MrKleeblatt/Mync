import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/backup/backup.dart';
import 'package:mync/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('Sicherung und Wiederherstellung', () async {
    final tmp = await Directory.systemTemp.createTemp('mync_backup');
    addTearDown(() => tmp.delete(recursive: true));
    final data = '${tmp.path}/daten';
    Directory('$data/sync').createSync(recursive: true);
    File('$data/state.json').writeAsStringSync('{"queues":[1]}');
    File('$data/history.jsonl').writeAsStringSync('{"a":1}\n');
    File('$data/sync/identity.json').writeAsStringSync('{"id":"geheim"}');
    File('$data/sync/peers.json').writeAsStringSync('[]');
    File('$data/manifest.db').writeAsStringSync('nicht sichern');

    SharedPreferences.setMockInitialValues({});
    final s = await AppSettings.forTest(data, '${tmp.path}/cache');
    await s.setMusicDir('/musik');
    await s.setSpeed(1.0);
    await s.setCrossfadeSec(6);
    await s.setExcludes(['*.wav']);
    await s.setEqEnabled(true);

    final out = '${tmp.path}/x.${Backup.extension}';
    await Backup.create(s, out);
    final info = await Backup.inspect(out);
    expect(info.files, [
      'history.jsonl',
      'state.json',
      'sync/identity.json',
      'sync/peers.json',
    ]);
    expect(info.hasPairings, isTrue);

    // alles verändern, dann wiederherstellen
    File('$data/state.json').writeAsStringSync('{}');
    File('$data/sync/identity.json').deleteSync();
    await s.setMusicDir('/anders');
    await s.setCrossfadeSec(0);
    await s.setExcludes([]);
    await s.setPitch(3);
    await Backup.restore(s, out);
    expect(File('$data/state.json').readAsStringSync(), '{"queues":[1]}');
    expect(File('$data/sync/identity.json').existsSync(), isTrue);
    expect(s.musicDir, '/musik');
    expect(s.speed, 1.0);
    expect(s.crossfadeSec, 6);
    expect(s.excludes, ['*.wav']);
    expect(s.pitch, 0); // war in der Sicherung nicht gesetzt

    // ohne Kopplungen
    final out2 = '${tmp.path}/y.${Backup.extension}';
    await Backup.create(s, out2, pairings: false);
    expect((await Backup.inspect(out2)).hasPairings, isFalse);

    File('${tmp.path}/kaputt').writeAsStringSync('quatsch');
    await expectLater(
      Backup.inspect('${tmp.path}/kaputt'),
      throwsA(isA<FormatException>()),
    );
  });
}
