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
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../library/chapters.dart';

typedef _OneStr = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _TwoStr = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
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

  final _TwoStr scan;
  final _TwoStr listTracks;
  final _OneStr readTags;
  final _TwoStr writeTags;
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

/// SHA-256 einer Datei (hex).
Future<String> sha256File(String path) => Isolate.run(() {
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
