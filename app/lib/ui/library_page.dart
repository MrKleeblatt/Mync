import 'package:flutter/material.dart';

import '../core/music_fs.dart';
import 'folder_picker.dart';
import 'global_shortcuts.dart';
import 'scope.dart';
import 'status_line.dart';
import 'track_actions.dart';
import 'track_list.dart';

/// Ordner: die Musikordner zum Durchblättern, plus Suche.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage> {
  final _search = TextEditingController();
  final searchFocus = FocusNode();
  final _folderKey = GlobalKey<FolderViewState>();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void focusSearch() => searchFocus.requestFocus();

  /// Zurücktaste: erst die Suche schließen, dann Ordner für Ordner nach
  /// oben. false, wenn nichts mehr zurückzugehen ist.
  bool handleBack() {
    if (_query.isNotEmpty) {
      _search.clear();
      setState(() => _query = '');
      return true;
    }
    return _folderKey.currentState?.goUp() ?? false;
  }

  Future<void> _scan() async {
    if (context.settings.musicDir.isEmpty) return _pickFolder();
    await context.library.refresh();
  }

  Future<void> _pickFolder() async {
    final s = context.settings;
    final old = s.musicDir;
    final path = await pickMusicFolder(
      initial: old,
      confirm: 'Musikordner wählen',
    );
    if (path == null || path == old) return;
    await s.setMusicDir(path);
    if (!s.extraMusicDirs.contains(old)) await MusicFs.release(old);
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.library;
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
                      hintText: 'Suche${keyHint('Strg+F')}',
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
                    tooltip: 'Einlesen',
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
            if (lib.scanning) _ScanStatus(progress: lib.scanProgress),
            if (lib.status != null && !lib.scanning)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: StatusLine(lib.status, dense: true),
                ),
              ),
            if (lib.hashProgress case (final done, final total)
                when !lib.scanning)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
                child: Tooltip(
                  message: 'Prüfsummen für den Sync',
                  child: Row(
                    children: [
                      SizedBox(
                        width: 80,
                        child: LinearProgressIndicator(
                          value: total == 0 ? null : done / total,
                          minHeight: 2,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Prüfsummen für den Sync: $done / $total',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            if (_query.isNotEmpty)
              Expanded(
                child: _SearchResults(
                  query: _query,
                  onOpenFolder: (f) {
                    _search.clear();
                    setState(() => _query = '');
                    _folderKey.currentState?.open(f);
                  },
                ),
              )
            else
              Expanded(
                child: !lib.loaded
                    ? const Center(child: CircularProgressIndicator())
                    : lib.tracks.isEmpty
                    ? _EmptyLibrary(onScan: _scan, onPick: _pickFolder)
                    : FolderView(key: _folderKey),
              ),
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
          if (context.settings.musicDir.isNotEmpty)
            Text(folderLabel(context.settings.musicDir)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onPick,
                icon: const Icon(Icons.folder_open),
                label: const Text('Ordner wählen'),
              ),
              if (context.settings.musicDir.isNotEmpty)
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
            _SectionTitle('Ordner (${folders.length})', Icons.folder_outlined),
            for (final f in folders)
              GestureDetector(
                onSecondaryTapUp: (d) => showTrackMenu(
                  context,
                  lib.tracksBelow(f),
                  actions: groupActions,
                  title: f.split('/').last,
                ),
                child: ListTile(
                  leading: const Icon(Icons.folder),
                  title: Text(f.split('/').last),
                  subtitle: Text(f),
                  onTap: () => onOpenFolder(f),
                ),
              ),
          ],
          if (tracks.isNotEmpty)
            _SectionTitle(
              'Titel (${tracks.length})',
              Icons.music_note_outlined,
            ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, this.icon);
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 6),
        Text(text, style: Theme.of(context).textTheme.titleSmall),
      ],
    ),
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

  /// Zurücktaste: einen Ordner nach oben; false im Musikordner selbst.
  bool goUp() {
    if (_folder.isEmpty) return false;
    final i = _folder.lastIndexOf('/');
    setState(() => _folder = i < 0 ? '' : _folder.substring(0, i));
    return true;
  }

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
              actions: groupActions,
              title: name,
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
                    title: name,
                  ),
                ),
              ),
            ),
          ),
        if (subs.isNotEmpty && tracks.isNotEmpty) const Divider(),
      ],
    );
    return TrackListView(tracks: tracks, header: header, tapOpensMenu: true);
  }

  String _join(String name) => _folder.isEmpty ? name : '$_folder/$name';
}

class _ScanStatus extends StatelessWidget {
  const _ScanStatus({required this.progress});
  final (int, int, int) progress;

  @override
  Widget build(BuildContext context) {
    final (found, total, done) = progress;
    final theme = Theme.of(context);
    final text = total == 0 ? 'Suche … $found' : 'Lese ein … $done / $total';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: total == 0 ? null : done / total,
            minHeight: 3,
          ),
        ],
      ),
    );
  }
}
