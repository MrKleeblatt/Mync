import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../settings.dart';
import '../src/rust/api/library.dart';

/// Bibliothek: Musikordner wählen, scannen (Rust-Kern) und Titel anzeigen.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<TrackInfo> _tracks = const [];
  String _query = '';
  bool _busy = false;
  String? _message;

  AppSettings get _s => widget.settings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await listTracks(root: _s.musicDir, db: _s.manifestDb);
      if (mounted) setState(() => _tracks = t);
    } catch (e) {
      if (mounted) setState(() => _message = 'Fehler: $e');
    }
  }

  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return true;
    // Umbenennen, Löschen und Tag-Schreiben brauchen „Zugriff auf alle Dateien“.
    if (await Permission.manageExternalStorage.isGranted) return true;
    final status = await Permission.manageExternalStorage.request();
    return status.isGranted;
  }

  Future<void> _pickFolder() async {
    String? path;
    if (Platform.isAndroid) {
      path = await _askPath();
    } else {
      path = await getDirectoryPath(
        initialDirectory: _s.musicDir,
        confirmButtonText: 'Musikordner wählen',
      );
    }
    if (path == null || path.isEmpty) return;
    await _s.setMusicDir(path);
    setState(() => _tracks = const []);
    await _scan();
  }

  /// Auf Android liefert der System-Dialog keine echten Dateipfade, daher
  /// wird der Pfad hier (vorerst) eingegeben.
  Future<String?> _askPath() {
    final ctrl = TextEditingController(text: _s.musicDir);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Musikordner'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'Pfad',
            hintText: '/storage/emulated/0/Music',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Übernehmen'),
          ),
        ],
      ),
    );
  }

  Future<void> _scan() async {
    if (!await _ensurePermission()) {
      setState(() => _message = 'Ohne Dateizugriff kann nicht gescannt werden.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final r = await scanLibrary(root: _s.musicDir, db: _s.manifestDb);
      await _load();
      setState(() {
        _message = '${r.total} Dateien · ${r.added} neu · ${r.removed} entfernt'
            '${r.errors.isEmpty ? '' : ' · ${r.errors.length} Fehler'}';
      });
    } catch (e) {
      setState(() => _message = 'Fehler: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<TrackInfo> get _filtered {
    if (_query.isEmpty) return _tracks;
    final q = _query.toLowerCase();
    return _tracks.where((t) {
      return [t.title, t.artist, t.album, t.path]
          .any((v) => v != null && v.toLowerCase().contains(q));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tracks = _filtered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text('Bibliothek', style: theme.textTheme.headlineSmall),
              ),
              IconButton(
                tooltip: 'Musikordner wählen',
                onPressed: _busy ? null : _pickFolder,
                icon: const Icon(Icons.folder_open),
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: _busy ? null : _scan,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: const Text('Scannen'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            _s.musicDir,
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SearchBar(
            hintText: 'Titel, Künstler, Album oder Pfad suchen',
            leading: const Icon(Icons.search),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(_message!, style: theme.textTheme.bodySmall),
          ),
        Expanded(
          child: tracks.isEmpty
              ? Center(
                  child: Text(
                    _tracks.isEmpty
                        ? 'Noch keine Titel – Musikordner wählen und scannen.'
                        : 'Keine Treffer.',
                    style: theme.textTheme.bodyMedium,
                  ),
                )
              : ListView.builder(
                  itemCount: tracks.length,
                  itemBuilder: (context, i) => _TrackTile(track: tracks[i]),
                ),
        ),
      ],
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({required this.track});

  final TrackInfo track;

  @override
  Widget build(BuildContext context) {
    final fileName = track.path.split('/').last;
    final subtitle = [track.artist, track.album]
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .join(' · ');
    return ListTile(
      leading: const Icon(Icons.music_note),
      title: Text(track.title ?? fileName, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subtitle.isEmpty ? track.path : subtitle,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: track.track == null ? null : Text(track.track!),
    );
  }
}
