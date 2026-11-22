import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../core/mync_core.dart';
import '../core/music_fs.dart';
import '../log.dart';
import '../settings.dart';
import 'track.dart';

/// Die Musikbibliothek: liest das Manifest über den Zig-Kern, liefert
/// Ordner- und Titelansichten, Suche und Cover.
class Library extends ChangeNotifier {
  Library(this.settings) {
    settings.addListener(_onSettings);
  }

  final AppSettings settings;

  List<Track> _all = const [];
  Map<String, Track> _byPath = const {};
  Map<String, Track> _byId = const {};
  bool scanning = false;

  /// Fortschritt des laufenden Scans: gefunden, davon neu einzulesen, fertig.
  (int found, int total, int done) scanProgress = (0, 0, 0);
  void _onScanProgress(int found, int total, int done) {
    scanProgress = (found, total, done);
    notifyListeners();
  }

  bool loaded = false;

  /// Audio-Hashes im Hintergrund (nur für den Sync): (fertig, gesamt);
  /// null, wenn gerade nichts zu tun ist.
  (int done, int total)? hashProgress;
  Future<void>? _hashing;

  /// Zustand des letzten Ladens/Einlesens (Details im Logbuch).
  OpStatus? status;

  /// Wird bei erkannten Umbenennungen aufgerufen (alter → neuer Pfad).
  void Function(Map<String, String> renames)? onRenamed;

  /// Hauptordner: seine Titel liegen direkt in der Wurzel der Bibliothek.
  String get root => settings.musicDir;

  /// Weitere Musikordner mit dem Ordnernamen, unter dem sie erscheinen.
  List<LibraryRoot> get extraRoots => _extra;
  List<LibraryRoot> _extra = const [];

  /// Präfix des Musikordners, in dem [rel] liegt ('' = Hauptordner).
  String rootPrefixOf(String rel) {
    for (final r in _extra) {
      if (rel == r.prefix || rel.startsWith('${r.prefix}/')) return r.prefix;
    }
    return '';
  }

  /// Wird erhöht, wenn Lyrics gespeichert wurden (Ansichten laden neu).
  int lyricsVersion = 0;
  void lyricsChanged() {
    lyricsVersion++;
    notifyListeners();
  }

  /// Absoluter Pfad zu einem Bibliothekspfad.
  String abs(String rel) {
    for (final r in _extra) {
      if (rel == r.prefix) return r.dir;
      if (rel.startsWith('${r.prefix}/')) {
        return '${r.dir}/${rel.substring(r.prefix.length + 1)}';
      }
    }
    return '$root/$rel';
  }

  int _hide = 0;
  String _config = '';

  String get _currentConfig => jsonEncode([
    settings.musicDir,
    settings.extraMusicDirs,
    settings.excludes,
  ]);

  void _onSettings() {
    if (settings.hideShorterThan != _hide) {
      _hide = settings.hideShorterThan;
      _rebuild();
      notifyListeners();
    }
    if (_currentConfig != _config) {
      _config = _currentConfig;
      _coverCache.clear();
      unawaited(refresh());
    }
  }

  /// Ordnet weiteren Musikordnern eindeutige Namen zu (kollidiert ein Name
  /// mit einem Ordner im Hauptordner oder einem anderen, wird „ (2)“ angehängt).
  Future<void> _computeRoots() async {
    final used = <String>{};
    try {
      if (root.isNotEmpty) {
        for (final e in await MusicFs.list(root)) {
          if (e.isDir) used.add(e.name);
        }
      }
    } catch (_) {}
    final out = <LibraryRoot>[];
    for (final d in settings.extraMusicDirs) {
      final clean = d.endsWith('/') && d.length > 1
          ? d.substring(0, d.length - 1)
          : d;
      if (clean == root) continue;
      final base =
          MusicFs.describe(clean)
              .split('/')
              .where((s) => s.isNotEmpty)
              .lastOrNull ??
          'Ordner';
      var name = base;
      for (var i = 2; used.contains(name); i++) {
        name = '$base ($i)';
      }
      used.add(name);
      out.add(LibraryRoot(name, clean, settings.manifestDbFor(clean)));
    }
    _extra = out;
  }

  /// Liest alle Manifeste und setzt die Präfixe der weiteren Ordner.
  Future<List<Track>> _listAll() async {
    final out = <Track>[
      if (root.isNotEmpty)
        for (final i in await listTracks(root: root, db: settings.manifestDb))
          Track(i),
    ];
    for (final r in _extra) {
      if (!File(r.db).existsSync()) continue;
      try {
        for (final i in await listTracks(root: r.dir, db: r.db)) {
          out.add(Track(i, prefix: r.prefix));
        }
      } catch (_) {}
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// Alle sichtbaren Titel (ggf. ohne sehr kurze Dateien).
  List<Track> get tracks => _visible;
  List<Track> _visible = const [];
  Track? byPath(String rel) => _byPath[rel];
  Track? byFileId(String id) => id.isEmpty ? null : _byId[id];

  /// Lädt das Manifest (ohne Scan).
  Future<void> load() async {
    _config = _currentConfig;
    _hide = settings.hideShorterThan;
    await _computeRoots();
    try {
      _set(await _listAll());
      logInfo('Bibliothek geladen: ${_all.length} Titel');
    } catch (e, st) {
      logError('Bibliothek laden fehlgeschlagen', e, st);
      status = const OpStatus.error('Laden fehlgeschlagen');
    }
    loaded = true;
    notifyListeners();
    // offene Prüfsummen vom letzten Mal – aber nicht vor einem Scan beim
    // Start (der startet gleich danach und hätte sonst zu warten)
    if (!settings.scanOnStart) unawaited(ensureHashed());
  }

  /// Scannt den Musikordner und lädt danach neu.
  Future<ScanSummary?> refresh() async {
    if (scanning) return null;
    if (root.isEmpty) {
      status = const OpStatus.error('Kein Ordner');
      notifyListeners();
      return null;
    }
    // vor dem ersten await sperren, sonst laufen zwei Scans gleichzeitig
    scanning = true;
    if (!await _rootReadable(root)) {
      logWarning('Musikordner nicht gefunden: ${MusicFs.describe(root)}');
      scanning = false;
      status = const OpStatus.error('Ordner fehlt');
      notifyListeners();
      return null;
    }
    status = const OpStatus.busy('Lese ein …');
    logInfo('Einlesen gestartet: $root');
    final watch = Stopwatch()..start();
    notifyListeners();
    try {
      await _computeRoots();
      final before = {for (final t in _all) t.fileId: t.path};
      scanProgress = (0, 0, 0);
      final r = await _scan(root, settings.manifestDb);
      var total = r.total, hashed = r.hashed;
      var added = r.added, removed = r.removed;
      final errors = [...r.errors];
      final missing = <String>[];
      for (final x in _extra) {
        if (!await _rootReadable(x.dir)) {
          missing.add(MusicFs.describe(x.dir));
          continue;
        }
        try {
          final s = await _scan(x.dir, x.db);
          total += s.total;
          hashed += s.hashed;
          added += s.added;
          removed += s.removed;
          errors.addAll(s.errors);
        } catch (e, st) {
          logError('Einlesen von ${x.dir} fehlgeschlagen', e, st);
          errors.add('${x.dir}: $e');
        }
      }
      final tracks = await _listAll();
      final renames = <String, String>{};
      for (final t in tracks) {
        final old = before[t.fileId];
        if (old != null && old != t.path) renames[old] = t.path;
      }
      _set(tracks);
      if (renames.isNotEmpty) onRenamed?.call(renames);
      for (final e in errors) {
        logWarning('Nicht lesbar: $e');
      }
      for (final m in missing) {
        logWarning('Weiterer Musikordner nicht gefunden: $m');
      }
      final summary = '$total Dateien · +$added · −$removed';
      logInfo(
        'Einlesen fertig in ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s: '
        '$summary, $hashed neu eingelesen, ${errors.length} Fehler',
      );
      unawaited(ensureHashed());
      status = errors.isEmpty && missing.isEmpty
          ? OpStatus.ok(summary)
          : OpStatus.error(
              '$summary · ${errors.length + missing.length} nicht lesbar',
            );
      return ScanSummary(
        total: total,
        hashed: hashed,
        added: added,
        removed: removed,
        errors: errors,
      );
    } catch (e, st) {
      logError('Einlesen fehlgeschlagen', e, st);
      status = const OpStatus.error('Fehlgeschlagen');
      return null;
    } finally {
      scanning = false;
      loaded = true;
      notifyListeners();
    }
  }

  /// Berechnet fehlende Audio-Hashes (der Scan liest nur Tags und Dauer).
  /// Läuft im Hintergrund nach jedem Scan; der Sync wartet darauf.
  Future<void> ensureHashed() => _hashing ??= _hashAll().whenComplete(() {
    _hashing = null;
    hashProgress = null;
    notifyListeners();
  });

  /// Wiederholt, bis nichts mehr offen ist – kommen während des
  /// Nachberechnens neue Dateien hinzu (Scan), werden sie mit erfasst.
  Future<void> _hashAll() async {
    for (var round = 0; round < 5; round++) {
      if (!await _hashRound()) return;
    }
  }

  /// Eine Runde; true, wenn etwas berechnet wurde (dann noch eine Runde).
  Future<bool> _hashRound() async {
    final roots = [
      if (root.isNotEmpty) (root, settings.manifestDb),
      for (final r in _extra) (r.dir, r.db),
    ];
    final todo = <(String, String, List<String>)>[];
    for (final (dir, db) in roots) {
      if (!File(db).existsSync()) continue;
      try {
        final p = await pendingHashes(db);
        if (p.isNotEmpty) todo.add((dir, db, p));
      } catch (e, st) {
        logError('Offene Prüfsummen nicht lesbar', e, st);
      }
    }
    final total = todo.fold(0, (n, t) => n + t.$3.length);
    if (total == 0) return false;
    logInfo('Prüfsummen für den Sync: $total Dateien im Hintergrund');
    final watch = Stopwatch()..start();
    var done = 0, failed = 0;
    hashProgress = (0, total);
    notifyListeners();
    // kleine Portionen: jede hält den Kern so lange, wie sie ganze Dateien
    // liest – ein Scan soll dazwischen drankommen
    const batch = 8;
    for (final (dir, db, paths) in todo) {
      final tree = MusicFs.isTree(dir);
      for (var i = 0; i < paths.length; i += batch) {
        // Einlesen hat Vorrang
        while (scanning) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        final part = paths.sublist(i, min(i + batch, paths.length));
        final fds = tree ? await MusicFs.openFds(dir, part) : const <int>[];
        try {
          final items = <String, String>{
            for (var k = 0; k < part.length; k++)
              if (!tree)
                part[k]: '$dir/${part[k]}'
              else if (fds[k] >= 0)
                part[k]: 'fd:${fds[k]}:${part[k]}',
          };
          final (n, errors) = await fillHashes(db, items);
          failed += part.length - n;
          for (final e in errors) {
            logWarning('Prüfsumme nicht berechnet: $e');
          }
        } catch (e, st) {
          failed += part.length;
          logError('Prüfsummen fehlgeschlagen', e, st);
        } finally {
          if (fds.isNotEmpty) await MusicFs.closeFds(fds);
        }
        done += part.length;
        hashProgress = (done, total);
        notifyListeners();
      }
    }
    logInfo(
      'Prüfsummen fertig in ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s'
      '${failed > 0 ? ', $failed fehlgeschlagen' : ''}',
    );
    return failed < total;
  }

  /// Während des Einlesens das schon Gelesene zeigen (höchstens alle 2 s).
  final _partialWatch = Stopwatch();
  Future<void> _showPartial() async {
    if (_partialWatch.isRunning && _partialWatch.elapsedMilliseconds < 2000) {
      return;
    }
    _partialWatch
      ..reset()
      ..start();
    try {
      _set(await _listAll());
      notifyListeners();
    } catch (_) {}
  }

  Future<bool> _rootReadable(String dir) async {
    try {
      return await MusicFs.isDir(dir);
    } catch (e) {
      logWarning('Kein Zugriff auf ${MusicFs.describe(dir)}: $e');
      return false;
    }
  }

  /// Ordner (Linux) oder Ordnerfreigabe (Android) einlesen.
  Future<ScanSummary> _scan(String dir, String db) => MusicFs.isTree(dir)
      ? scanTree(
          tree: dir,
          db: db,
          excludes: settings.excludes,
          onProgress: _onScanProgress,
          onBatch: _showPartial,
        )
      : scanLibrary(
          root: dir,
          db: db,
          excludes: settings.excludes,
          onProgress: _onScanProgress,
        );

  void _set(List<Track> all) {
    _all = all;
    _byPath = {for (final t in all) t.path: t};
    _byId = {for (final t in all) t.fileId: t};
    _rebuild();
  }

  void _rebuild() {
    final minMs = settings.hideShorterThan * 1000;
    _visible = minMs <= 0
        ? _all
        : _all
              .where((t) => t.info.durationMs < 0 || t.info.durationMs >= minMs)
              .toList();
  }

  // ─── Ordner ────────────────────────────────────────────────────────────

  /// Unterordner direkt unter [folder] ('' = Wurzel), mit Anzahl Titel.
  List<(String name, int count)> subfolders(String folder) {
    final prefix = folder.isEmpty ? '' : '$folder/';
    final counts = <String, int>{};
    for (final t in _visible) {
      if (!t.path.startsWith(prefix)) continue;
      final rest = t.path.substring(prefix.length);
      final i = rest.indexOf('/');
      if (i < 0) continue;
      final name = rest.substring(0, i);
      counts[name] = (counts[name] ?? 0) + 1;
    }
    return counts.entries.map((e) => (e.key, e.value)).toList()
      ..sort((a, b) => compareText(a.$1, b.$1));
  }

  /// Titel direkt in [folder], nach Dateiname sortiert.
  List<Track> tracksIn(String folder) =>
      _visible.where((t) => t.folder == folder).toList()
        ..sort((a, b) => compareText(a.fileName, b.fileName));

  /// Alle Titel in [folder] und darunter.
  List<Track> tracksBelow(String folder) {
    final prefix = folder.isEmpty ? '' : '$folder/';
    return _visible.where((t) => t.path.startsWith(prefix)).toList()
      ..sort((a, b) => compareText(a.path, b.path));
  }

  // ─── Suche ─────────────────────────────────────────────────────────────

  List<Track> search(String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return const [];
    return _visible.where((t) => words.every(t.searchText.contains)).toList()
      ..sort((a, b) => compareText(a.title, b.title));
  }

  /// Ordner, deren Pfad alle Suchwörter enthält (kürzeste zuerst).
  List<String> searchFolders(String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return const [];
    final folders = <String>{};
    for (final t in _visible) {
      var f = t.folder;
      while (f.isNotEmpty && folders.add(f)) {
        final i = f.lastIndexOf('/');
        f = i < 0 ? '' : f.substring(0, i);
      }
    }
    final hits = folders.where((f) {
      final l = f.toLowerCase();
      return words.every(l.contains);
    }).toList();
    hits.sort((a, b) {
      final c = a.length.compareTo(b.length);
      return c != 0 ? c : compareText(a, b);
    });
    return hits;
  }

  // ─── Cover ─────────────────────────────────────────────────────────────

  final Map<String, Future<String?>> _coverCache = {};

  /// Wird bei jeder Cover-Änderung erhöht (Widgets laden dann neu).
  int coverVersion = 0;
  static const _folderCovers = [
    'cover',
    'folder',
    'front',
    'album',
    'albumart',
  ];
  static const _imageExt = ['jpg', 'jpeg', 'png', 'webp'];

  /// Pfad zu einem Coverbild für [t] (eingebettet oder `cover.jpg` im Ordner).
  Future<String?> coverFor(Track t) =>
      _coverCache.putIfAbsent(t.albumKey + t.folder, () => _findCover(t));

  Future<String?> _findCover(Track t) async {
    // 1. Eingebettetes Cover (in den Cache extrahiert)
    final out = _coverCachePath(t);
    if (File(out).existsSync()) return out;
    try {
      if (await MusicFs.withReadPath(
        abs(t.path),
        (p) => extractCover(p, out),
      )) {
        return out;
      }
    } catch (_) {}
    // 2. Bilddatei im Ordner
    final dir = abs(t.folder);
    try {
      final names = [
        for (final c in await MusicFs.list(dir))
          if (!c.isDir) c.name,
      ];
      String? pick;
      for (final base in _folderCovers) {
        pick ??= names
            .where((n) => _imageExt.any((e) => n.toLowerCase() == '$base.$e'))
            .firstOrNull;
      }
      pick ??= names
          .where((n) => _imageExt.any((e) => n.toLowerCase().endsWith('.$e')))
          .firstOrNull;
      if (pick == null) return null;
      final loc = '$dir/$pick';
      if (!MusicFs.isTree(loc)) return loc;
      // Ordnerfreigabe: Bild in den Cache holen (Image.file, Benachrichtigung)
      await MusicFs.copyOut(loc, out);
      return out;
    } catch (_) {}
    return null;
  }

  /// Nach dem Bearbeiten von Tags: Cover-Cache für die Datei verwerfen.
  /// Nach dem Ändern eines Covers: Cache-Datei und Bild-Cache verwerfen.
  void invalidateCover(Track t) {
    coverVersion++;
    _coverCache.remove(t.albumKey + t.folder);
    final f = File(_coverCachePath(t));
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    // auch verkleinerte Varianten (cacheWidth) verwerfen
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }

  String _coverCachePath(Track t) {
    final id = base64Url.encode(utf8.encode(t.path)).replaceAll('=', '');
    final short = id.length > 100 ? id.substring(id.length - 100) : id;
    return '${settings.cacheDir}/covers/$short.img';
  }

  @override
  void dispose() {
    settings.removeListener(_onSettings);
    super.dispose();
  }
}

/// Ein weiterer Musikordner: erscheint in der Bibliothek als Ordner [prefix].
class LibraryRoot {
  const LibraryRoot(this.prefix, this.dir, this.db);
  final String prefix;
  final String dir;
  final String db;
}
