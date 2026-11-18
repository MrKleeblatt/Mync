import 'package:flutter/material.dart';

import '../library/playlists.dart';
import '../library/track.dart';
import 'now_playing.dart';
import 'scope.dart';
import 'track_actions.dart';
import 'track_list.dart';

/// Playlists (`Playlists/*.m3u8`) und automatische Listen.
class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = context.library;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: lib,
      builder: (context, _) => FutureBuilder<List<String>>(
        future: lib.playlists.names(),
        builder: (context, snap) {
          final names = snap.data ?? const [];
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                child: Row(
                  children: [
                    Text('Playlists', style: theme.textTheme.headlineSmall),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Neue Playlist',
                      onPressed: () async {
                        final n = await askText(
                          context,
                          title: 'Neue Playlist',
                          label: 'Name',
                        );
                        if (n != null) {
                          await lib.playlists.write(n, []);
                          lib.playlistsChanged();
                        }
                      },
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
              ),
              _AutoTile(
                icon: Icons.new_releases,
                title: 'Zuletzt hinzugefügt',
                load: () => lib.sortedTracks('added').take(200).toList(),
              ),
              _AutoTile(
                icon: Icons.trending_up,
                title: 'Meistgespielt',
                load: () => _resolve(context, context.player.mostPlayed()),
              ),
              _AutoTile(
                icon: Icons.history,
                title: 'Zuletzt gespielt',
                load: () => _resolve(context, context.player.recentlyPlayed()),
              ),
              const Divider(),
              if (!names.contains(PlaylistStore.favoritesName))
                _PlaylistTile(name: PlaylistStore.favoritesName),
              for (final n in names) _PlaylistTile(name: n),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Gespeichert als .m3u8 in „${lib.playlists.dir.path}“ – wird mit dem Handy synchronisiert.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static List<Track> _resolve(BuildContext context, List<String> paths) =>
      paths.map(context.library.byPath).whereType<Track>().toList();
}

class _AutoTile extends StatelessWidget {
  const _AutoTile({
    required this.icon,
    required this.title,
    required this.load,
  });
  final IconData icon;
  final String title;
  final List<Track> Function() load;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: CircleAvatar(child: Icon(icon)),
    title: Text(title),
    onTap: () => _open(context, title, load, null),
  );
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final lib = context.library;
    final fav = name == PlaylistStore.favoritesName;
    return ListTile(
      leading: CircleAvatar(
        child: Icon(fav ? Icons.favorite : Icons.queue_music),
      ),
      title: Text(name),
      onTap: () async {
        final paths = await lib.playlists.read(name);
        if (!context.mounted) return;
        _open(
          context,
          name,
          () => paths.map(lib.byPath).whereType<Track>().toList(),
          name,
        );
      },
      trailing: fav
          ? null
          : PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'rename') {
                  final n = await askText(
                    context,
                    title: 'Playlist umbenennen',
                    label: 'Name',
                    initial: name,
                  );
                  if (n != null && n != name) {
                    await lib.playlists.rename(name, n);
                  }
                } else if (v == 'delete') {
                  await lib.playlists.delete(name);
                }
                lib.playlistsChanged();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Umbenennen …')),
                PopupMenuItem(value: 'delete', child: Text('Löschen')),
              ],
            ),
    );
  }
}

void _open(
  BuildContext context,
  String title,
  List<Track> Function() load,
  String? playlist,
) {
  final s = MyncScope.of(context);
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MyncScope(
        settings: s.settings,
        library: s.library,
        player: s.player,
        child: _PlaylistPage(title: title, load: load, playlist: playlist),
      ),
    ),
  );
}

class _PlaylistPage extends StatelessWidget {
  const _PlaylistPage({required this.title, required this.load, this.playlist});
  final String title;
  final List<Track> Function() load;
  final String? playlist;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: const PageMiniPlayer(),
      appBar: AppBar(title: Text(title)),
      body: ListenableBuilder(
        listenable: context.library,
        builder: (context, _) {
          final tracks = load();
          return TrackListView(
            tracks: tracks,
            header: GroupHeader(tracks: tracks, title: title),
          );
        },
      ),
    );
  }
}
