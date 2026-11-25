import 'package:flutter/material.dart';

import '../library/track.dart';
import '../player/player_controller.dart';
import 'cover_art.dart';
import 'menu_sheet.dart';
import 'scope.dart';
import 'track_actions.dart';

/// Die aktuelle Warteschlange (nach dem Vorbild von Musicolet): oben die
/// Auswahl der Warteschlange, darunter ihre Titel, unten die Suche.
/// Bearbeiten (verschieben, entfernen) nach langem Drücken auf einen Titel.
class QueuesPage extends StatefulWidget {
  const QueuesPage({super.key, this.compact = false});

  /// Kompakt: als Seitenleiste neben der Bibliothek.
  final bool compact;

  @override
  State<QueuesPage> createState() => QueuesPageState();
}

class QueuesPageState extends State<QueuesPage> {
  /// Bearbeitung: ausgewählte Einträge (Indizes); null = nicht bearbeiten.
  Set<int>? _selected;
  final _search = TextEditingController();
  String _query = '';
  int _queueId = -1;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Zurücktaste: Bearbeitung beenden bzw. Suche leeren.
  bool handleBack() {
    if (_selected != null) {
      _done();
      return true;
    }
    if (_query.isNotEmpty) {
      _search.clear();
      setState(() => _query = '');
      return true;
    }
    return false;
  }

  void _edit(int i) => setState(() => _selected = {i});
  void _done() => setState(() => _selected = null);

  void _toggle(int i) => setState(() {
    final s = _selected!;
    if (!s.remove(i)) s.add(i);
  });

  @override
  Widget build(BuildContext context) {
    final player = context.player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        // andere Warteschlange gewählt: Bearbeitung und Suche zurücksetzen
        if (_queueId != player.currentQueueIndex) {
          _queueId = player.currentQueueIndex;
          _selected = null;
        }
        final sel = _selected;
        if (sel != null) {
          sel.removeWhere((i) => i >= player.queue.items.length);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(player: player, compact: widget.compact),
            const Divider(height: 1),
            Expanded(
              child: _QueueList(
                player: player,
                query: _query,
                selected: sel,
                onEdit: _edit,
                onToggle: _toggle,
              ),
            ),
            if (sel != null)
              _EditBar(player: player, selected: sel, onDone: _done)
            else
              _SearchField(
                controller: _search,
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
          ],
        );
      },
    );
  }
}

// ─── Kopf: Auswahl der Warteschlange, Position, Gesamtdauer ─────────────

class _Header extends StatelessWidget {
  const _Header({required this.player, required this.compact});
  final PlayerController player;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = player.queue;
    final total = _total(context, player);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // „3. Name ⌄“ öffnet die Liste aller Warteschlangen
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              alignment: Alignment.centerLeft,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => _chooseQueue(context, player),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${player.currentQueueIndex + 1}. ${q.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: compact
                        ? theme.textTheme.titleMedium
                        : theme.textTheme.titleLarge,
                  ),
                ),
                const Icon(Icons.expand_more),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  q.items.isEmpty
                      ? 'Leer'
                      : '${q.index + 1} / ${q.items.length} · ⏱ ${formatDuration(total)}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              IconButton(
                tooltip: 'Mischen',
                onPressed: q.items.length < 2 ? null : player.shuffleQueue,
                icon: const Icon(Icons.shuffle),
              ),
              IconButton(
                tooltip: 'Mehr',
                icon: const Icon(Icons.more_vert),
                onPressed: () async {
                  final i = player.currentQueueIndex;
                  final v = await showActionSheet<String>(
                    context,
                    title: '${i + 1}. ${q.name}',
                    subtitle: '${q.items.length} Titel',
                    icon: Icons.queue_music,
                    items: [
                      const MenuItem('new', Icons.add, 'Neue Warteschlange'),
                      const MenuItem(
                        'rename',
                        Icons.edit_outlined,
                        'Umbenennen',
                      ),
                      const MenuItem('clear', Icons.clear_all, 'Leeren'),
                      if (player.queues.length > 1)
                        const MenuItem(
                          'delete',
                          Icons.delete_outline,
                          'Löschen',
                        ),
                    ],
                  );
                  if (v != null && context.mounted) {
                    await _queueAction(context, player, i, v);
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Duration _total(BuildContext context, PlayerController p) {
  final lib = context.library;
  return p.queue.items.fold(
    Duration.zero,
    (a, path) => a + (lib.byPath(path)?.duration ?? Duration.zero),
  );
}

Future<void> _queueAction(
  BuildContext context,
  PlayerController player,
  int i,
  String action,
) async {
  switch (action) {
    case 'new':
      await player.newQueue();
    case 'rename':
      final n = await askText(
        context,
        title: 'Umbenennen',
        label: 'Name',
        initial: player.queues[i].name,
      );
      if (n != null) player.renameQueue(i, n);
    case 'clear':
      if (i != player.currentQueueIndex) await player.switchQueue(i);
      await player.clearQueue();
    case 'delete':
      await player.deleteQueue(i);
  }
}

/// Alle Warteschlangen: wechseln, umbenennen, löschen, neu.
Future<void> _chooseQueue(BuildContext context, PlayerController player) =>
    showMenuSheet<void>(
      context,
      title: 'Warteschlangen',
      subtitle: '${player.queues.length} Warteschlangen',
      icon: Icons.queue_music,
      builder: (ctx) => ListenableBuilder(
        listenable: player,
        builder: (ctx, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < player.queues.length; i++)
              ListTile(
                contentPadding: const EdgeInsets.only(left: 24, right: 12),
                selected: i == player.currentQueueIndex,
                leading: Icon(
                  i == player.currentQueueIndex
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(
                  '${i + 1}. ${player.queues[i].name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${player.queues[i].items.length} Titel'),
                onTap: () {
                  player.switchQueue(i);
                  Navigator.pop(ctx);
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Umbenennen',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _queueAction(ctx, player, i, 'rename'),
                    ),
                    IconButton(
                      tooltip: 'Löschen',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: player.queues.length < 2
                          ? null
                          : () => _queueAction(ctx, player, i, 'delete'),
                    ),
                  ],
                ),
              ),
            const Divider(indent: 24, endIndent: 24),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.add),
              title: const Text('Neue Warteschlange'),
              onTap: () async {
                await player.newQueue();
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );

// ─── Titel ───────────────────────────────────────────────────────────────

class _QueueList extends StatelessWidget {
  const _QueueList({
    required this.player,
    required this.query,
    required this.selected,
    required this.onEdit,
    required this.onToggle,
  });
  final PlayerController player;
  final String query;
  final Set<int>? selected;
  final void Function(int) onEdit;
  final void Function(int) onToggle;

  bool _matches(Track? t, String path) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return [
      t?.title,
      t?.artist,
      t?.album,
      path,
    ].any((s) => s != null && s.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final q = player.queue;
    final lib = context.library;
    if (q.isEmpty) {
      return const Center(child: Text('Leer'));
    }
    final editing = selected != null;
    // Suche: nur passende Einträge, ohne Verschieben
    final shown = [
      for (var i = 0; i < q.items.length; i++)
        if (_matches(lib.byPath(q.items[i]), q.items[i])) i,
    ];
    Widget tile(BuildContext context, int i) => _QueueTile(
      key: ValueKey('$i:${q.items[i]}'),
      player: player,
      index: i,
      editing: editing,
      checked: selected?.contains(i) ?? false,
      onTap: editing ? () => onToggle(i) : () => player.jumpTo(i),
      onLongPress: editing ? () => onToggle(i) : () => onEdit(i),
    );
    if (query.isNotEmpty || !editing) {
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: shown.length,
        itemBuilder: (context, k) => tile(context, shown[k]),
      );
    }
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: q.items.length,
      onReorderItem: player.moveItem,
      itemBuilder: tile,
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    super.key,
    required this.player,
    required this.index,
    required this.editing,
    required this.checked,
    required this.onTap,
    required this.onLongPress,
  });
  final PlayerController player;
  final int index;
  final bool editing;
  final bool checked;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final path = player.queue.items[index];
    final t = context.library.byPath(path);
    final current = index == player.queue.index;
    final accent = current ? c.primary : null;
    Widget cover = t == null
        ? const SizedBox.square(dimension: 52, child: Icon(Icons.help_outline))
        : CoverArt(track: t, size: 52);
    if (editing) {
      cover = Stack(
        alignment: Alignment.center,
        children: [
          Opacity(opacity: checked ? 0.4 : 1, child: cover),
          if (checked) Icon(Icons.check, size: 32, color: c.onSurface),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: checked
            ? c.primaryContainer.withValues(alpha: 0.35)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: current
              ? BorderSide(color: c.primary, width: 1.5)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 0, 6),
            child: Row(
              children: [
                if (editing)
                  ReorderableDragStartListener(
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.drag_handle),
                    ),
                  )
                else
                  const SizedBox(width: 8),
                cover,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t?.title ?? path.split('/').last,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: accent,
                          fontWeight: current ? FontWeight.w600 : null,
                        ),
                      ),
                      Text(
                        t?.artist ?? 'Datei fehlt',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: accent ?? c.onSurfaceVariant,
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              t?.album ?? t?.folder ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: accent ?? c.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (t != null)
                            Text(
                              formatDuration(t.duration),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: accent,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (player.stopsAfter(path))
                  Tooltip(
                    message: 'Hält nach diesem Titel an',
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(
                        Icons.pause_circle_outline,
                        size: 18,
                        color: c.primary,
                      ),
                    ),
                  ),
                if (current && player.playing)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(Icons.graphic_eq, size: 18, color: c.primary),
                  ),
                if (!editing)
                  Builder(
                    builder: (b) => IconButton(
                      tooltip: 'Mehr',
                      icon: Icon(Icons.more_horiz, color: accent),
                      onPressed: () => _tileMenu(b, player, index, t),
                    ),
                  )
                else
                  const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// „⋯“ an einem Titel der Warteschlange (einheitliches Menü).
Future<void> _tileMenu(
  BuildContext context,
  PlayerController player,
  int index,
  Track? t,
) async {
  final path = player.queue.items[index];
  final stops = player.stopsAfter(path);
  final chosen = await showActionSheet<Object>(
    context,
    title: t?.title ?? path.split('/').last,
    subtitle: t?.artist,
    leading: t == null
        ? const Icon(Icons.help_outline, size: 28)
        : CoverArt(track: t, size: 48),
    items: [
      if (index != player.queue.index)
        const MenuItem('next', Icons.playlist_play, 'Als Nächstes'),
      MenuItem(
        'stop',
        stops ? Icons.play_circle_outline : Icons.pause_circle_outline,
        stops ? 'Nicht mehr danach anhalten' : 'Nach diesem Titel anhalten',
        selected: stops,
      ),
      const MenuItem(
        'remove',
        Icons.remove_circle_outline,
        'Aus Warteschlange entfernen',
      ),
      if (t != null) ...[
        null,
        for (final a in const [
          TrackAction.newQueue,
          TrackAction.editTags,
          TrackAction.syncLyrics,
          TrackAction.details,
        ])
          MenuItem<Object>(a, a.icon, a.label),
      ],
    ],
  );
  if (!context.mounted) return;
  switch (chosen) {
    case 'next':
      await player.moveAfterCurrent([index]);
    case 'stop':
      player.setStopAfter(stops ? null : path);
    case 'remove':
      await _removeWithUndo(context, player, [index]);
    case final TrackAction a when t != null:
      await runTrackAction(context, a, [t]);
  }
}

/// Entfernt Titel, mit „Rückgängig“ (wieder an alter Stelle einfügen).
Future<void> _removeWithUndo(
  BuildContext context,
  PlayerController player,
  List<int> indices,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final sorted = indices.toList()..sort();
  final removed = [for (final i in sorted) (i, player.queue.items[i])];
  final hadCurrent = sorted.contains(player.queue.index);
  await player.removeItems(sorted);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          removed.length == 1
              ? 'Entfernt: ${context.mounted ? context.library.byPath(removed.first.$2)?.title ?? removed.first.$2 : removed.first.$2}'
              : '${removed.length} Titel entfernt',
        ),
        action: hadCurrent
            ? null
            : SnackBarAction(
                label: 'Rückgängig',
                onPressed: () async {
                  for (final (i, path) in removed) {
                    await player.append([path]);
                    final last = player.queue.items.length - 1;
                    if (i < last) await player.moveItem(last, i);
                  }
                },
              ),
      ),
    );
}

// ─── Unten: Bearbeiten bzw. Suche ───────────────────────────────────────

class _EditBar extends StatelessWidget {
  const _EditBar({
    required this.player,
    required this.selected,
    required this.onDone,
  });
  final PlayerController player;
  final Set<int> selected;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lib = context.library;
    final time = selected.fold(
      Duration.zero,
      (a, i) =>
          a + (lib.byPath(player.queue.items[i])?.duration ?? Duration.zero),
    );
    final none = selected.isEmpty;
    Widget action(IconData icon, String label, VoidCallback? onTap) => Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Opacity(
            opacity: onTap == null ? 0.4 : 1,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [Icon(icon), const SizedBox(height: 2), Text(label)],
            ),
          ),
        ),
      ),
    );
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${selected.length} ausgewählt · ⏱ ${formatDuration(time)}'
                ' · Griff ≡ zum Verschieben',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  action(
                    Icons.remove_circle_outline,
                    'Entfernen',
                    none
                        ? null
                        : () async {
                            final s = selected.toList();
                            onDone();
                            await _removeWithUndo(context, player, s);
                          },
                  ),
                  action(
                    Icons.playlist_play,
                    'Als Nächstes',
                    none
                        ? null
                        : () async {
                            final s = selected.toList();
                            onDone();
                            await player.moveAfterCurrent(s);
                          },
                  ),
                  action(Icons.check, 'Fertig', onDone),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
    child: TextField(
      controller: controller,
      onChanged: onChanged,
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search),
        hintText: 'In dieser Warteschlange suchen …',
        border: InputBorder.none,
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Leeren',
                icon: const Icon(Icons.close),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
      ),
    ),
  );
}
