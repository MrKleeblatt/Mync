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

typedef _TwoStr = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _VersionC = Pointer<Utf8> Function();

class MyncCoreException implements Exception {
  MyncCoreException(this.message);
  final String message;
  @override
  String toString() => 'mync-Kern: $message';
}

class _Lib {
  _Lib._(DynamicLibrary lib)
      : scan = lib.lookupFunction<_TwoStr, _TwoStr>('mync_scan'),
        listTracks = lib.lookupFunction<_TwoStr, _TwoStr>('mync_list_tracks'),
        free = lib.lookupFunction<_FreeC, _FreeDart>('mync_free'),
        version = lib.lookupFunction<_VersionC, _VersionC>('mync_version');

  final _TwoStr scan;
  final _TwoStr listTracks;
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

  /// Ruft eine Kernfunktion mit zwei String-Argumenten auf.
  Object? call2(_TwoStr f, String a, String b) {
    final pa = a.toNativeUtf8();
    final pb = b.toNativeUtf8();
    try {
      final res = f(pa, pb);
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

/// Ein Titel der Bibliothek, wie die Oberfläche ihn anzeigt.
class TrackInfo {
  TrackInfo.fromJson(Map<String, dynamic> j)
      : fileId = j['file_id'] as String,
        path = j['path'] as String,
        title = j['title'] as String?,
        artist = j['artist'] as String?,
        album = j['album'] as String?,
        track = j['track'] as String?;

  final String fileId;
  final String path;
  final String? title;
  final String? artist;
  final String? album;
  final String? track;
}

String coreVersion() => _Lib.instance.version().toDartString();

/// Durchsucht den Musikordner [root] und aktualisiert das Manifest [db].
Future<ScanSummary> scanLibrary({required String root, required String db}) =>
    Isolate.run(() {
      final lib = _Lib.instance;
      final j = lib.call2(lib.scan, root, db) as Map<String, dynamic>;
      return ScanSummary.fromJson(j);
    });

/// Liefert alle Titel aus dem Manifest, sortiert nach Pfad.
Future<List<TrackInfo>> listTracks({required String root, required String db}) =>
    Isolate.run(() {
      final lib = _Lib.instance;
      final list = lib.call2(lib.listTracks, root, db) as List;
      return [for (final t in list) TrackInfo.fromJson(t as Map<String, dynamic>)];
    });
