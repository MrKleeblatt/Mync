import 'package:flutter/material.dart';

import '../core/music_fs.dart';
import '../library/rename.dart';
import '../library/track.dart';
import '../log.dart';
import 'scope.dart';
import 'status_line.dart';

Future<void> showRenameDialog(BuildContext context, List<Track> tracks) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MyncScope(
        settings: context.settings,
        library: context.library,
        player: context.player,
        child: RenameDialog(tracks: tracks),
      ),
    );

enum _State { ok, same, conflict, invalid }

class _Plan {
  _Plan(this.track, this.target, this.state);
  final Track track;
  final String? target;
  final _State state;
}

/// Benennt Dateien nach einem Muster aus ihren Tags um (mit Vorschau).
class RenameDialog extends StatefulWidget {
  const RenameDialog({super.key, required this.tracks});
  final List<Track> tracks;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final _ctrl = TextEditingController(text: context.settings.renamePattern)
    ..addListener(() => setState(() {}));
  bool _running = false;
  int _done = 0;
  OpStatus? _status;

  List<_Plan> _plan() {
    final lib = context.library;
    final pattern = _ctrl.text;
    final seen = <String, int>{};
    final targets = [
      for (final t in widget.tracks)
        renameTarget(t, pattern, rootPrefix: lib.rootPrefixOf(t.path)),
    ];
    for (final x in targets) {
      if (x != null) seen[x.toLowerCase()] = (seen[x.toLowerCase()] ?? 0) + 1;
    }
    return [
      for (var i = 0; i < widget.tracks.length; i++)
        _Plan(widget.tracks[i], targets[i], switch (targets[i]) {
          null => _State.invalid,
          final x when x == widget.tracks[i].path => _State.same,
          final x
              when seen[x.toLowerCase()]! > 1 ||
                  lib.byPath(x) != null &&
                      x.toLowerCase() != widget.tracks[i].path.toLowerCase() =>
            _State.conflict,
          _ => _State.ok,
        }),
    ];
  }

  Future<void> _run(List<_Plan> plan) async {
    final lib = context.library;
    await context.settings.setRenamePattern(_ctrl.text);
    final todo = plan.where((p) => p.state == _State.ok).toList();
    setState(() {
      _running = true;
      _done = 0;
      _status = OpStatus.busy('0 / ${todo.length} …');
    });
    var ok = 0;
    var failed = 0;
    for (final p in todo) {
      try {
        await _move(lib.abs(p.track.path), lib.abs(p.target!));
        logInfo('Umbenannt: ${p.track.path} → ${p.target}');
        ok++;
      } catch (e, st) {
        logError('Umbenennen fehlgeschlagen: ${p.track.path}', e, st);
        failed++;
      }
      if (mounted) {
        setState(() {
          _done++;
          _status = OpStatus.busy('$_done / ${todo.length} …');
        });
      }
    }
    // leere alte Ordner aufräumen
    for (final p in todo) {
      await _pruneEmpty(MusicFs.parent(lib.abs(p.track.path)));
    }
    await lib.refresh();
    if (!mounted) return;
    if (failed == 0) {
      Navigator.pop(context);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('$ok ✓')));
    } else {
      setState(() {
        _running = false;
        _status = OpStatus.error('$ok ✓ · $failed ✗');
      });
    }
  }

  static String _base(String path) {
    final slash = path.lastIndexOf('/');
    final dot = path.lastIndexOf('.');
    return dot > slash ? path.substring(0, dot) : path;
  }

  Future<void> _move(String from, String to) async {
    await MusicFs.rename(from, to);
    // Begleitdateien mit gleichem Namen (Lyrics, Beschreibung, Kapitel)
    final fb = _base(from), tb = _base(to);
    for (final ext in sidecarExtensions) {
      final side = '$fb.$ext';
      if (await MusicFs.exists(side) && !await MusicFs.exists('$tb.$ext')) {
        await MusicFs.rename(side, '$tb.$ext');
      }
    }
  }

  Future<void> _pruneEmpty(String d) async {
    final roots = {
      context.library.root,
      for (final r in context.library.extraRoots) r.dir,
    };
    var dir = d;
    while (!roots.contains(dir) && !roots.contains('$dir/')) {
      try {
        if (!await MusicFs.isDir(dir)) return;
        if ((await MusicFs.list(dir)).isNotEmpty) return;
        await MusicFs.delete(dir);
      } catch (_) {
        return;
      }
      final up = MusicFs.parent(dir);
      if (up == dir) return;
      dir = up;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _insert(String ph) {
    final sel = _ctrl.selection;
    final text = _ctrl.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    _ctrl.value = TextEditingValue(
      text: text.replaceRange(start, end, ph),
      selection: TextSelection.collapsed(offset: start + ph.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = _plan();
    final count = plan.where((p) => p.state == _State.ok).length;
    final conflicts = plan.where((p) => p.state == _State.conflict).length;
    return AlertDialog(
      title: Text('Umbenennen (${widget.tracks.length})'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _ctrl,
              enabled: !_running,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Muster',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final e in renamePlaceholders.entries)
                  Tooltip(
                    message: e.value,
                    child: ActionChip(
                      label: Text(e.key),
                      onPressed: _running ? null : () => _insert(e.key),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final ex in const [
                  '{track} - {title}',
                  '{artist} - {title}',
                  '/{albumartist}/{album}/{track} {title}',
                ])
                  TextButton(
                    onPressed: _running ? null : () => _ctrl.text = ex,
                    child: Text(ex),
                  ),
              ],
            ),
            const Divider(),
            SizedBox(
              height: 260,
              child: ListView.builder(
                itemCount: plan.length,
                itemBuilder: (context, i) {
                  final p = plan[i];
                  final (icon, color, note) = switch (p.state) {
                    _State.ok => (
                      Icons.arrow_forward,
                      theme.colorScheme.primary,
                      p.target!,
                    ),
                    _State.same => (
                      Icons.check,
                      theme.colorScheme.outline,
                      '=',
                    ),
                    _State.conflict => (
                      Icons.warning_amber,
                      theme.colorScheme.error,
                      '${p.target} ✗',
                    ),
                    _State.invalid => (
                      Icons.block,
                      theme.colorScheme.error,
                      '✗',
                    ),
                  };
                  return ListTile(
                    dense: true,
                    leading: Icon(icon, color: color, size: 20),
                    title: Text(
                      p.track.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      note,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.state == _State.ok ? null : color,
                      ),
                    ),
                  );
                },
              ),
            ),
            if (conflicts > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '$conflicts ✗',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: StatusLine(_status),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _running ? null : () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _running || count == 0 ? null : () => _run(plan),
          child: Text('$count ✓'),
        ),
      ],
    );
  }
}
