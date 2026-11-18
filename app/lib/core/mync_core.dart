/// Anbindung an den mync-Kern (Zig, `core/`) über dart:ffi.
///
/// Der Kern exportiert C-Funktionen, die JSON liefern:
/// `{"ok": …}` oder `{"error": "…"}`. Aufrufe laufen in einem eigenen
/// Isolate, damit die Oberfläche beim Scannen nicht hängt.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _OneStr = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _TwoStr = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _VersionC = Pointer<Utf8> Function();

class MyncCoreException implements Exception {
  MyncCoreException(this.message);
  final String message;

  /// Verständliche Meldung für die Oberfläche.
  String get userMessage => switch (message) {
    'UnsupportedFormat' => 'Tags dieses Formats können noch nicht geschrieben werden (bisher: MP3, FLAC).',
    'FileNotFound' => 'Datei oder Ordner nicht gefunden.',
    'AccessDenied' || 'PermissionDenied' => 'Keine Berechtigung.',
    'AudioChanged' =>
      'Sicherheitsprüfung fehlgeschlagen – die Datei wurde nicht verändert.',
    _ => message,
  };

  @override
  String toString() => 'mync-Kern: $message';
}

class _Lib {
  _Lib._(DynamicLibrary lib)
    : scan = lib.lookupFunction<_TwoStr, _TwoStr>('mync_scan'),
      listTracks = lib.lookupFunction<_TwoStr, _TwoStr>('mync_list_tracks'),
      readTags = lib.lookupFunction<_OneStr, _OneStr>('mync_read_tags'),
      writeTags = lib.lookupFunction<_TwoStr, _TwoStr>('mync_write_tags'),
      extractCover = lib.lookupFunction<_TwoStr, _TwoStr>('mync_extract_cover'),
      free = lib.lookupFunction<_FreeC, _FreeDart>('mync_free'),
      version = lib.lookupFunction<_VersionC, _VersionC>('mync_version');

  final _TwoStr scan;
  final _TwoStr listTracks;
  final _OneStr readTags;
  final _TwoStr writeTags;
  final _TwoStr extractCover;
  final _FreeDart free;
  final _VersionC version;

  static _Lib? _instance;
  static _Lib get instance => _instance ??= _Lib._(_open());

  static DynamicLibrary _open() {
    if (Platform.isLinux || Platform.isAndroid) {
      // Linux: liegt im Bundle unter lib/ (RPATH $ORIGIN/lib), Android: jniLibs
      return DynamicLibrary.open('libmync_core.so');
    }
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
  ScanSummary.fromJson(Map<String, dynamic> j)
    : total = j['total'] as int,
      hashed = j['hashed'] as int,
      added = j['added'] as int,
      removed = j['removed'] as int,
      errors = (j['errors'] as List).cast<String>();

  final int total;
  final int hashed;
  final int added;
  final int removed;
  final List<String> errors;
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
      writable = j['writable'] as bool;

  final TagFields fields;
  final int pictures;
  final bool writable;
}

String coreVersion() => _Lib.instance.version().toDartString();

/// Durchsucht den Musikordner [root] und aktualisiert das Manifest [db].
Future<ScanSummary> scanLibrary({required String root, required String db}) =>
    Isolate.run(() {
      final lib = _Lib.instance;
      return ScanSummary.fromJson(
        lib.call2(lib.scan, root, db) as Map<String, dynamic>,
      );
    });

/// Liefert alle Audiodateien aus dem Manifest, sortiert nach Pfad.
Future<List<TrackInfo>> listTracks({
  required String root,
  required String db,
}) => Isolate.run(() {
  final lib = _Lib.instance;
  final list = lib.call2(lib.listTracks, root, db) as List;
  return [for (final t in list) TrackInfo.fromJson(t as Map<String, dynamic>)];
});

/// Liest alle Tags der Datei [absPath].
Future<FileTags> readTags(String absPath) => Isolate.run(() {
  final lib = _Lib.instance;
  return FileTags.fromJson(
    lib.call1(lib.readTags, absPath) as Map<String, dynamic>,
  );
});

/// Ersetzt die Tags der Datei [absPath] durch [fields] (fehlende Felder
/// werden entfernt). Nur MP3 und FLAC.
Future<FileTags> writeTags(String absPath, TagFields fields) => Isolate.run(() {
  final lib = _Lib.instance;
  final json = jsonEncode(fields);
  return FileTags.fromJson(
    lib.call2(lib.writeTags, absPath, json) as Map<String, dynamic>,
  );
});

/// Schreibt das eingebettete Cover von [absPath] nach [outPath].
/// Liefert false, wenn die Datei kein Cover enthält.
Future<bool> extractCover(String absPath, String outPath) => Isolate.run(() {
  final lib = _Lib.instance;
  return lib.call2(lib.extractCover, absPath, outPath) as bool;
});
