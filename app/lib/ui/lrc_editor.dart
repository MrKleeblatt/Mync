import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/mync_core.dart';
import '../log.dart';
import '../library/lrc.dart';
import '../library/track.dart';
import 'global_shortcuts.dart';
import 'scope.dart';
import 'status_line.dart';

Future<void> showLrcEditor(BuildContext context, Track track) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MyncScope(
        settings: context.settings,
        library: context.library,
        player: context.player,
        child: LrcEditor(track: track),
      ),
    );

/// Pfad der `.lrc`-Datei neben einem Titel.
String lrcPathFor(BuildContext context, Track t) => context.library.abs(
  '${t.folder.isEmpty ? '' : '${t.folder}/'}${t.baseName}.lrc',
);

String _fmt(Duration d) {
  final cs = (d.inMilliseconds / 10).round();
  return '${(cs ~/ 6000).toString().padLeft(2, '0')}:'
      '${((cs ~/ 100) % 60).toString().padLeft(2, '0')}.'
      '${(cs % 100).toString().padLeft(2, '0')}';
}

/// Lyrics synchronisieren: Zeile für Zeile beim Hören einen Zeitstempel
/// setzen (Eingabetaste), danach als `.lrc` oder in die Tags speichern.
class LrcEditor extends StatefulWidget {
  const LrcEditor({super.key, required this.track});
  final Track track;

  @override
  State<LrcEditor> createState() => _LrcEditorState();
}

class _LrcEditorState extends State<LrcEditor> {
  List<LrcDraftLine>? _lines;
  int _target = 0;
  bool _toTags = false;
  bool _saving = false;
  bool _writable = true;
  OpStatus? _status;
  final _scroll = ScrollController();
  final _focus = FocusNode();
  static const _rowHeight = 48.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String? text;
    var fromFile = false;
    final lrc = File(lrcPathFor(context, widget.track));
    final abs = context.library.abs(widget.track.path);
    if (await lrc.exists()) {
      text = await lrc.readAsString();
      fromFile = true;
    }
    try {
      final tags = await readTags(abs);
      _writable = tags.writable;
      text ??= tags.fields['lyrics']?.join('\n');
    } catch (_) {
      _writable = false;
    }
    if (!mounted) return;
    setState(() {
      _lines = lrcDraftFrom(text);
      _toTags = !fromFile && text != null && _writable;
      _target = _lines!.indexWhere((l) => l.time == null);
      if (_target < 0) _target = 0;
    });
    if (_lines!.isEmpty) await _editText();
  }

  bool get _isCurrent => context.player.queue.current == widget.track.path;

  Future<void> _playThis() async {
    final p = context.player;
    await p.playNext([widget.track.path]);
    await p.next();
  }

  void _stamp() {
    final lines = _lines;
    if (lines == null || lines.isEmpty || !_isCurrent) return;
    setState(() {
      lines[_target].time = context.player.position;
      if (_target < lines.length - 1) _target++;
    });
    _reveal();
  }

  void _back() {
    final lines = _lines;
    if (lines == null || lines.isEmpty) return;
    setState(() {
      if (_target > 0 && lines[_target].time == null) _target--;
      lines[_target].time = null;
    });
    _reveal();
  }

  void _select(int i) {
    setState(() => _target = i.clamp(0, (_lines?.length ?? 1) - 1));
    _reveal();
  }

  void _shift(int ms) {
    final l = _lines?[_target];
    if (l?.time == null) return;
    setState(() {
      final v = l!.time!.inMilliseconds + ms;
      l.time = Duration(milliseconds: v < 0 ? 0 : v);
    });
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        (_target * _rowHeight - 2 * _rowHeight).clamp(
          0,
          _scroll.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _editText() async {
    final old = _lines ?? [];
    final ctrl = TextEditingController(text: old.map((l) => l.text).join('\n'));
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Liedtext'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            minLines: 12,
            maxLines: 20,
            decoration: const InputDecoration(
              hintText: 'Text einfügen – eine Zeile pro Lyrics-Zeile',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Übernehmen'),
          ),
        ],
      ),
    );
    // nicht sofort entsorgen: der Dialog blendet noch aus
    Future<void>.delayed(const Duration(seconds: 1), ctrl.dispose);
    if (text == null || !mounted) return;
    final rows = [
      for (final l in text.split(RegExp(r'\r?\n')))
        if (l.trim().isNotEmpty) l.trim(),
    ];
    setState(() {
      // Zeiten bleiben je Zeilennummer erhalten
      _lines = [
        for (var i = 0; i < rows.length; i++)
          LrcDraftLine(rows[i], i < old.length ? old[i].time : null),
      ];
      _target = _lines!.indexWhere((l) => l.time == null);
      if (_target < 0) _target = 0;
    });
    _focus.requestFocus();
  }

  Future<void> _save() async {
    final lines = _lines!;
    final t = widget.track;
    final lib = context.library;
    final text = formatLrc(
      lines,
      title: t.hasTitle ? t.title : null,
      artist: t.artists.isEmpty ? null : t.artist,
    );
    setState(() {
      _saving = true;
      _status = const OpStatus.busy('Speichere …');
    });
    try {
      final lrc = File(lrcPathFor(context, t));
      if (_toTags) {
        final abs = lib.abs(t.path);
        final tags = await readTags(abs);
        await writeTags(abs, {
          ...tags.fields,
          'lyrics': [text.trimRight()],
        });
        // eine alte .lrc hätte Vorrang – entfernen
        if (await lrc.exists()) await lrc.delete();
        await lib.refresh();
      } else {
        await lrc.writeAsString(text, flush: true);
      }
      lib.lyricsChanged();
      logInfo(
        'Lyrics gespeichert (${_toTags ? 'Tags' : '.lrc'}): ${t.path}, '
        '${lines.where((l) => l.time != null).length} Zeilen',
      );
      if (mounted) Navigator.pop(context);
    } catch (e, st) {
      logError('Lyrics speichern fehlgeschlagen: ${t.path}', e, st);
      setState(() {
        _saving = false;
        _status = OpStatus.error(shortError(e, 'Speichern fehlgeschlagen'));
      });
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (e.logicalKey) {
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        _stamp();
      case LogicalKeyboardKey.backspace:
        _back();
      case LogicalKeyboardKey.arrowUp:
        _select(_target - 1);
      case LogicalKeyboardKey.arrowDown:
        _select(_target + 1);
      case LogicalKeyboardKey.minus || LogicalKeyboardKey.numpadSubtract:
        _shift(-100);
      case LogicalKeyboardKey.add ||
          LogicalKeyboardKey.numpadAdd ||
          LogicalKeyboardKey.equal:
        _shift(100);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = context.player;
    final lines = _lines;
    final timed = lines?.where((l) => l.time != null).length ?? 0;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: AlertDialog(
        title: Text('Lyrics synchronisieren – ${widget.track.title}'),
        content: SizedBox(
          width: 680,
          height: 520,
          child: lines == null
              ? const Center(child: CircularProgressIndicator())
              : ListenableBuilder(
                  listenable: player,
                  builder: (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!_isCurrent)
                        Card(
                          color: theme.colorScheme.secondaryContainer,
                          child: ListTile(
                            leading: const Icon(Icons.info_outline),
                            title: Text(
                              'Zum Synchronisieren muss dieser Titel laufen.',
                            ),
                            trailing: FilledButton.icon(
                              onPressed: _playThis,
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('Abspielen'),
                            ),
                          ),
                        ),
                      Row(
                        children: [
                          IconButton(
                            tooltip: '5 s zurück',
                            onPressed: _isCurrent
                                ? () => player.seekRelative(
                                    const Duration(seconds: -5),
                                  )
                                : null,
                            icon: const Icon(Icons.replay_5),
                          ),
                          IconButton.filled(
                            tooltip: 'Wiedergabe/Pause${keyHint('Leertaste')}',
                            onPressed: _isCurrent ? player.playPause : null,
                            icon: Icon(
                              player.playing ? Icons.pause : Icons.play_arrow,
                            ),
                          ),
                          IconButton(
                            tooltip: '5 s vor',
                            onPressed: _isCurrent
                                ? () => player.seekRelative(
                                    const Duration(seconds: 5),
                                  )
                                : null,
                            icon: const Icon(Icons.forward_5),
                          ),
                          const SizedBox(width: 8),
                          StreamBuilder<Duration>(
                            stream: player.player.stream.position,
                            builder: (context, _) => Text(
                              _isCurrent ? _fmt(player.position) : '--:--.--',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '$timed / ${lines.length} Zeilen',
                            style: theme.textTheme.bodySmall,
                          ),
                          IconButton(
                            tooltip: 'Text bearbeiten',
                            onPressed: _editText,
                            icon: const Icon(Icons.edit_note),
                          ),
                        ],
                      ),
                      const Divider(height: 8),
                      Expanded(
                        child: ListView.builder(
                          controller: _scroll,
                          itemCount: lines.length,
                          itemExtent: _rowHeight,
                          itemBuilder: (context, i) {
                            final l = lines[i];
                            final active = i == _target;
                            return Material(
                              color: active
                                  ? theme.colorScheme.primaryContainer
                                  : Colors.transparent,
                              child: InkWell(
                                onTap: () => _select(i),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 96,
                                      child: TextButton(
                                        onPressed: l.time == null || !_isCurrent
                                            ? null
                                            : () => player.seek(l.time!),
                                        child: Text(
                                          l.time == null ? '–' : _fmt(l.time!),
                                          style: const TextStyle(
                                            fontFeatures: [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        l.text,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: active
                                            ? theme.textTheme.titleSmall
                                            : theme.textTheme.bodyMedium,
                                      ),
                                    ),
                                    if (active && l.time != null) ...[
                                      IconButton(
                                        tooltip: '0,1 s früher (−)',
                                        onPressed: () => _shift(-100),
                                        icon: const Icon(Icons.remove),
                                      ),
                                      IconButton(
                                        tooltip: '0,1 s später (+)',
                                        onPressed: () => _shift(100),
                                        icon: const Icon(Icons.add),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      // auf dem Handy: „Zeit setzen“ antippen statt Tasten
                      if (!Platform.isAndroid)
                        Text(
                          'Eingabetaste: Zeit für die markierte Zeile setzen · '
                          'Rücktaste: zurück · ↑/↓: Zeile wählen · −/+: '
                          '0,1 s verschieben · Leertaste: Pause',
                          style: theme.textTheme.bodySmall,
                        ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: _isCurrent && lines.isNotEmpty
                                ? _stamp
                                : null,
                            icon: const Icon(Icons.timer_outlined),
                            label: const Text('Zeit setzen'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: lines.isEmpty ? null : _back,
                            child: const Text('Zurück'),
                          ),
                          const Spacer(),
                          SegmentedButton<bool>(
                            segments: [
                              const ButtonSegment(
                                value: false,
                                label: Text('.lrc-Datei'),
                              ),
                              ButtonSegment(
                                value: true,
                                enabled: _writable,
                                label: const Text('In die Tags'),
                              ),
                            ],
                            selected: {_toTags},
                            onSelectionChanged: (v) =>
                                setState(() => _toTags = v.first),
                          ),
                        ],
                      ),
                      if (_status != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: StatusLine(_status),
                        ),
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: _saving || timed == 0 ? null : _save,
            child: Text(
              timed < (lines?.length ?? 0)
                  ? 'Speichern ($timed von ${lines!.length})'
                  : 'Speichern',
            ),
          ),
        ],
      ),
    );
  }
}
