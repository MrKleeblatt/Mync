import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/storage_access.dart';
import '../library/track.dart';
import 'scope.dart';
import 'track_actions.dart';
import 'track_list.dart';

/// Bibliothek: Ordner (Hauptansicht) und alle Titel – plus Suche.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _search = TextEditingController();
  final searchFocus = FocusNode();
  final _folderKey = GlobalKey<FolderViewState>();
  String _query = '';

  static const _tabNames = ['Ordner', 'Titel'];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: _tabNames.length,
      vsync: this,
      initialIndex: 0,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tabs.index = context.settings.libraryTab.clamp(0, _tabNames.length - 1);
      _tabs.addListener(() => context.settings.setLibraryTab(_tabs.index));
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void focusSearch() => searchFocus.requestFocus();

  Future<void> _scan() async {
    if (!await StorageAccess.granted()) {
      await StorageAccess.request();
      return;
    }
    if (mounted) await context.library.refresh();
  }

  Future<void> _pickFolder() async {
    final s = context.settings;
    final path = await getDirectoryPath(
      initialDirectory: s.musicDir,
      confirmButtonText: 'Musikordner wählen',
    );
    if (path == null || path.isEmpty) return;
    await s.setMusicDir(path);
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.library;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: lib,
      builder: (context, _) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: SearchBar(
                      controller: _search,
                      focusNode: searchFocus,
                      hintText: 'Bibliothek durchsuchen (Strg+F)',
                      leading: const Icon(Icons.search),
                      trailing: [
                        if (_query.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                          ),
                      ],
                      onChanged: (v) => setState(() => _query = v.trim()),
                      elevation: const WidgetStatePropertyAll(0),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Musikordner wählen',
                    onPressed: lib.scanning ? null : _pickFolder,
                    icon: const Icon(Icons.folder_open),
                  ),
                  IconButton(
                    tooltip: 'Bibliothek neu einlesen',
                    onPressed: lib.scanning ? null : _scan,
                    icon: lib.scanning
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            if (lib.message != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(lib.message!, style: theme.textTheme.bodySmall),
                ),
              ),
            if (_query.isNotEmpty)
              Expanded(
                child: _SearchResults(
                  query: _query,
                  onOpenFolder: (f) {
                    _search.clear();
                    setState(() => _query = '');
                    _tabs.index = 0;
                    _folderKey.currentState?.open(f);
                  },
                ),
              )
            else ...[
              TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [for (final n in _tabNames) Tab(text: n)],
              ),
              Expanded(
                child: !lib.loaded
                    ? const Center(child: CircularProgressIndicator())
                    : lib.tracks.isEmpty
                    ? _EmptyLibrary(onScan: _scan, onPick: _pickFolder)
                    : TabBarView(
                        controller: _tabs,
                        children: [
                          FolderView(key: _folderKey),
                          const AllTracksView(),
                        ],
                      ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onScan, required this.onPick});
  final VoidCallback onScan;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.library_music,
            size: 56,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            'Keine Titel gefunden in',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(context.settings.musicDir),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onPick,
                icon: const Icon(Icons.folder_open),
                label: const Text('Ordner wählen'),
              ),
              FilledButton.icon(
                onPressed: onScan,
                icon: const Icon(Icons.refresh),
                label: const Text('Einlesen'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.query, required this.onOpenFolder});
  final String query;
  final ValueChanged<String> onOpenFolder;

  @override
  Widget build(BuildContext context) {
    final lib = context.library;
    final tracks = lib.search(query);
    final folders = lib.searchFolders(query).take(20).toList();
    if (tracks.isEmpty && folders.isEmpty) {
      return const Center(child: Text('Keine Treffer'));
    }
    return TrackListView(
      tracks: tracks,
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (folders.isNotEmpty) ...[
            _SectionTitle('Ordner (${folders.length})'),
            for (final f in folders)
              GestureDetector(
                onSecondaryTapUp: (d) => showTrackMenu(
                  context,
                  lib.tracksBelow(f),
                  position: d.globalPosition,
                  actions: groupActions,
                ),
                child: ListTile(
                  leading: const Icon(Icons.folder),
                  title: Text(f.split('/').last),
                  subtitle: Text(f),
                  onTap: () => onOpenFolder(f),
                ),
              ),
          ],
          if (tracks.isNotEmpty) _SectionTitle('Titel (${tracks.length})'),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

// ─── Ordner ──────────────────────────────────────────────────────────────

class FolderView extends StatefulWidget {
  const FolderView({super.key});

  @override
  State<FolderView> createState() => FolderViewState();
}

class FolderViewState extends State<FolderView>
    with AutomaticKeepAliveClientMixin {
  String _folder = '';

  /// Öffnet einen Ordner (z. B. aus der Suche).
  void open(String folder) => setState(() => _folder = folder);

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    // Eigene Abhängigkeit von der Bibliothek: const-Widgets werden sonst nicht neu gebaut
    super.build(context);
    return ListenableBuilder(
      listenable: context.library,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final lib = context.library;
    final subs = lib.subfolders(_folder);
    final tracks = lib.tracksIn(_folder);
    final parts = _folder.isEmpty ? <String>[] : _folder.split('/');
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Brotkrumen
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: () => setState(() => _folder = ''),
                icon: const Icon(Icons.home, size: 18),
                label: const Text('Musik'),
              ),
              for (var i = 0; i < parts.length; i++) ...[
                const Icon(Icons.chevron_right, size: 18),
                TextButton(
                  onPressed: () => setState(
                    () => _folder = parts.sublist(0, i + 1).join('/'),
                  ),
                  child: Text(parts[i]),
                ),
              ],
            ],
          ),
        ),
        if (_folder.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('..'),
            onTap: () => setState(
              () => _folder = parts.length <= 1
                  ? ''
                  : parts.sublist(0, parts.length - 1).join('/'),
            ),
          ),
        for (final (name, count) in subs)
          GestureDetector(
            onSecondaryTapUp: (d) => showTrackMenu(
              context,
              lib.tracksBelow(_join(name)),
              position: d.globalPosition,
              actions: groupActions,
            ),
            child: ListTile(
              leading: const Icon(Icons.folder),
              title: Text(name),
              subtitle: Text('$count Titel'),
              onTap: () => setState(() => _folder = _join(name)),
              trailing: Builder(
                builder: (c) => IconButton(
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => showTrackMenu(
                    c,
                    lib.tracksBelow(_join(name)),
                    actions: groupActions,
                  ),
                ),
              ),
            ),
          ),
        if (subs.isNotEmpty && tracks.isNotEmpty) const Divider(),
      ],
    );
    return TrackListView(tracks: tracks, header: header);
  }

  String _join(String name) => _folder.isEmpty ? name : '$_folder/$name';
}

// ─── Alle Titel ──────────────────────────────────────────────────────────

class AllTracksView extends StatefulWidget {
  const AllTracksView({super.key});

  @override
  State<AllTracksView> createState() => _AllTracksViewState();
}

class _AllTracksViewState extends State<AllTracksView> {
  static const sorts = {
    'title': 'Titel',
    'artist': 'Künstler',
    'album': 'Album',
    'year': 'Jahr',
    'duration': 'Dauer',
    'added': 'Zuletzt hinzugefügt',
    'file': 'Dateiname',
  };

  @override
  Widget build(BuildContext context) {
    // Eigene Abhängigkeit von der Bibliothek: const-Widgets werden sonst nicht neu gebaut
    return ListenableBuilder(
      listenable: context.library,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final s = context.settings;
    final sort = sorts.containsKey(s.trackSort) ? s.trackSort : 'title';
    final tracks = context.library.sortedTracks(sort);
    return TrackListView(
      tracks: tracks,
      header: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
        child: Row(
          children: [
            Text(
              '${tracks.length} Titel · ${formatDuration(tracks.fold(Duration.zero, (a, t) => a + t.duration))}',
            ),
            const Spacer(),
            PopupMenuButton<String>(
              tooltip: 'Sortieren',
              initialValue: sort,
              onSelected: (v) async {
                await s.setTrackSort(v);
                setState(() {});
              },
              itemBuilder: (_) => [
                for (final e in sorts.entries)
                  PopupMenuItem(value: e.key, child: Text(e.value)),
              ],
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    const Icon(Icons.sort),
                    const SizedBox(width: 4),
                    Text(sorts[sort]!),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
