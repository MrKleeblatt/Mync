import 'package:flutter/material.dart';

import '../library/track.dart';
import '../player/player_controller.dart';
import 'cover_art.dart';
import 'scope.dart';
import 'track_actions.dart';

/// Alle Warteschlangen (oben) und der Inhalt der aktuellen (darunter).
/// Jede Warteschlange merkt sich Titel und Position.
class QueuesPage extends StatelessWidget {
  const QueuesPage({super.key, this.compact = false});

  /// Kompakt: als Seitenleiste neben der Bibliothek.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final player = context.player;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Text(
                    'Warteschlangen',
                    style: compact
                        ? theme.textTheme.titleMedium
                        : theme.textTheme.headlineSmall,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Neue Warteschlange',
                    onPressed: () => player.newQueue(),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 56,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                itemCount: player.queues.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final q = player.queues[i];
                  final sel = i == player.currentQueueIndex;
                  return GestureDetector(
                    onSecondaryTapUp: (d) =>
                        _queueMenu(context, player, i, d.globalPosition),
                    onLongPressStart: (d) =>
                        _queueMenu(context, player, i, d.globalPosition),
                    child: ChoiceChip(
                      selected: sel,
                      avatar: sel && player.playing
                          ? const Icon(Icons.graphic_eq, size: 18)
                          : null,
                      label: Text(
                        '${q.name} · ${q.items.isEmpty ? 0 : q.index + 1}/${q.items.length}',
                      ),
                      onSelected: (_) => player.switchQueue(i),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${player.queue.items.length} Titel · ${formatDuration(_total(context, player))}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Mischen',
                    onPressed: player.queue.items.length < 2
                        ? null
                        : player.shuffleQueue,
                    icon: const Icon(Icons.shuffle),
                  ),
                  Builder(
                    builder: (c) => IconButton(
                      tooltip: 'Weitere Aktionen',
                      onPressed: () {
                        final box = c.findRenderObject() as RenderBox;
                        _queueMenu(
                          c,
                          player,
                          player.currentQueueIndex,
                          box.localToGlobal(box.size.center(Offset.zero)),
                        );
                      },
                      icon: const Icon(Icons.more_vert),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _QueueList(player: player)),
          ],
        );
      },
    );
  }

  static Duration _total(BuildContext context, PlayerController p) {
    final lib = context.library;
    return p.queue.items.fold(
      Duration.zero,
      (a, path) => a + (lib.byPath(path)?.duration ?? Duration.zero),
    );
  }

  static Future<void> _queueMenu(
    BuildContext context,
    PlayerController player,
    int i,
    Offset pos,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        pos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'rename', child: Text('Umbenennen …')),
        PopupMenuItem(value: 'clear', child: Text('Leeren')),
        PopupMenuItem(value: 'delete', child: Text('Löschen')),
      ],
    );
    if (!context.mounted) return;
    switch (choice) {
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
}

/// Titel der Warteschlange. Bearbeiten nur durch seitliches Wischen:
/// nach links nimmt den Titel heraus (rückgängig machbar), nach rechts
/// schaltet ihn zum Verschieben frei (Griff zum Ziehen, Pfeile).
class _QueueList extends StatefulWidget {
  const _QueueList({required this.player});
  final PlayerController player;

  @override
  State<_QueueList> createState() => _QueueListState();
}

class _QueueListState extends State<_QueueList> {
  String? _moving; // Pfad des Titels, der gerade verschoben werden darf

  Future<void> _remove(BuildContext context, int i, String path) async {
    final player = widget.player;
    final name = context.library.byPath(path)?.title ?? path.split('/').last;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final wasCurrent = i == player.queue.index;
    await player.removeAt(i);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text('− $name'),
        action: wasCurrent
            ? null
            : SnackBarAction(
                label: 'Rückgängig',
                onPressed: () async {
                  await player.append([path]);
                  final last = player.queue.items.length - 1;
                  if (i < last) await player.moveItem(last, i);
                },
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final q = player.queue;
    final lib = context.library;
    final theme = Theme.of(context);
    if (q.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('–', textAlign: TextAlign.center),
        ),
      );
    }
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      itemCount: q.items.length,
      onReorderItem: player.moveItem,
      itemBuilder: (context, i) {
        final path = q.items[i];
        final t = lib.byPath(path);
        final current = i == q.index;
        final moving = _moving == path;
        return Dismissible(
          key: ValueKey('$i:$path'),
          background: Container(
            color: theme.colorScheme.secondaryContainer,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Icon(
                  Icons.swap_vert,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 8),
                Text(
                  moving ? 'Fertig' : 'Verschieben',
                  style: TextStyle(
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ],
            ),
          ),
          secondaryBackground: Container(
            color: theme.colorScheme.errorContainer,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  'Herausnehmen',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.remove_circle_outline,
                  color: theme.colorScheme.onErrorContainer,
                ),
              ],
            ),
          ),
          confirmDismiss: (dir) async {
            if (dir == DismissDirection.startToEnd) {
              setState(() => _moving = moving ? null : path);
              return false;
            }
            return true;
          },
          onDismissed: (_) => _remove(context, i, path),
          child: ListTile(
            selected: current,
            dense: true,
            tileColor: moving
                ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.35)
                : null,
            leading: t == null
                ? const Icon(Icons.help_outline)
                : CoverArt(track: t, size: 36),
            title: Text(
              t?.title ?? path.split('/').last,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: current
                  ? const TextStyle(fontWeight: FontWeight.w600)
                  : null,
            ),
            subtitle: Text(
              t?.artist ?? 'Datei fehlt',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (current)
                  Icon(
                    player.playing ? Icons.graphic_eq : Icons.pause,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                if (moving) ...[
                  IconButton(
                    tooltip: 'Nach oben',
                    onPressed: i == 0 ? null : () => player.moveItem(i, i - 1),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                  ),
                  IconButton(
                    tooltip: 'Nach unten',
                    onPressed: i == q.items.length - 1
                        ? null
                        : () => player.moveItem(i, i + 1),
                    icon: const Icon(Icons.arrow_downward, size: 18),
                  ),
                  ReorderableDragStartListener(
                    index: i,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Fertig',
                    onPressed: () => setState(() => _moving = null),
                    icon: const Icon(Icons.check, size: 18),
                  ),
                ],
              ],
            ),
            onTap: () => player.jumpTo(i),
          ),
        );
      },
    );
  }
}
