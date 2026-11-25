// Ende-zu-Ende-Test des Syncs: zwei Geräte (PC und Handy) im selben Prozess,
// verbunden über 127.0.0.1. Benötigt den gebauten Kern:
//   LD_LIBRARY_PATH=../core/zig-out/lib flutter test test/sync_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/core/mync_core.dart';
import 'package:mync/sync/mdns.dart';
import 'package:mync/sync/sync_service.dart';
import 'package:mync/sync/sync_session.dart';

class TestHost implements SyncHost {
  TestHost(this.root, this.db);
  @override
  final String root;
  @override
  final String db;
  final applied = <String>[];
  @override
  Future<void> rescan() async {
    await scanLibrary(root: root, db: db);
    await hashAllPending(root: root, db: db);
  }

  @override
  Future<void> afterApply(List<String> changedPaths) async =>
      applied.addAll(changedPaths);
}

const fixtures = '../core/testdata';

Future<void> waitFor(bool Function() cond, {String what = ''}) async {
  for (var i = 0; i < 300; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('Zeitüberschreitung: $what');
}

void copy(String fixture, String root, String rel) {
  final dst = File('$root/$rel');
  dst.parent.createSync(recursive: true);
  File('$fixtures/$fixture').copySync(dst.path);
}

String sha(String path) =>
    sha256Bytes(File(path).readAsBytesSync())
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

void main() {
  late Directory tmp;
  late SyncService pc, phone;
  late TestHost pcHost, phoneHost;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mync_sync');
    pcHost = TestHost(
      '${tmp.path}/pc/Musik',
      '${tmp.path}/pc/data/manifest.db',
    );
    phoneHost = TestHost(
      '${tmp.path}/handy/Musik',
      '${tmp.path}/handy/data/manifest.db',
    );
    for (final r in [pcHost.root, phoneHost.root]) {
      copy('mp3-tagged.mp3', r, 'Lumen/a.mp3');
      copy('flac-tagged.flac', r, 'Lumen/b.flac');
      copy('mp3-plain.mp3', r, 'c.mp3');
    }
    copy(
      'opus-plain.opus',
      phoneHost.root,
      'Handy/x.opus',
    ); // nur auf dem Handy
    pc = SyncService(
      dataDir: '${tmp.path}/pc/data',
      host: pcHost,
      deviceName: 'PC',
      port: 0,
      mdns: DartMdns(port: 45353), // nicht das mDNS des Systems
    );
    phone = SyncService(
      dataDir: '${tmp.path}/handy/data',
      host: phoneHost,
      deviceName: 'Handy',
      port: 0,
      mdns: DartMdns(port: 45353), // nicht das mDNS des Systems
    );
    await pc.init();
    await phone.init();
    await pc.startServer();
    await phone.startServer();
  });

  tearDown(() async {
    await pc.stopServer();
    await phone.stopServer();
    await tmp.delete(recursive: true);
  });

  Future<(SyncSession, SyncSession)> sync() async {
    final peer = pc.peers.single;
    final a = await pc.syncWith(
      peer,
      hostOverride: '127.0.0.1',
      portOverride: phone.listeningPort,
    );
    expect(a, isNotNull, reason: pc.message);
    await waitFor(
      () => phone.session != null && phone.session!.ready && a!.ready,
      what: 'Inbox bereit',
    );
    expect(a!.error, isNull);
    expect(phone.session!.error, isNull);
    return (a, phone.session!);
  }

  Future<void> finishBoth(SyncSession a, SyncSession b) async {
    await Future.wait([a.finish(), b.finish()]);
    await waitFor(() => a.closed && b.closed, what: 'Sitzungen geschlossen');
    pc.dismissSession();
    phone.dismissSession();
  }

  Map<ChangeKind, List<String>> summary(SyncSession s) {
    final m = <ChangeKind, List<String>>{};
    for (final i in s.items) {
      m
          .putIfAbsent(i.remote.kind, () => [])
          .add(
            '${i.isConflict ? 'KONFLIKT ' : ''}${i.remote.newEntry?.path ?? i.remote.oldEntry!.path}',
          );
    }
    return m;
  }

  test(
    'Kopplung, erster Abgleich, Änderungen, Konflikt, nichts mehr zu tun',
    () async {
      // ─── Kopplung ───
      phone.allowPairing();
      unawaited(pc.pairWith('127.0.0.1', phone.listeningPort!));
      await waitFor(
        () => pc.pairing != null && phone.pairing != null,
        what: 'Kopplungscode',
      );
      expect(pc.pairing!.code, phone.pairing!.code);
      pc.confirmPairing(true);
      phone.confirmPairing(true);
      await waitFor(
        () => pc.pairing!.result != null && phone.pairing!.result != null,
        what: 'Kopplung',
      );
      expect(pc.pairing!.result, isTrue);
      expect(phone.pairing!.result, isTrue);
      expect(pc.peers.single.name, 'Handy');
      expect(phone.peers.single.name, 'PC');

      // ─── 1. Abgleich: nur die Handy-Datei ist neu für den PC ───
      var (a, b) = await sync();
      expect(summary(a), {
        ChangeKind.add: ['Handy/x.opus'],
      });
      expect(b.items, isEmpty);
      a.acceptAll();
      await a.applyDecisions();
      expect(a.items.single.done, isTrue, reason: a.items.single.error);
      expect(
        sha('${pcHost.root}/Handy/x.opus'),
        sha('${phoneHost.root}/Handy/x.opus'),
      );
      await finishBoth(a, b);

      // ─── Änderungen ───
      // PC: umbenennen, Tags ändern, löschen, neue Datei
      const renamed = 'Verschoben/Tiefer/c-umbenannt.mp3';
      Directory('${pcHost.root}/Verschoben/Tiefer').createSync(recursive: true);
      await File('${pcHost.root}/c.mp3').rename('${pcHost.root}/$renamed');
      final tagsA = await readTags('${pcHost.root}/Lumen/a.mp3');
      await writeTags('${pcHost.root}/Lumen/a.mp3', {
        ...tagsA.fields,
        'title': ['Titel vom PC'],
      });
      await File('${pcHost.root}/Lumen/b.flac').delete();
      copy('vorbis-tagged.ogg', pcHost.root, 'Neu/d.ogg');
      // Handy: gleiche Datei anders getaggt (Konflikt) und eigene Datei getaggt
      await writeTags('${phoneHost.root}/Lumen/a.mp3', {
        ...tagsA.fields,
        'title': ['Titel vom Handy'],
      });

      // ─── 2. Abgleich ───
      (a, b) = await sync();
      expect(summary(b), {
        ChangeKind.tags: ['KONFLIKT Lumen/a.mp3'],
        ChangeKind.delete: ['Lumen/b.flac'],
        ChangeKind.rename: [renamed],
        ChangeKind.add: ['Neu/d.ogg'],
      });
      expect(summary(a), {
        ChangeKind.tags: ['KONFLIKT Lumen/a.mp3'],
      });

      // Handy übernimmt alles (Löschen ausdrücklich), PC behält seine Tags
      b.acceptAll(includeDeletes: true);
      await b.applyDecisions();
      for (final i in b.items) {
        expect(i.done, isTrue, reason: '${i.remote.kind}: ${i.error}');
      }
      a.decide(a.items.single, Decision.reject);
      await a.applyDecisions();

      expect(File('${phoneHost.root}/c.mp3').existsSync(), isFalse);
      expect(sha('${phoneHost.root}/$renamed'), sha('${pcHost.root}/$renamed'));
      expect(
        sha('${phoneHost.root}/Neu/d.ogg'),
        sha('${pcHost.root}/Neu/d.ogg'),
      );
      expect(File('${phoneHost.root}/Lumen/b.flac').existsSync(), isFalse);
      final trashed = Directory('${phoneHost.root}/.mync-trash')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.split('/').last);
      expect(
        trashed,
        contains('b.flac'),
        reason: 'Gelöschtes landet im Papierkorb',
      );
      expect(
        (await readTags('${phoneHost.root}/Lumen/a.mp3')).fields['title'],
        ['Titel vom PC'],
      );
      expect((await readTags('${pcHost.root}/Lumen/a.mp3')).fields['title'], [
        'Titel vom PC',
      ]);
      expect(
        phoneHost.applied,
        containsAll([renamed, 'Neu/d.ogg', 'Lumen/a.mp3']),
      );
      await finishBoth(a, b);

      // ─── 3. Abgleich: alles gleich ───
      (a, b) = await sync();
      expect(a.items, isEmpty);
      expect(b.items, isEmpty);
      await finishBoth(a, b);
    },
  );

  test(
    'Erster Abgleich: gleiche Aufnahme unter anderem Namen = Umbenennung',
    () async {
      await File('${pcHost.root}/c.mp3').rename('${pcHost.root}/c-anders.mp3');
      phone.allowPairing();
      unawaited(pc.pairWith('127.0.0.1', phone.listeningPort!));
      await waitFor(
        () => pc.pairing != null && phone.pairing != null,
        what: 'Kopplung',
      );
      pc.confirmPairing(true);
      phone.confirmPairing(true);
      await waitFor(
        () => pc.pairing!.result == true && phone.pairing!.result == true,
        what: 'gekoppelt',
      );
      final (a, b) = await sync();
      expect(summary(a), {
        ChangeKind.rename: ['c.mp3'],
        ChangeKind.add: ['Handy/x.opus'],
      });
      expect(summary(b), {
        ChangeKind.rename: ['c-anders.mp3'],
      });
      // Das Handy übernimmt den Namen vom PC: Datei wird nur umbenannt
      b.acceptAll();
      await b.applyDecisions();
      expect(File('${phoneHost.root}/c-anders.mp3').existsSync(), isTrue);
      expect(File('${phoneHost.root}/c.mp3').existsSync(), isFalse);
      a.decide(
        a.items.firstWhere((i) => i.remote.kind == ChangeKind.rename),
        Decision.reject,
      );
      await finishBoth(a, b);
      final (a2, b2) = await sync();
      expect(summary(a2), {
        ChangeKind.add: ['Handy/x.opus'],
      });
      expect(b2.items, isEmpty);
      await finishBoth(a2, b2);
    },
  );

  test('Immer ignorieren: die Änderung wird nicht mehr angeboten', () async {
    phone.allowPairing();
    unawaited(pc.pairWith('127.0.0.1', phone.listeningPort!));
    await waitFor(
      () => pc.pairing != null && phone.pairing != null,
      what: 'Kopplung',
    );
    pc.confirmPairing(true);
    phone.confirmPairing(true);
    await waitFor(
      () => pc.pairing!.result == true && phone.pairing!.result == true,
      what: 'gekoppelt',
    );

    var (a, b) = await sync();
    expect(a.items.single.remote.newEntry!.path, 'Handy/x.opus');
    a.decide(a.items.single, Decision.ignore);
    await a.applyDecisions();
    expect(File('${pcHost.root}/Handy/x.opus').existsSync(), isFalse);
    await finishBoth(a, b);

    (a, b) = await sync();
    expect(a.items, isEmpty);
    await finishBoth(a, b);
  });
}
