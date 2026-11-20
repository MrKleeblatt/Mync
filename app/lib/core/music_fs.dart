// Zugriff auf Musikdateien, unabhängig vom Speicherort.
//
// Ein Ort ist ein String:
// - Linux: ein absoluter Pfad.
// - Android: die Ordnerfreigabe (`content://…/tree/<id>`) plus `/<pfad>` –
//   mync sieht dort nur die Ordner, die der Nutzer ausgewählt hat
//   (Storage Access Framework, kein „Zugriff auf alle Dateien“). Die
//   Arbeit macht MusicFs.kt über den Kanal `mync/fs`.
//
// Der Zig-Kern kennt unter Android keine Pfade; er bekommt geöffnete
// Dateideskriptoren als `fd:N:<name>` ([withReadPath]) oder eine Kopie im
// Cache ([withWritePath]).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class FsChild {
  const FsChild(this.name, this.isDir);
  final String name;
  final bool isDir;
}

/// Eine Datei der rekursiven Auflistung (für den Scan).
class FsFile {
  const FsFile(this.path, this.size, this.mtimeNs);
  final String path;
  final int size;
  final int mtimeNs;
  Map<String, Object> toJson() => {
    'path': path,
    'size': size,
    'mtime_ns': mtimeNs,
  };
}

abstract final class MusicFs {
  static const _ch = MethodChannel('mync/fs');

  /// Für Tests und Linux: Cache-Verzeichnis für Arbeitskopien.
  static String tempDir = Directory.systemTemp.path;

  /// Ist [loc] ein Ort in einer Ordnerfreigabe (Android)?
  static bool isTree(String loc) => loc.startsWith('content://');

  /// Teilt einen Ort in Freigabe und Pfad darin.
  static (String tree, String rel) split(String loc) {
    final i = loc.indexOf('/tree/');
    final j = i < 0 ? -1 : loc.indexOf('/', i + 6);
    if (j < 0) return (loc, '');
    return (loc.substring(0, j), loc.substring(j + 1));
  }

  static Map<String, Object> _args(String loc, [Map<String, Object>? more]) {
    final (tree, rel) = split(loc);
    return {'tree': tree, 'rel': rel, ...?more};
  }

  /// Übergeordneter Ort (bei der Freigabe selbst: sie selbst).
  static String parent(String loc) {
    if (isTree(loc)) {
      final (tree, rel) = split(loc);
      final i = rel.lastIndexOf('/');
      return i < 0 ? tree : '$tree/${rel.substring(0, i)}';
    }
    return File(loc).parent.path;
  }

  /// Lesbarer Name für einen Ordner: bei Freigaben z. B.
  /// „Interner Speicher/Music“ statt der URI.
  static String describe(String loc) {
    if (!isTree(loc)) return loc;
    final (tree, rel) = split(loc);
    final id = _decode(tree.substring(tree.indexOf('/tree/') + 6));
    final colon = id.indexOf(':');
    final volume = colon < 0 ? '' : id.substring(0, colon);
    final path = colon < 0 ? id : id.substring(colon + 1);
    final where = switch (volume) {
      'primary' => 'Interner Speicher',
      'home' => 'Dokumente',
      '' => 'Freigabe',
      _ => 'SD-Karte',
    };
    return [
      where,
      if (path.isNotEmpty) path,
      if (rel.isNotEmpty) rel,
    ].join('/');
  }

  static String _decode(String s) {
    try {
      return Uri.decodeComponent(s);
    } on ArgumentError {
      return s;
    }
  }

  /// URI zum Abspielen (media_kit kann content:// direkt).
  static String mediaUri(String loc) {
    if (!isTree(loc)) return Uri.file(loc).toString();
    final (tree, rel) = split(loc);
    // Gerätespeicher/SD-Karte: Dokument-ID = Pfad (siehe MusicFs.kt)
    final root = _decode(tree.substring(tree.indexOf('/tree/') + 6));
    final id = rel.isEmpty
        ? root
        : root.endsWith(':')
        ? '$root$rel'
        : '$root/$rel';
    return '$tree/document/${Uri.encodeComponent(id)}';
  }

  // ─── Freigaben ────────────────────────────────────────────────────────

  /// Lässt den Nutzer einen Ordner wählen und merkt sich die Freigabe.
  /// null = abgebrochen.
  static Future<String?> pickTree({String? initial}) => _ch.invokeMethod(
    'pickTree',
    {'initial': ?(initial != null && isTree(initial) ? initial : null)},
  );

  /// Gibt eine Freigabe wieder ab (Ordner entfernt).
  static Future<void> release(String tree) async {
    if (!isTree(tree)) return;
    try {
      await _ch.invokeMethod('release', {'tree': tree});
    } catch (_) {}
  }

  /// Speichert [data] an einem Ort, den der Nutzer wählt (Android).
  /// Liefert die URI oder null bei Abbruch.
  static Future<String?> saveDocument(
    String name,
    Uint8List data, {
    String mime = 'application/octet-stream',
  }) => _ch.invokeMethod('saveDocument', {
    'name': name,
    'mime': mime,
    'data': data,
  });

  // ─── Lesen ────────────────────────────────────────────────────────────

  static Future<bool> exists(String loc) async {
    if (!isTree(loc)) {
      return FileSystemEntity.typeSync(loc) != FileSystemEntityType.notFound;
    }
    return await _ch.invokeMethod<Object>('stat', _args(loc)) != null;
  }

  static Future<bool> isDir(String loc) async {
    if (!isTree(loc)) return Directory(loc).existsSync();
    final s = await _ch.invokeMapMethod<String, Object>('stat', _args(loc));
    return s?['dir'] == true;
  }

  static Future<List<FsChild>> list(String dir) async {
    if (!isTree(dir)) {
      return [
        for (final e in Directory(dir).listSync())
          FsChild(
            e.uri.pathSegments.where((s) => s.isNotEmpty).last,
            e is Directory,
          ),
      ];
    }
    final r = await _ch.invokeListMethod<Map>('children', _args(dir));
    return [
      for (final m in r ?? const [])
        FsChild(m['name'] as String, m['dir'] == true),
    ];
  }

  /// Alle Dateien unter der Freigabe [tree] (ohne versteckte Ordner).
  static Future<List<FsFile>> listFiles(String tree) async {
    final r = await _ch.invokeListMethod<Map>('listFiles', {'tree': tree});
    return [
      for (final m in r ?? const [])
        FsFile(
          m['path'] as String,
          (m['size'] as num).toInt(),
          (m['mtime_ns'] as num).toInt(),
        ),
    ];
  }

  static Future<Uint8List> readBytes(String loc) async {
    if (!isTree(loc)) return File(loc).readAsBytes();
    return (await _ch.invokeMethod<Uint8List>('read', _args(loc)))!;
  }

  static Future<String> readString(String loc) async =>
      utf8.decode(await readBytes(loc), allowMalformed: true);

  /// Text lesen, null wenn die Datei fehlt oder nicht lesbar ist.
  static Future<String?> tryReadString(String loc) async {
    try {
      if (!await exists(loc)) return null;
      return await readString(loc);
    } catch (_) {
      return null;
    }
  }

  /// Gibt dem Zig-Kern einen Pfad zum Lesen: den Pfad selbst oder unter
  /// Android einen geöffneten Deskriptor `fd:N:<name>`.
  static Future<T> withReadPath<T>(
    String loc,
    Future<T> Function(String path) body,
  ) async {
    if (!isTree(loc)) return body(loc);
    final fds = await openFds(split(loc).$1, [split(loc).$2]);
    if (fds.first < 0) throw FileSystemException('nicht lesbar', loc);
    try {
      return await body('fd:${fds.first}:${split(loc).$2}');
    } finally {
      await closeFds(fds);
    }
  }

  /// Öffnet mehrere Dateien einer Freigabe zum Lesen (-1 = fehlgeschlagen).
  static Future<List<int>> openFds(String tree, List<String> rels) async =>
      (await _ch.invokeListMethod<int>('openFds', {
        'tree': tree,
        'rels': rels,
        'mode': 'r',
      }))!;

  static Future<void> closeFds(List<int> fds) =>
      _ch.invokeMethod('closeFds', {'fds': fds});

  /// Kopiert [loc] nach [path] (lokale Datei).
  static Future<void> copyOut(String loc, String path) async {
    if (!isTree(loc)) {
      await File(path).parent.create(recursive: true);
      await File(loc).copy(path);
      return;
    }
    await _ch.invokeMethod('copyOut', _args(loc, {'path': path}));
  }

  // ─── Schreiben ────────────────────────────────────────────────────────

  /// Schreibt [data] nach [loc] (legt fehlende Ordner an).
  static Future<void> writeBytes(String loc, List<int> data) async {
    if (!isTree(loc)) {
      final f = File(loc);
      await f.parent.create(recursive: true);
      final tmp = File('$loc.mync-tmp');
      await tmp.writeAsBytes(data, flush: true);
      await tmp.rename(loc);
      return;
    }
    await _ch.invokeMethod(
      'write',
      _args(loc, {'data': Uint8List.fromList(data)}),
    );
  }

  static Future<void> writeString(String loc, String s) =>
      writeBytes(loc, utf8.encode(s));

  /// Kopiert die lokale Datei [path] nach [loc] (ersetzt den Inhalt).
  static Future<void> copyIn(String path, String loc) async {
    if (!isTree(loc)) {
      await File(loc).parent.create(recursive: true);
      await File(path).copy(loc);
      return;
    }
    await _ch.invokeMethod('copyIn', _args(loc, {'path': path}));
  }

  /// Gibt dem Zig-Kern einen Pfad zum Ändern der Datei: den Pfad selbst,
  /// unter Android eine Arbeitskopie im Cache, die danach zurückgeschrieben
  /// wird (nur wenn [body] ohne Fehler endet).
  static Future<T> withWritePath<T>(
    String loc,
    Future<T> Function(String path) body,
  ) async {
    if (!isTree(loc)) return body(loc);
    final name = split(loc).$2.split('/').last;
    final dir = await Directory('$tempDir/mync-edit').create(recursive: true);
    final tmp = '${dir.path}/${DateTime.now().microsecondsSinceEpoch}-$name';
    try {
      await copyOut(loc, tmp);
      final r = await body(tmp);
      await copyIn(tmp, loc);
      return r;
    } finally {
      try {
        await File(tmp).delete();
      } catch (_) {}
    }
  }

  /// Benennt um oder verschiebt (legt Zielordner an). Fehler, wenn das Ziel
  /// schon existiert (außer bei reiner Änderung der Groß-/Kleinschreibung).
  static Future<void> rename(String from, String to) async {
    if (!isTree(from)) {
      await File(to).parent.create(recursive: true);
      if (await File(to).exists() && from.toLowerCase() != to.toLowerCase()) {
        throw FileSystemException('Ziel existiert schon', to);
      }
      await File(from).rename(to);
      return;
    }
    final (tree, rel) = split(from);
    final (tree2, rel2) = split(to);
    if (tree != tree2) {
      throw FileSystemException('Verschieben zwischen Ordnern', to);
    }
    await _ch.invokeMethod('rename', {'tree': tree, 'rel': rel, 'to': rel2});
  }

  static Future<void> delete(String loc) async {
    if (!isTree(loc)) {
      final t = FileSystemEntity.typeSync(loc);
      if (t == FileSystemEntityType.directory) {
        await Directory(loc).delete();
      } else if (t != FileSystemEntityType.notFound) {
        await File(loc).delete();
      }
      return;
    }
    await _ch.invokeMethod('delete', _args(loc));
  }

  static Future<void> mkdirs(String loc) async {
    if (!isTree(loc)) {
      await Directory(loc).create(recursive: true);
      return;
    }
    await _ch.invokeMethod('mkdirs', _args(loc));
  }
}
