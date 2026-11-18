import 'dart:convert';
import 'dart:io';

import '../settings.dart';

/// Inhalt eines Backups (zur Anzeige vor dem Wiederherstellen).
class BackupInfo {
  BackupInfo(this.created, this.files, this.prefCount, this.hasPairings);
  final DateTime created;
  final List<String> files;
  final int prefCount;
  final bool hasPairings;
}

/// Sichert Einstellungen, Warteschlangen, Hörprotokoll und (optional) die
/// Kopplungen in eine Datei `.mync-backup` (gzip-komprimiertes JSON).
/// Die Musikdateien und das Manifest gehören nicht dazu – das Manifest
/// entsteht beim nächsten Einlesen neu.
class Backup {
  static const extension = 'mync-backup';

  /// Dateien unter dem Datenordner, die gesichert werden.
  static List<File> _files(String dataDir, {required bool pairings}) {
    final out = <File>[
      File('$dataDir/state.json'),
      File('$dataDir/history.jsonl'),
    ];
    final sync = Directory('$dataDir/sync');
    if (pairings && sync.existsSync()) {
      out.addAll(
        sync.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.json'),
        ),
      );
    }
    return out.where((f) => f.existsSync()).toList();
  }

  static Future<File> create(
    AppSettings settings,
    String outPath, {
    bool pairings = true,
  }) async {
    final dataDir = settings.dataDir;
    final files = <String, String>{};
    for (final f in _files(dataDir, pairings: pairings)) {
      final rel = f.path.substring(dataDir.length + 1);
      files[rel] = base64.encode(await f.readAsBytes());
    }
    final json = jsonEncode({
      'mync_backup': 1,
      'created': DateTime.now().toIso8601String(),
      'prefs': settings.exportPrefs(),
      'files': files,
    });
    final out = File(outPath);
    await out.parent.create(recursive: true);
    await out.writeAsBytes(gzip.encode(utf8.encode(json)), flush: true);
    return out;
  }

  static Future<Map<String, dynamic>> _read(String path) async {
    final bytes = await File(path).readAsBytes();
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(gzip.decode(bytes)));
    } catch (_) {
      throw const FormatException('Keine mync-Sicherung.');
    }
    if (j is! Map<String, dynamic> || j['mync_backup'] != 1) {
      throw const FormatException('Keine mync-Sicherung.');
    }
    return j;
  }

  static Future<BackupInfo> inspect(String path) async {
    final j = await _read(path);
    final files = (j['files'] as Map).keys.cast<String>().toList()..sort();
    return BackupInfo(
      DateTime.tryParse(j['created'] as String? ?? '') ?? DateTime(0),
      files,
      (j['prefs'] as Map).length,
      files.contains('sync/identity.json'),
    );
  }

  /// Stellt alles wieder her. Danach muss die App neu starten.
  static Future<void> restore(
    AppSettings settings,
    String path, {
    bool pairings = true,
  }) async {
    final j = await _read(path);
    final dataDir = settings.dataDir;
    final files = (j['files'] as Map).cast<String, String>();
    for (final e in files.entries) {
      final rel = e.key;
      if (rel.contains('..') || rel.startsWith('/')) continue;
      if (!pairings && rel.startsWith('sync/')) continue;
      final f = File('$dataDir/$rel');
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.restore');
      await tmp.writeAsBytes(base64.decode(e.value), flush: true);
      await tmp.rename(f.path);
    }
    await settings.importPrefs((j['prefs'] as Map).cast<String, dynamic>());
  }
}
