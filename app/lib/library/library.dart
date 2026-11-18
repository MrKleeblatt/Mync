import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/mync_core.dart';
import '../settings.dart';
import 'playlists.dart';
import 'track.dart';

/// Ein Album: gleicher Albumname und gleicher Album-Künstler.
class Album {
  Album(this.key, this.name, this.artist, this.tracks);
  final String key;
  final String name;
  final String artist;
  final List<Track> tracks;

  int? get year => tracks
      .map((t) => t.year)
      .whereType<int>()
      .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
  Duration get duration => tracks.fold(Duration.zero, (a, t) => a + t.duration);
  Track get first => tracks.first;
}

/// Künstler, Genre, Komponist …: Name + Titel.
class Group {
  Group(this.name, this.tracks);
  final String name;
  final List<Track> tracks;
}

/// Die Musikbibliothek: liest das Manifest über den Zig-Kern, baut die
/// Ansichten (Ordner, Alben, Künstler, Genres) und verwaltet Cover,
/// Favoriten und Wiedergabestatistik.
class Library extends ChangeNotifier {
  Library(this.settings) : playlists = PlaylistStore(settings.musicDir) {
    settings.addListener(_onSettings);
  }

  final AppSettings settings;
  PlaylistStore playlists;

  List<Track> _all = const [];
  Map<String, Track> _byPath = const {};
  bool scanning = false;
  bool loaded = false;
  String? message;

  /// Wird bei erkannten Umbenennungen aufgerufen (alter → neuer Pfad).
  void Function(Map<String, String> renames)? onRenamed;

  String get root => settings.musicDir;
  String abs(String rel) => '$root/$rel';

  int _hide = 0;
  String _root = '';

  void _onSettings() {
    if (settings.hideShorterThan != _hide) {
      _hide = settings.hideShorterThan;
      _rebuild();
      notifyListeners();
    }
    if (settings.musicDir != _root) {
      _root = settings.musicDir;
      playlists = PlaylistStore(_root);
      _coverCache.clear();
      unawaited(refresh());
    }
  }

  /// Alle sichtbaren Titel (ggf. ohne sehr kurze Dateien).
  List<Track> get tracks => _visible;
  List<Track> _visible = const [];
  Track? byPath(String rel) => _byPath[rel];

  List<Album> albums = const [];
  List<Group> artists = const [];
  List<Group> albumArtists = const [];
  List<Group> genres = const [];
  List<Group> composers = const [];

  /// Lädt das Manifest (ohne Scan).
  Future<void> load() async {
    _root = settings.musicDir;
    _hide = settings.hideShorterThan;
    try {
      final infos = await listTracks(root: root, db: settings.manifestDb);
      _set(infos.map(Track.new).toList());
    } catch (e) {
      message = 'Fehler beim Laden: $e';
    }
    await _loadFavorites();
    loaded = true;
    notifyListeners();
  }

  /// Scannt den Musikordner und lädt danach neu.
  Future<ScanSummary?> refresh() async {
    if (scanning) return null;
    if (!Directory(root).existsSync()) {
      message = 'Musikordner nicht gefunden: $root';
      notifyListeners();
      return null;
    }
    scanning = true;
    message = null;
    notifyListeners();
    try {
      final before = {for (final t in _all) t.fileId: t.path};
      final r = await scanLibrary(root: root, db: settings.manifestDb);
      final infos = await listTracks(root: root, db: settings.manifestDb);
      final tracks = infos.map(Track.new).toList();
      final renames = <String, String>{};
      for (final t in tracks) {
        final old = before[t.fileId];
        if (old != null && old != t.path) renames[old] = t.path;
      }
      _set(tracks);
      await _loadFavorites();
      if (renames.isNotEmpty) onRenamed?.call(renames);
      message =
          '${r.total} Dateien · ${r.added} neu · ${r.removed} entfernt'
          '${r.errors.isEmpty ? '' : ' · ${r.errors.length} Fehler'}';
      return r;
    } catch (e) {
      message = e is MyncCoreException ? e.userMessage : 'Fehler: $e';
      return null;
    } finally {
      scanning = false;
      loaded = true;
      notifyListeners();
    }
  }

  void _set(List<Track> all) {
    _all = all;
    _byPath = {for (final t in all) t.path: t};
    _rebuild();
  }

  void _rebuild() {
    final minMs = settings.hideShorterThan * 1000;
    _visible = minMs <= 0
        ? _all
        : _all
              .where((t) => t.info.durationMs < 0 || t.info.durationMs >= minMs)
              .toList();

    final byAlbum = <String, List<Track>>{};
    for (final t in _visible) {
      byAlbum.putIfAbsent(t.albumKey, () => []).add(t);
    }
    albums = [
      for (final e in byAlbum.entries)
        Album(
          e.key,
          e.value.first.albumOrUnknown,
          e.value.first.albumArtist,
          e.value..sort(compareAlbumOrder),
        ),
    ]..sort((a, b) => compareText(a.name, b.name));

    artists = _group((t) => t.artists, unknown: 'Unbekannter Künstler');
    albumArtists = _group((t) => [t.albumArtist]);
    genres = _group((t) => t.genres, unknown: 'Ohne Genre');
    composers = _group((t) => t.composers);
  }

  List<Group> _group(List<String> Function(Track) keys, {String? unknown}) {
    final map = <String, List<Track>>{};
    final names = <String, String>{};
    for (final t in _visible) {
      var ks = keys(t);
      if (ks.isEmpty) {
        if (unknown == null) continue;
        ks = [unknown];
      }
      for (final k in ks) {
        final lk = k.toLowerCase();
        names.putIfAbsent(lk, () => k);
        map.putIfAbsent(lk, () => []).add(t);
      }
    }
    return [
      for (final e in map.entries)
        Group(names[e.key]!, e.value..sort(_byAlbumThenOrder)),
    ]..sort((a, b) => compareText(a.name, b.name));
  }

  static int _byAlbumThenOrder(Track a, Track b) {
    final c = compareText(a.albumOrUnknown, b.albumOrUnknown);
    return c != 0 ? c : compareAlbumOrder(a, b);
  }

  /// Alben eines Künstlers.
  List<Album> albumsOf(Group artist) {
    final keys = artist.tracks.map((t) => t.albumKey).toSet();
    return albums.where((a) => keys.contains(a.key)).toList();
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

  // ─── Sortierte Titelliste ─────────────────────────────────────────────

  List<Track> sortedTracks(String sort) {
    final list = [..._visible];
    switch (sort) {
      case 'artist':
        list.sort((a, b) {
          final c = compareText(a.artist, b.artist);
          return c != 0 ? c : _byAlbumThenOrder(a, b);
        });
      case 'album':
        list.sort(_byAlbumThenOrder);
      case 'year':
        list.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
      case 'duration':
        list.sort((a, b) => b.info.durationMs.compareTo(a.info.durationMs));
      case 'added':
        list.sort((a, b) => b.info.addedMs.compareTo(a.info.addedMs));
      case 'file':
        list.sort((a, b) => compareText(a.path, b.path));
      default:
        list.sort((a, b) => compareText(a.title, b.title));
    }
    return list;
  }

  // ─── Favoriten ─────────────────────────────────────────────────────────

  Set<String> favorites = {};

  Future<void> _loadFavorites() async {
    try {
      favorites = (await playlists.read(PlaylistStore.favoritesName)).toSet();
    } catch (_) {
      favorites = {};
    }
  }

  bool isFavorite(String rel) => favorites.contains(rel);

  Future<void> toggleFavorite(String rel) async {
    if (favorites.contains(rel)) {
      favorites.remove(rel);
    } else {
      favorites.add(rel);
    }
    notifyListeners();
    await playlists.write(PlaylistStore.favoritesName, favorites.toList());
  }

  /// Benachrichtigt Ansichten nach Änderungen an Playlists.
  void playlistsChanged() => notifyListeners();

  // ─── Cover ─────────────────────────────────────────────────────────────

  final Map<String, Future<String?>> _coverCache = {};
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
    final id = base64Url.encode(utf8.encode(t.path)).replaceAll('=', '');
    final short = id.length > 100 ? id.substring(id.length - 100) : id;
    final out = '${settings.cacheDir}/covers/$short.img';
    if (File(out).existsSync()) return out;
    try {
      if (await extractCover(abs(t.path), out)) return out;
    } catch (_) {}
    // 2. Bilddatei im Ordner
    final dir = Directory(abs(t.folder));
    try {
      final files = dir.listSync().whereType<File>().toList();
      for (final base in _folderCovers) {
        for (final f in files) {
          final n = f.uri.pathSegments.last.toLowerCase();
          if (_imageExt.any((e) => n == '$base.$e')) return f.path;
        }
      }
      for (final f in files) {
        final n = f.uri.pathSegments.last.toLowerCase();
        if (_imageExt.any((e) => n.endsWith('.$e'))) return f.path;
      }
    } catch (_) {}
    return null;
  }

  /// Nach dem Bearbeiten von Tags: Cover-Cache für die Datei verwerfen.
  void invalidateCover(Track t) => _coverCache.remove(t.albumKey + t.folder);

  @override
  void dispose() {
    settings.removeListener(_onSettings);
    super.dispose();
  }
}
