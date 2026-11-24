/// Anbindung an den mync-Kern (Zig, `core/`) über dart:ffi.
///
/// Der Kern exportiert C-Funktionen, die JSON liefern:
/// `{"ok": …}` oder `{"error": "…"}`. Aufrufe laufen in einem eigenen
/// Isolate, damit die Oberfläche beim Scannen nicht hängt.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../library/chapters.dart';
import '../log.dart';
import 'music_fs.dart';

typedef _OneStr = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _TwoStr = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _ScanC = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Pointer<Uint32>,
);
typedef _ScanD = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  Pointer<Uint32>,
);
typedef _FillC = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Uint32>,
);
typedef _ScanListingC = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Int32,
  Pointer<Uint32>,
);
typedef _ScanListingD = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  int,
  Pointer<Uint32>,
);
typedef _ThreeStr = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _KeypairC = Void Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _KeypairD = void Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _DhC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _DhD = int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _SealC = Void Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
);
typedef _SealD = void Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
);
typedef _OpenC = Int32 Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
);
typedef _OpenD = int Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
);
typedef _HkdfC = Void Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
);
typedef _HkdfD = void Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);
typedef _ShaC = Void Function(Pointer<Uint8>, Size, Pointer<Uint8>);
typedef _ShaD = void Function(Pointer<Uint8>, int, Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _VersionC = Pointer<Utf8> Function();

class MyncCoreException implements Exception {
  MyncCoreException(this.message);
  final String message;

  /// Verständliche Meldung für die Oberfläche.
  String get userMessage => switch (message) {
    'UnsupportedFormat' => 'Format nicht schreibbar',
    'UnsupportedImage' => 'Nur JPEG/PNG',
    'FileNotFound' => 'Nicht gefunden',
    'AccessDenied' || 'PermissionDenied' => 'Keine Berechtigung',
    'AudioChanged' => 'Prüfung fehlgeschlagen – unverändert',
    _ => message,
  };

  @override
  String toString() => 'mync-Kern: $message';
}

class _Lib {
  _Lib._(DynamicLibrary lib)
    : scan = lib.lookupFunction<_ScanC, _ScanD>('mync_scan'),
      chunkFile = lib.lookupFunction<_OneStr, _OneStr>('mync_chunk_file'),
      pendingHashes = lib.lookupFunction<_OneStr, _OneStr>(
        'mync_pending_hashes',
      ),
      fillHashes = lib.lookupFunction<_FillC, _FillC>('mync_fill_hashes'),
      scanListing = lib.lookupFunction<_ScanListingC, _ScanListingD>(
        'mync_scan_listing',
      ),
      listTracks = lib.lookupFunction<_TwoStr, _TwoStr>('mync_list_tracks'),
      readTags = lib.lookupFunction<_OneStr, _OneStr>('mync_read_tags'),
      writeTags = lib.lookupFunction<_ThreeStr, _ThreeStr>('mync_write_tags'),
      extractCover = lib.lookupFunction<_TwoStr, _TwoStr>('mync_extract_cover'),
      verifyEd25519 = lib.lookupFunction<_ThreeStr, _ThreeStr>(
        'mync_verify_ed25519',
      ),
      sha256File = lib.lookupFunction<_OneStr, _OneStr>('mync_sha256_file'),
      manifestEntries = lib.lookupFunction<_TwoStr, _TwoStr>(
        'mync_manifest_entries',
      ),
      syncPlan = lib.lookupFunction<_OneStr, _OneStr>('mync_sync_plan'),
      x25519Keypair = lib.lookupFunction<_KeypairC, _KeypairD>(
        'mync_x25519_keypair',
      ),
      x25519 = lib.lookupFunction<_DhC, _DhD>('mync_x25519'),
      aeadSeal = lib.lookupFunction<_SealC, _SealD>('mync_aead_seal'),
      aeadOpen = lib.lookupFunction<_OpenC, _OpenD>('mync_aead_open'),
      hkdf = lib.lookupFunction<_HkdfC, _HkdfD>('mync_hkdf'),
      sha256 = lib.lookupFunction<_ShaC, _ShaD>('mync_sha256'),
      free = lib.lookupFunction<_FreeC, _FreeDart>('mync_free'),
      version = lib.lookupFunction<_VersionC, _VersionC>('mync_version');

  final _ScanD scan;
  final _OneStr chunkFile;
  final _OneStr pendingHashes;
  final _FillC fillHashes;
  final _ScanListingD scanListing;
  final _TwoStr listTracks;
  final _OneStr readTags;
  final _ThreeStr writeTags;
  final _TwoStr extractCover;
  final _ThreeStr verifyEd25519;
  final _OneStr sha256File;
  final _TwoStr manifestEntries;
  final _OneStr syncPlan;
  final _KeypairD x25519Keypair;
  final _DhD x25519;
  final _SealD aeadSeal;
  final _OpenD aeadOpen;
  final _HkdfD hkdf;
  final _ShaD sha256;
  final _FreeDart free;
  final _VersionC version;

  static _Lib? _instance;
  static _Lib get instance => _instance ??= _Lib._(_open());

  static DynamicLibrary _open() {
    if (Platform.isLinux) {
      // Zuerst neben dem Programm (Bundle: lib/), unabhängig davon, wie der
      // Suchpfad gesetzt ist (z. B. von Nix' autoPatchelf umgeschrieben)
      final dir = File(Platform.resolvedExecutable).parent.path;
      final bundled = File('$dir/lib/libmync_core.so');
      if (bundled.existsSync()) return DynamicLibrary.open(bundled.path);
      return DynamicLibrary.open('libmync_core.so'); // Tests, Entwicklung
    }
    if (Platform.isAndroid) return DynamicLibrary.open('libmync_core.so');
    throw UnsupportedError('mync läuft auf Linux und Android');
  }

  Object? _result(Pointer<Utf8> res) {
    if (res == nullptr) throw MyncCoreException('kein Ergebnis');
    try {
      final json = jsonDecode(res.toDartString()) as Map<String, dynamic>;
      if (json.containsKey('error')) {
        throw MyncCoreException(json['error'] as String);
      }
      return json['ok'];
    } finally {
      free(res);
    }
  }

  Object? call1(_OneStr f, String a) {
    final pa = a.toNativeUtf8();
    try {
      return _result(f(pa));
    } finally {
      malloc.free(pa);
    }
  }

  Object? call3(_ThreeStr f, String a, String b, String c) {
    final pa = a.toNativeUtf8();
    final pb = b.toNativeUtf8();
    final pc = c.toNativeUtf8();
    try {
      return _result(f(pa, pb, pc));
    } finally {
      malloc.free(pa);
      malloc.free(pb);
      malloc.free(pc);
    }
  }

  Object? call2(_TwoStr f, String a, String b) {
    final pa = a.toNativeUtf8();
    final pb = b.toNativeUtf8();
    try {
      return _result(f(pa, pb));
    } finally {
      malloc.free(pa);
      malloc.free(pb);
    }
  }
}

/// Ergebnis eines Bibliotheks-Scans.
class ScanSummary {
  const ScanSummary({
    required this.total,
    required this.hashed,
    required this.added,
    required this.removed,
    this.errors = const [],
    this.needed = const [],
  });

  ScanSummary.fromJson(Map<String, dynamic> j)
    : total = j['total'] as int,
      hashed = j['hashed'] as int,
      added = j['added'] as int,
      removed = j['removed'] as int,
      errors = (j['errors'] as List).cast<String>(),
      needed = ((j['needed'] as List?) ?? const []).cast<String>();

  final int total;
  final int hashed;
  final int added;
  final int removed;
  final List<String> errors;

  /// Nur bei [scanListing]: neu einzulesende Dateien ohne `src`.
  final List<String> needed;
}

/// Feldname → Werte, z. B. {"artist": ["A", "B"]}.
typedef TagFields = Map<String, List<String>>;

TagFields _fields(Object? j) => {
  for (final e in (j as Map<String, dynamic>).entries)
    e.key: (e.value as List).cast<String>(),
};

/// Eine Audiodatei der Bibliothek, wie sie der Kern liefert.
class TrackInfo {
  TrackInfo.fromJson(Map<String, dynamic> j)
    : fileId = j['file_id'] as String,
      path = j['path'] as String,
      durationMs = j['duration_ms'] as int,
      addedMs = j['added_ms'] as int,
      hasLyrics = j['has_lyrics'] as bool,
      fields = _fields(j['fields']);

  final String fileId;

  /// Relativ zur Musikwurzel, mit `/`.
  final String path;
  final int durationMs;
  final int addedMs;
  final bool hasLyrics;
  final TagFields fields;
}

/// Alle Tags einer einzelnen Datei (inkl. Lyrics).
class FileTags {
  FileTags.fromJson(Map<String, dynamic> j)
    : fields = _fields(j['fields']),
      pictures = j['pictures'] as int,
      writable = j['writable'] as bool,
      pictureHashes = (j['picture_hashes'] as List? ?? const []).cast<String>(),
      chapters = [
        for (final c in (j['chapters'] as List? ?? const []))
          Chapter(
            Duration(
              milliseconds: (c as Map<String, dynamic>)['start_ms'] as int,
            ),
            c['title'] as String,
            end: c['end_ms'] == null
                ? null
                : Duration(milliseconds: c['end_ms'] as int),
          ),
      ];

  final TagFields fields;
  final int pictures;
  final bool writable;
  final List<String> pictureHashes;

  /// Kapitel aus den Tags (ID3 CHAP, Vorbis CHAPTERxxx, MP4 chpl).
  final List<Chapter> chapters;
}

String coreVersion() => _Lib.instance.version().toDartString();

/// Durchsucht den Musikordner [root] und aktualisiert das Manifest [db].
/// [excludes]: Ausschlussmuster (`*.wav`, `Hörproben`, `Podcasts/**/*.mp3`).
/// [onProgress]: (gefunden, zu lesen, fertig), etwa dreimal pro Sekunde.
Future<ScanSummary> scanLibrary({
  required String root,
  required String db,
  List<String> excludes = const [],
  void Function(int found, int total, int done)? onProgress,
}) async {
  // Drei Zähler im nativen Speicher: der Kern zählt (aus mehreren Threads),
  // dieser Isolate liest sie, während der Scan in einem anderen läuft.
  final counters = calloc<Uint32>(3);
  final address = counters.address;
  Timer? timer;
  if (onProgress != null) {
    timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      onProgress(counters[0], counters[1], counters[2]);
    });
  }
  try {
    return await _scanInIsolate(root, db, jsonEncode(excludes), address);
    // Audio-Hashes holt [fillHashes] im Hintergrund nach
  } finally {
    timer?.cancel();
    calloc.free(counters);
  }
}

/// Eigene Funktion, damit die Closure für den Isolate nur diese einfachen
/// Werte mitnimmt (nicht den Fortschritts-Callback und was an ihm hängt).
Future<ScanSummary> _scanInIsolate(
  String root,
  String db,
  String excludesJson,
  int progressAddress,
) => Isolate.run(() {
  final lib = _Lib.instance;
  final a = root.toNativeUtf8();
  final b = db.toNativeUtf8();
  final c = excludesJson.toNativeUtf8();
  try {
    return ScanSummary.fromJson(
      lib._result(
        lib.scan(
          a,
          b,
          c,
          _deferAudio,
          Pointer<Uint32>.fromAddress(progressAddress),
        ),
      ) as Map<String, dynamic>,
    );
  } finally {
    malloc.free(a);
    malloc.free(b);
    malloc.free(c);
  }
});

/// Scans lesen nur Tags und Dauer (Dateiköpfe); der Audio-Hash liest die
/// ganze Datei und wird nur für den Sync gebraucht – er entsteht danach im
/// Hintergrund ([pendingHashes], [fillHashes]).
const _deferAudio = 1;

/// Pfade im Manifest [db], deren Audio-Hash noch fehlt.
Future<List<String>> pendingHashes(String db) => Isolate.run(() {
  final lib = _Lib.instance;
  return (lib.call1(lib.pendingHashes, db) as List).cast<String>();
});

/// Berechnet fehlende Audio-Hashes. [items]: Pfad im Manifest → `src`
/// (absoluter Pfad oder `fd:N:<name>`). Liefert (berechnet, Fehler).
Future<(int, List<String>)> fillHashes(String db, Map<String, String> items) =>
    _fillInIsolate(
      db,
      jsonEncode([
        for (final e in items.entries) {'path': e.key, 'src': e.value},
      ]),
    );

Future<(int, List<String>)> _fillInIsolate(String db, String json) =>
    Isolate.run(() {
      final lib = _Lib.instance;
      final a = db.toNativeUtf8();
      final b = json.toNativeUtf8();
      try {
        final r =
            lib._result(lib.fillHashes(a, b, nullptr)) as Map<String, dynamic>;
        return (r['hashed'] as int, (r['errors'] as List).cast<String>());
      } finally {
        malloc.free(a);
        malloc.free(b);
      }
    });

/// Holt alle fehlenden Audio-Hashes eines lokalen Ordners [root] nach.
Future<void> hashAllPending({required String root, required String db}) async {
  final p = await pendingHashes(db);
  if (p.isEmpty) return;
  await fillHashes(db, {for (final x in p) x: '$root/$x'});
}

/// Gleicht das Manifest [db] mit einer Auflistung ab (siehe
/// `mync_scan_listing` im Kern). Einträge: `path`, `size`, `mtime_ns` und
/// optional `src` (`fd:N:<name>`) für Dateien, die eingelesen werden sollen.
Future<ScanSummary> scanListing({
  required String db,
  required List<Map<String, Object>> listing,
  List<String> excludes = const [],
  bool last = false,
}) =>
    _scanListingInIsolate(db, jsonEncode(listing), jsonEncode(excludes), last);

Future<ScanSummary> _scanListingInIsolate(
  String db,
  String listingJson,
  String excludesJson,
  bool last,
) => Isolate.run(() {
  final lib = _Lib.instance;
  final a = db.toNativeUtf8();
  final b = listingJson.toNativeUtf8();
  final c = excludesJson.toNativeUtf8();
  try {
    return ScanSummary.fromJson(
      lib._result(lib.scanListing(a, b, c, last ? 1 : 0, _deferAudio, nullptr))
          as Map<String, dynamic>,
    );
  } finally {
    malloc.free(a);
    malloc.free(b);
    malloc.free(c);
  }
});

/// Scan einer Ordnerfreigabe (Android): Kotlin listet auf, der Kern sagt,
/// was neu einzulesen ist, und bekommt diese Dateien portionsweise als
/// offene Deskriptoren – nie mehr als [batch] auf einmal (nur Dateiköpfe
/// werden gelesen, siehe [_deferAudio]).
Future<ScanSummary> scanTree({
  required String tree,
  required String db,
  List<String> excludes = const [],
  void Function(int found, int total, int done)? onProgress,
  Future<void> Function()? onBatch,
  int batch = 256,
}) async {
  final watch = Stopwatch()..start();
  final files = await MusicFs.listFiles(tree);
  logInfo(
    'Einlesen: ${files.length} Dateien aufgelistet in '
    '${watch.elapsedMilliseconds} ms',
  );
  final listing = [for (final f in files) f.toJson()];
  final first = await scanListing(db: db, listing: listing, excludes: excludes);
  final needed = first.needed;
  onProgress?.call(first.total, needed.length, 0);
  final index = {for (var i = 0; i < files.length; i++) files[i].path: i};
  var hashed = 0, added = 0;
  final errors = <String>[...first.errors];
  for (var start = 0; start < needed.length; start += batch) {
    final part = needed.sublist(start, min(start + batch, needed.length));
    final fds = await MusicFs.openFds(tree, part);
    try {
      final withSrc = [...listing];
      for (var i = 0; i < part.length; i++) {
        if (fds[i] < 0) {
          errors.add('${part[i]}: nicht lesbar');
          continue;
        }
        final at = index[part[i]]!;
        withSrc[at] = {...listing[at], 'src': 'fd:${fds[i]}:${part[i]}'};
      }
      final r = await scanListing(db: db, listing: withSrc, excludes: excludes);
      hashed += r.hashed;
      added += r.added;
      errors.addAll(r.errors);
    } finally {
      await MusicFs.closeFds(fds);
    }
    onProgress?.call(
      first.total,
      needed.length,
      min(start + batch, needed.length),
    );
    await onBatch?.call(); // schon Eingelesenes anzeigen
  }
  if (needed.isNotEmpty) {
    logInfo(
      'Einlesen: ${needed.length} Dateien gelesen, gesamt '
      '${watch.elapsedMilliseconds} ms',
    );
  }
  final done = await scanListing(
    db: db,
    listing: listing,
    excludes: excludes,
    last: true,
  );
  return ScanSummary(
    total: done.total,
    hashed: hashed,
    added: added,
    removed: done.removed,
    errors: [...errors, ...done.errors],
  );
}

/// Liefert alle Audiodateien aus dem Manifest, sortiert nach Pfad.
Future<List<TrackInfo>> listTracks({
  required String root,
  required String db,
}) => Isolate.run(() {
  final lib = _Lib.instance;
  final list = lib.call2(lib.listTracks, root, db) as List;
  return [for (final t in list) TrackInfo.fromJson(t as Map<String, dynamic>)];
});

/// Liest alle Tags der Datei am Ort [loc] (Pfad oder Ordnerfreigabe,
/// siehe `MusicFs`).
Future<FileTags> readTags(String loc) => MusicFs.withReadPath(loc, _readTagsAt);

Future<FileTags> _readTagsAt(String path) => Isolate.run(() {
  final lib = _Lib.instance;
  return FileTags.fromJson(
    lib.call1(lib.readTags, path) as Map<String, dynamic>,
  );
});

/// Ersetzt die Tags der Datei am Ort [loc] durch [fields] (fehlende Felder
/// werden entfernt). In einer Ordnerfreigabe über eine Arbeitskopie.
///
/// Cover: [coverFile] (JPEG/PNG) ersetzt alle eingebetteten Bilder,
/// [removeCover] entfernt sie; sonst bleiben sie unverändert.
Future<FileTags> writeTags(
  String loc,
  TagFields fields, {
  String? coverFile,
  bool removeCover = false,
}) {
  final json = jsonEncode(fields);
  final cover = coverFile ?? (removeCover ? '-' : '');
  return MusicFs.withWritePath(loc, (p) => _writeTagsAt(p, json, cover));
}

Future<FileTags> _writeTagsAt(String path, String json, String cover) =>
    Isolate.run(() {
      final lib = _Lib.instance;
      return FileTags.fromJson(
        lib.call3(lib.writeTags, path, json, cover) as Map<String, dynamic>,
      );
    });

/// Schreibt das eingebettete Cover der Datei [path] (Pfad oder `fd:N:…`)
/// nach [outPath]. Liefert false, wenn die Datei kein Cover enthält.
Future<bool> extractCover(String path, String outPath) => Isolate.run(() {
  final lib = _Lib.instance;
  return lib.call2(lib.extractCover, path, outPath) as bool;
});

/// Zerlegt die Datei [path] in Bausteine (Teil-Updates, wie Kassenbon):
/// (hash, offset, länge).
Future<List<(String, int, int)>> chunkFile(String path) => Isolate.run(() {
  final lib = _Lib.instance;
  return [
    for (final c in lib.call1(lib.chunkFile, path) as List)
      (c[0] as String, (c[1] as num).toInt(), (c[2] as num).toInt()),
  ];
});

/// Prüft eine Ed25519-Signatur (Schlüssel und Signatur hexadezimal).
Future<bool> verifyEd25519(
  String publicKeyHex,
  String message,
  String signatureHex,
) => Isolate.run(() {
  final lib = _Lib.instance;
  return lib.call3(lib.verifyEd25519, publicKeyHex, message, signatureHex)
      as bool;
});

/// SHA-256 einer Datei (hex), auch in einer Ordnerfreigabe.
Future<String> sha256File(String loc) => MusicFs.withReadPath(loc, _sha256At);

Future<String> _sha256At(String path) => Isolate.run(() {
  final lib = _Lib.instance;
  return lib.call1(lib.sha256File, path) as String;
});

// ─── Sync ──────────────────────────────────────────────────────────────────

/// Alle Dateien des Manifests mit Hashes (JSON-Objekte path/audio_hash/tag_hash/file_id/size).
Future<List<Map<String, dynamic>>> manifestEntries({
  required String root,
  required String db,
}) => Isolate.run(() {
  final lib = _Lib.instance;
  return (lib.call2(lib.manifestEntries, root, db) as List)
      .cast<Map<String, dynamic>>();
});

/// Vorschläge (Diff-Engine des Kerns) aus Basis, lokalem und entferntem Stand.
List<Map<String, dynamic>> syncPlan(Map<String, Object?> input) {
  final lib = _Lib.instance;
  return (lib.call1(lib.syncPlan, jsonEncode(input)) as List)
      .cast<Map<String, dynamic>>();
}

// ─── Kryptografie (synchron, schnell) ─────────────────────────────────────

Uint8List _withBuffers(
  int outLen,
  void Function(Pointer<Uint8> out, Arena arena) f,
) {
  return using((arena) {
    final out = arena<Uint8>(outLen == 0 ? 1 : outLen);
    f(out, arena);
    return Uint8List.fromList(out.asTypedList(outLen));
  });
}

Pointer<Uint8> _copy(Arena arena, List<int> data) {
  final p = arena<Uint8>(data.isEmpty ? 1 : data.length);
  p.asTypedList(data.length).setAll(0, data);
  return p;
}

/// (geheim, öffentlich), je 32 Byte.
(Uint8List, Uint8List) x25519Keypair() {
  final lib = _Lib.instance;
  return using((arena) {
    final s = arena<Uint8>(32), p = arena<Uint8>(32);
    lib.x25519Keypair(s, p);
    return (
      Uint8List.fromList(s.asTypedList(32)),
      Uint8List.fromList(p.asTypedList(32)),
    );
  });
}

Uint8List x25519(List<int> secret, List<int> public) {
  final lib = _Lib.instance;
  return _withBuffers(32, (out, a) {
    if (lib.x25519(_copy(a, secret), _copy(a, public), out) != 0) {
      throw MyncCoreException('X25519: ungültiger Schlüssel');
    }
  });
}

Uint8List aeadSeal(
  List<int> key,
  List<int> nonce,
  List<int> ad,
  List<int> msg,
) {
  final lib = _Lib.instance;
  return _withBuffers(msg.length + 16, (out, a) {
    lib.aeadSeal(
      _copy(a, key),
      _copy(a, nonce),
      _copy(a, ad),
      ad.length,
      _copy(a, msg),
      msg.length,
      out,
    );
  });
}

/// null, wenn die Nachricht manipuliert ist oder der Schlüssel falsch.
Uint8List? aeadOpen(
  List<int> key,
  List<int> nonce,
  List<int> ad,
  List<int> ct,
) {
  if (ct.length < 16) return null;
  final lib = _Lib.instance;
  var ok = true;
  final r = _withBuffers(ct.length - 16, (out, a) {
    ok =
        lib.aeadOpen(
          _copy(a, key),
          _copy(a, nonce),
          _copy(a, ad),
          ad.length,
          _copy(a, ct),
          ct.length,
          out,
        ) ==
        0;
  });
  return ok ? r : null;
}

Uint8List hkdf(List<int> salt, List<int> ikm, List<int> info, int length) {
  final lib = _Lib.instance;
  return _withBuffers(length, (out, a) {
    lib.hkdf(
      _copy(a, salt),
      salt.length,
      _copy(a, ikm),
      ikm.length,
      _copy(a, info),
      info.length,
      out,
      length,
    );
  });
}

Uint8List sha256Bytes(List<int> data) {
  final lib = _Lib.instance;
  return _withBuffers(
    32,
    (out, a) => lib.sha256(_copy(a, data), data.length, out),
  );
}
