import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/mync_core.dart';
import '../library/track.dart';
import 'cover_art.dart';
import 'scope.dart';

/// Felder des Editors: (Schlüssel, Beschriftung, mehrwertig mit „;“).
const _editorFields = <(String, String, bool)>[
  ('title', 'Titel', false),
  ('artist', 'Künstler', true),
  ('album', 'Album', false),
  ('albumartist', 'Album-Künstler', true),
  ('composer', 'Komponist', true),
  ('genre', 'Genre', true),
  ('date', 'Jahr', false),
  ('track', 'Nr.', false),
  ('tracktotal', 'von', false),
  ('disc', 'CD', false),
  ('disctotal', 'CDs', false),
  ('comment', 'Kommentar', false),
];

/// Felder, die bei Mehrfachbearbeitung pro Datei verschieden sein müssen.
const _perFileOnly = {'title', 'track', 'lyrics'};

Future<void> showTagEditor(BuildContext context, List<Track> tracks) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MyncScope(
        settings: context.settings,
        library: context.library,
        player: context.player,
        child: TagEditorDialog(tracks: tracks),
      ),
    );

class TagEditorDialog extends StatefulWidget {
  const TagEditorDialog({super.key, required this.tracks});
  final List<Track> tracks;

  @override
  State<TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<TagEditorDialog> {
  final _ctrl = <String, TextEditingController>{};
  final _mixed = <String>{};
  final _dirty = <String>{};
  List<FileTags>? _loaded;
  String? _error;
  bool _saving = false;

  /// Neues Cover (Bilddatei) bzw. Cover entfernen; beides aus = unverändert.
  String? _coverFile;
  bool _removeCover = false;
  int _done = 0;

  bool get _multi => widget.tracks.length > 1;

  @override
  void initState() {
    super.initState();
    for (final f in [
      ..._editorFields.map((e) => e.$1),
      'description',
      'lyrics',
    ]) {
      _ctrl[f] = TextEditingController()..addListener(() => _dirty.add(f));
    }
    _load();
  }

  Future<void> _load() async {
    try {
      final lib = context.library;
      final all = await Future.wait(
        widget.tracks.map((t) => readTags(lib.abs(t.path))),
      );
      if (!mounted) return;
      for (final f in _ctrl.keys) {
        final values = all
            .map((t) => (t.fields[f] ?? const []).join('; '))
            .toSet();
        _ctrl[f]!.text = values.length == 1 ? values.first : '';
        if (values.length > 1) _mixed.add(f);
      }
      _dirty.clear();
      setState(() => _loaded = all);
    } catch (e) {
      setState(() => _error = e is MyncCoreException ? e.userMessage : '$e');
    }
  }

  bool get _writable => _loaded != null && _loaded!.every((t) => t.writable);

  Future<void> _save() async {
    final lib = context.library;
    setState(() {
      _saving = true;
      _done = 0;
      _error = null;
    });
    try {
      for (var i = 0; i < widget.tracks.length; i++) {
        final path = lib.abs(widget.tracks[i].path);
        final fields = <String, List<String>>{
          for (final e in _loaded![i].fields.entries) e.key: [...e.value],
        };
        for (final f in _dirty) {
          if (_multi && _perFileOnly.contains(f)) continue;
          final text = _ctrl[f]!.text.trim();
          final multiValue = _editorFields.any((e) => e.$1 == f && e.$3);
          final values = text.isEmpty
              ? <String>[]
              : multiValue
              ? text
                    .split(';')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList()
              : [f == 'lyrics' ? _ctrl[f]!.text : text];
          if (values.isEmpty) {
            fields.remove(f);
          } else {
            fields[f] = values;
          }
        }
        await writeTags(
          path,
          fields,
          coverFile: _coverFile,
          removeCover: _removeCover,
        );
        lib.invalidateCover(widget.tracks[i]);
        setState(() => _done = i + 1);
      }
      await lib.refresh();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = e is MyncCoreException ? e.userMessage : '$e';
      });
    }
  }

  Future<void> _pickCover() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Bilder',
          extensions: ['jpg', 'jpeg', 'png'],
          mimeTypes: ['image/jpeg', 'image/png'],
        ),
      ],
    );
    if (file == null) return;
    setState(() {
      _coverFile = file.path;
      _removeCover = false;
    });
  }

  Widget _coverSection(ThemeData theme) {
    const size = 96.0;
    final loaded = _loaded!;
    final counts = loaded.map((t) => t.pictureHashes.join(',')).toSet();
    final Widget preview;
    if (_coverFile != null) {
      preview = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(_coverFile!),
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
    } else if (_removeCover) {
      preview = CoverArt(track: null, size: size, radius: 8);
    } else {
      preview = CoverArt(track: widget.tracks.first, size: size, radius: 8);
    }
    final String status;
    if (_coverFile != null) {
      status = 'Neues Cover: ${_coverFile!.split(Platform.pathSeparator).last}';
    } else if (_removeCover) {
      status = 'Eingebettete Bilder werden entfernt.';
    } else if (counts.length > 1) {
      status = 'Verschiedene Cover – bleiben unverändert.';
    } else {
      final n = loaded.first.pictures;
      status = n == 0
          ? 'Kein eingebettetes Cover.'
          : n == 1
          ? 'Eingebettetes Cover.'
          : '$n eingebettete Bilder.';
    }
    final hasAny = loaded.any((t) => t.pictures > 0);
    final enabled = !_saving && _writable;
    return Row(
      children: [
        preview,
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(status, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    onPressed: enabled ? _pickCover : null,
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('Bild wählen …'),
                  ),
                  if (hasAny && !_removeCover)
                    OutlinedButton.icon(
                      onPressed: enabled
                          ? () => setState(() {
                              _removeCover = true;
                              _coverFile = null;
                            })
                          : null,
                      icon: const Icon(Icons.hide_image_outlined),
                      label: const Text('Entfernen'),
                    ),
                  if (_coverFile != null || _removeCover)
                    TextButton(
                      onPressed: enabled
                          ? () => setState(() {
                              _removeCover = false;
                              _coverFile = null;
                            })
                          : null,
                      child: const Text('Rückgängig'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(String key, String label, {int maxLines = 1, double? width}) {
    final disabled = _multi && _perFileOnly.contains(key);
    return SizedBox(
      width: width,
      child: TextField(
        controller: _ctrl[key],
        enabled: !disabled && !_saving && _writable,
        maxLines: maxLines,
        minLines: maxLines > 1 ? 4 : 1,
        decoration: InputDecoration(
          labelText: label,
          hintText: _mixed.contains(key) ? '<verschiedene Werte>' : null,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _multi
        ? 'Tags von ${widget.tracks.length} Titeln'
        : 'Tags bearbeiten';
    Widget body;
    if (_loaded == null && _error == null) {
      body = const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    } else {
      body = SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_multi)
              Text(widget.tracks.first.path, style: theme.textTheme.bodySmall),
            if (_loaded != null && !_writable)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Tags dieses Formats können nicht geschrieben werden '
                  '(möglich: MP3, FLAC, Ogg Vorbis, Opus, M4A, WAV). '
                  'Die Werte werden nur angezeigt.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (_multi)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Nur geänderte Felder werden in alle Dateien geschrieben.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            if (_loaded != null) _coverSection(theme),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final f in _editorFields)
                  _field(
                    f.$1,
                    f.$2,
                    width:
                        const {
                          'track',
                          'tracktotal',
                          'disc',
                          'disctotal',
                          'date',
                        }.contains(f.$1)
                        ? 102
                        : 270,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _field(
              'description',
              'Beschreibung (Kapitel als „00:00 Titel“ je Zeile möglich)',
              maxLines: 6,
            ),
            const SizedBox(height: 12),
            if (!_multi)
              _field('lyrics', 'Lyrics (auch LRC mit [mm:ss.xx])', maxLines: 8),
            const SizedBox(height: 4),
            Text(
              'Mehrere Künstler/Genres mit „;“ trennen.',
              style: theme.textTheme.bodySmall,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      );
    }
    return AlertDialog(
      title: Text(title),
      content: SizedBox(width: 580, child: body),
      actions: [
        if (_saving)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text('$_done / ${widget.tracks.length}'),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: (_saving || !_writable) ? null : _save,
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
