// Teil-Updates der APK (wie Kassenbon). Braucht den Zig-Kern
// (LD_LIBRARY_PATH=../core/zig-out/lib).
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/core/mync_core.dart';
import 'package:mync/update/android_update.dart';
import 'package:mync/update/delta.dart';

bool _core() {
  try {
    DynamicLibrary.open('libmync_core.so');
    return true;
  } catch (_) {
    return false;
  }
}

/// Dieselben Prüfdaten wie Kassenbon (chunker.zig/delta.dart):
/// 300 000 Bytes aus splitmix64, Startwert 42.
Uint8List testData() {
  final buf = Uint8List(300000);
  var s = 42;
  for (var i = 0; i < buf.length; i++) {
    s += 0x9E3779B97F4A7C15;
    var z = s;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    buf[i] = (z ^ (z >>> 31)) & 0xFF;
  }
  return buf;
}

/// Liefert [data] wie GitHub: /apk leitet auf /signed um, dort nur einzelne
/// Bereiche (206). [ignoreRanges]: Server, der Ranges ignoriert (200).
Future<(HttpServer, List<String>)> serve(
  Uint8List data, {
  bool ignoreRanges = false,
}) async {
  final log = <String>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    log.add('${req.uri.path} ${range ?? '-'}');
    if (req.uri.path == '/apk') {
      res.statusCode = HttpStatus.found;
      res.headers.set(HttpHeaders.locationHeader, '/signed');
    } else if (range == null || ignoreRanges) {
      res.add(data);
    } else if (range.contains(',')) {
      res.statusCode = HttpStatus.notImplemented; // wie GitHub
    } else {
      final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
      final a = int.parse(m[1]!), b = int.parse(m[2]!);
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $a-$b/${data.length}',
      );
      res.add(Uint8List.sublistView(data, a, b + 1));
    }
    await res.close();
  });
  return (server, log);
}

void main() {
  final skip = _core() ? false : 'libmync_core.so fehlt';
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('mync_delta'));
  tearDown(() => tmp.delete(recursive: true));

  Future<String> write(String name, List<int> data) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(data);
    return f.path;
  }

  Future<ChunkManifest> manifestOf(String path, String url) async {
    final bytes = await File(path).readAsBytes();
    return ChunkManifest.fromJson({
      'version': '9.9.9',
      'name': 'mync-v9.9.9-android-arm64.apk',
      'url': url,
      'size': bytes.length,
      'sha256': await sha256File(path),
      'chunks': [
        for (final (h, _, l) in await chunkFile(path)) [h, l],
      ],
    });
  }

  test('gleiche Bausteine wie Kassenbon (Prüfwerte aus chunker.zig)', () async {
    final chunks = await chunkFile(await write('t', testData()));
    expect(
      [for (final c in chunks) c.$3],
      [15101, 27119, 58303, 20822, 11470, 39488, 64528, 18597, 30563, 14009],
    );
    expect(chunks.first.$1, '2c12667d4ab2cedc82508ad421eb578f');
    expect(chunks[1].$2, 15101); // Offset
  }, skip: skip);

  test('Bereiche: fehlende Bausteine, nahe Lücken zusammengefasst', () {
    final m = ChunkManifest.fromJson({
      'version': '1.0.0',
      'name': 'a.apk',
      'url': 'u',
      'size': 50000,
      'sha256': '',
      'chunks': [
        ['a', 10000],
        ['x', 10000],
        ['b', 10000],
        ['y', 10000],
        ['c', 10000],
      ],
    });
    final have = [('a', 0, 10000), ('b', 10000, 10000), ('c', 20000, 10000)];
    // ohne Lückenfüllung: zwei Bereiche; mit: einer (b wird mitgeladen)
    expect(plan(m, have, gap: 0).ranges, [(10000, 10000), (30000, 10000)]);
    expect(plan(m, have).ranges, [(10000, 30000)]);
    expect(plan(m, have, gap: 0).download, 20000);
  });

  test(
    'Teil-Update von einem Server wie GitHub (Umleitung, einzelne Ranges)',
    () async {
      final old = testData();
      final neu = Uint8List.fromList([
        ...old.sublist(0, 120000),
        ...List.filled(5000, 0x55),
        ...old.sublist(125000),
      ]);
      final installed = await write('alt.apk', old);
      final (server, log) = await serve(neu);
      addTearDown(server.close);
      final m = await manifestOf(
        await write('neu.apk', neu),
        'http://127.0.0.1:${server.port}/apk',
      );
      final p = plan(m, await chunkFile(installed));
      expect(p.download, lessThan(neu.length ~/ 3));
      final out = await Directory('${tmp.path}/updates').create();
      final texts = <String>{};
      final path = await prepareApk(
        manifest: m,
        plan: p,
        installedApk: installed,
        dir: out.path,
        client: HttpClient.new,
        report: (_, t) => texts.add(t),
      );
      expect(await File(path).readAsBytes(), neu);
      expect(texts.single, startsWith('Lade nur'));
      // nur einzelne Bereiche, die Umleitung wurde einmal aufgelöst
      expect(log.where((l) => l.startsWith('/apk')).length, 1);
      expect(log.where((l) => l.contains(',')), isEmpty);
    },
    skip: skip,
  );

  test('Rückfall auf die ganze APK, wenn Ranges nicht gehen', () async {
    final old = testData();
    final neu = Uint8List.fromList([...old.reversed]);
    final installed = await write('alt.apk', old);
    final (server, _) = await serve(neu, ignoreRanges: true);
    addTearDown(server.close);
    final m = await manifestOf(
      await write('neu.apk', neu),
      'http://127.0.0.1:${server.port}/apk',
    );
    final out = await Directory('${tmp.path}/updates').create();
    final path = await prepareApk(
      manifest: m,
      plan: plan(m, await chunkFile(installed)),
      installedApk: installed,
      dir: out.path,
      client: HttpClient.new,
      report: (_, _) {},
    );
    expect(await File(path).readAsBytes(), neu);
  }, skip: skip);
}
