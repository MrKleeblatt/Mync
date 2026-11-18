import 'package:flutter/material.dart';

import '../library/track.dart';
import 'scope.dart';
import 'tag_editor.dart';

/// Aktionen für einen oder mehrere Titel (Kontextmenü, Gruppen-Menü).
enum TrackAction {
  play('Abspielen', Icons.play_arrow),
  shuffle('Zufällig abspielen', Icons.shuffle),
  playNext('Als Nächstes spielen', Icons.playlist_play),
  append('Zur Warteschlange hinzufügen', Icons.playlist_add),
  newQueue('In neuer Warteschlange', Icons.add_to_queue),
  editTags('Tags bearbeiten …', Icons.edit),
  details('Details', Icons.info_outline);

  const TrackAction(this.label, this.icon);
  final String label;
  final IconData icon;
}

const singleTrackActions = [
  TrackAction.playNext,
  TrackAction.append,
  TrackAction.newQueue,
  TrackAction.editTags,
  TrackAction.details,
];

const groupActions = [
  TrackAction.play,
  TrackAction.shuffle,
  TrackAction.playNext,
  TrackAction.append,
  TrackAction.newQueue,
  TrackAction.editTags,
];

/// Zeigt ein Popup-Menü an [position] und führt die gewählte Aktion aus.
Future<void> showTrackMenu(
  BuildContext context,
  List<Track> tracks, {
  Offset? position,
  List<TrackAction> actions = singleTrackActions,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final box = context.findRenderObject() as RenderBox?;
  final pos =
      position ??
      (box == null
          ? Offset.zero
          : box.localToGlobal(box.size.topRight(Offset.zero)));
  final chosen = await showMenu<TrackAction>(
    context: context,
    position: RelativeRect.fromRect(
      pos & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final a in actions)
        PopupMenuItem(
          value: a,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(a.icon),
            title: Text(a.label),
          ),
        ),
    ],
  );
  if (chosen != null && context.mounted) {
    await runTrackAction(context, chosen, tracks);
  }
}

Future<void> runTrackAction(
  BuildContext context,
  TrackAction action,
  List<Track> tracks,
) async {
  if (tracks.isEmpty) return;
  final player = context.player;
  final paths = tracks.map((t) => t.path).toList();
  final messenger = ScaffoldMessenger.maybeOf(context);
  void toast(String s) => messenger?.showSnackBar(
    SnackBar(content: Text(s), duration: const Duration(seconds: 2)),
  );
  final what = tracks.length == 1
      ? '„${tracks.first.title}“'
      : '${tracks.length} Titel';

  switch (action) {
    case TrackAction.play:
      await player.playTracks(paths);
    case TrackAction.shuffle:
      await player.playTracks(paths..shuffle());
    case TrackAction.playNext:
      await player.playNext(paths);
      toast('$what wird als Nächstes gespielt');
    case TrackAction.append:
      await player.append(paths);
      toast('$what zur Warteschlange hinzugefügt');
    case TrackAction.newQueue:
      await player.newQueue(paths: paths);
      toast('Neue Warteschlange „${player.queue.name}“');
    case TrackAction.editTags:
      if (context.mounted) await showTagEditor(context, tracks);
    case TrackAction.details:
      if (context.mounted) await showTrackDetails(context, tracks.first);
  }
}

/// Einfacher Texteingabe-Dialog.
Future<String?> askText(
  BuildContext context, {
  required String title,
  String label = '',
  String initial = '',
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) =>
            Navigator.pop(ctx, v.trim().isEmpty ? null : v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            ctx,
            ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
          ),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

Future<void> showTrackDetails(BuildContext context, Track t) {
  final (plays, last) = context.player.playsFor(t);
  final rows = <(String, String)>[
    ('Titel', t.title),
    ('Künstler', t.artist),
    ('Album', t.albumOrUnknown),
    ('Album-Künstler', t.albumArtist),
    if (t.genres.isNotEmpty) ('Genre', t.genres.join(', ')),
    if (t.composers.isNotEmpty) ('Komponist', t.composers.join(', ')),
    if (t.date != null) ('Jahr', t.date!),
    if (t.trackNo != null) ('Titelnummer', '${t.trackNo}'),
    ('Dauer', formatDuration(t.duration)),
    ('Datei', t.path),
    ('Format', t.extension.toUpperCase()),
    ('Hinzugefügt', _date(t.added)),
    ('Gespielt', '$plays×'),
    if (last != null) ('Zuletzt gehört', _date(last)),
  ];
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Details'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Table(
            columnWidths: const {0: IntrinsicColumnWidth()},
            children: [
              for (final r in rows)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 16, bottom: 6),
                      child: Text(
                        r.$1,
                        style: Theme.of(ctx).textTheme.labelMedium,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SelectableText(r.$2),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Schließen'),
        ),
      ],
    ),
  );
}

String _date(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year} '
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
