import 'dart:io';

/// Playlists als `.m3u8`-Dateien im Ordner `Playlists/` der Musikwurzel.
/// Pfade werden relativ zur Musikwurzel gespeichert (`../Album/Titel.mp3`
/// aus Sicht der Playlist), damit sie auf Handy und PC gleich funktionieren
/// und mit dem Sync wandern.
class PlaylistStore {
  PlaylistStore(this.root);

  final String root;

  static const folderName = 'Playlists';
  static const favoritesName = 'Favoriten';

  Directory get dir => Directory('$root/$folderName');

  File fileFor(String name) => File('${dir.path}/$name.m3u8');

  /// Alle Playlist-Namen (ohne Endung), alphabetisch, Favoriten zuerst.
  Future<List<String>> names() async {
    if (!await dir.exists()) return [];
    final out = <String>[];
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final n = e.uri.pathSegments.last;
      final lower = n.toLowerCase();
      if (lower.endsWith('.m3u8')) {
        out.add(n.substring(0, n.length - 5));
      } else if (lower.endsWith('.m3u')) {
        out.add(n.substring(0, n.length - 4));
      }
    }
    out.sort((a, b) {
      if (a == favoritesName) return -1;
      if (b == favoritesName) return 1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    return out.toSet().toList();
  }

  File _existing(String name) {
    final m3u8 = fileFor(name);
    if (m3u8.existsSync()) return m3u8;
    final m3u = File('${dir.path}/$name.m3u');
    return m3u.existsSync() ? m3u : m3u8;
  }

  /// Liest eine Playlist; liefert Pfade relativ zur Musikwurzel.
  Future<List<String>> read(String name) async {
    final f = _existing(name);
    if (!await f.exists()) return [];
    final text = await f.readAsString();
    return parse(text, playlistDir: f.parent.path, root: root);
  }

  Future<void> write(String name, List<String> relPaths) async {
    await dir.create(recursive: true);
    await fileFor(name).writeAsString(serialize(relPaths));
    final legacy = File('${dir.path}/$name.m3u');
    if (await legacy.exists()) await legacy.delete();
  }

  Future<void> add(String name, List<String> relPaths) async {
    final cur = await read(name);
    await write(name, [...cur, ...relPaths.where((p) => !cur.contains(p))]);
  }

  Future<void> remove(String name, String relPath) async {
    final cur = await read(name);
    await write(name, cur.where((p) => p != relPath).toList());
  }

  Future<void> delete(String name) async {
    final f = _existing(name);
    if (await f.exists()) await f.delete();
  }

  Future<void> rename(String from, String to) async {
    final items = await read(from);
    await write(to, items);
    await delete(from);
  }

  static String serialize(List<String> relPaths) {
    final b = StringBuffer('#EXTM3U\n');
    for (final p in relPaths) {
      b.writeln('../$p');
    }
    return b.toString();
  }

  /// Wandelt Einträge (relativ zur Playlist, relativ zur Wurzel oder absolut)
  /// in Pfade relativ zur Musikwurzel um.
  static List<String> parse(
    String text, {
    required String playlistDir,
    required String root,
  }) {
    final out = <String>[];
    final rootUri = Uri.directory(root);
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final entry = line.replaceAll('\\', '/');
      String abs;
      if (entry.startsWith('/')) {
        abs = entry;
      } else if (entry.startsWith('../') || entry.startsWith('./')) {
        abs = Uri.directory(playlistDir).resolve(entry).toFilePath();
      } else {
        // Ohne Präfix: zuerst relativ zur Playlist, sonst relativ zur Wurzel
        final rel = Uri.directory(playlistDir).resolve(entry).toFilePath();
        abs = File(rel).existsSync()
            ? rel
            : rootUri.resolve(entry).toFilePath();
      }
      final normRoot = rootUri.toFilePath();
      if (abs.startsWith(normRoot)) out.add(abs.substring(normRoot.length));
    }
    return out;
  }
}
