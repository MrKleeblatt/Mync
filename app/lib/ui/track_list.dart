import 'package:flutter/material.dart';

import '../library/track.dart';
import 'cover_art.dart';
import 'scope.dart';
import 'track_actions.dart';

/// Liste von Titeln. Antippen spielt die Liste ab diesem Titel in der
/// aktuellen Warteschlange; Rechtsklick/Menü zeigt weitere Aktionen.
class TrackListView extends StatelessWidget {
  const TrackListView({
    super.key,
    required this.tracks,
    this.showCover = true,
    this.showTrackNo = false,
    this.header,
    this.padding = const EdgeInsets.only(bottom: 16),
  });

  final List<Track> tracks;
  final bool showCover;
  final bool showTrackNo;
  final Widget? header;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final player = context.player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final current = player.currentPath;
        final offset = header == null ? 0 : 1;
        return ListView.builder(
          padding: padding,
          itemCount: tracks.length + offset,
          itemExtent: header == null ? 64 : null,
          itemBuilder: (context, i) {
            if (i < offset) return header!;
            final t = tracks[i - offset];
            return TrackTile(
              track: t,
              selected: t.path == current,
              showCover: showCover,
              leadingNumber: showTrackNo ? t.trackNo : null,
              onTap: () => player.playTracks(
                tracks.map((e) => e.path).toList(),
                start: i - offset,
              ),
            );
          },
        );
      },
    );
  }
}

class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.selected = false,
    this.showCover = true,
    this.leadingNumber,
    this.trailing,
    this.subtitle,
  });

  final Track track;
  final VoidCallback onTap;
  final bool selected;
  final bool showCover;
  final int? leadingNumber;
  final Widget? trailing;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub =
        subtitle ??
        [track.artist, if (track.album != null) track.album!].join(' · ');
    Widget leading;
    if (leadingNumber != null || !showCover) {
      leading = SizedBox(
        width: 32,
        child: Center(
          child: selected
              ? Icon(Icons.equalizer, color: theme.colorScheme.primary)
              : Text(
                  leadingNumber?.toString() ?? '',
                  style: theme.textTheme.bodySmall,
                ),
        ),
      );
    } else {
      leading = CoverArt(track: track, size: 44);
    }
    return GestureDetector(
      onSecondaryTapUp: (d) =>
          showTrackMenu(context, [track], position: d.globalPosition),
      onLongPressStart: (d) =>
          showTrackMenu(context, [track], position: d.globalPosition),
      child: ListTile(
        selected: selected,
        leading: leading,
        title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: onTap,
        trailing:
            trailing ??
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 8),
                Text(
                  formatDuration(track.duration),
                  style: theme.textTheme.bodySmall,
                ),
                Builder(
                  builder: (btnCtx) => IconButton(
                    tooltip: 'Mehr',
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => showTrackMenu(btnCtx, [track]),
                  ),
                ),
              ],
            ),
      ),
    );
  }
}

/// Kopfzeile für Gruppen (Album, Künstler, Ordner): Abspielen, Zufall, Menü.
class GroupHeader extends StatelessWidget {
  const GroupHeader({
    super.key,
    required this.tracks,
    required this.title,
    this.subtitle,
    this.cover,
  });

  final List<Track> tracks;
  final String title;
  final String? subtitle;
  final Widget? cover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = tracks.fold(Duration.zero, (a, t) => a + t.duration);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (cover != null) ...[cover!, const SizedBox(width: 16)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.headlineSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null)
                  Text(subtitle!, style: theme.textTheme.titleSmall),
                Text(
                  '${tracks.length} Titel · ${formatDuration(total)}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: tracks.isEmpty
                          ? null
                          : () => runTrackAction(
                              context,
                              TrackAction.play,
                              tracks,
                            ),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Abspielen'),
                    ),
                    OutlinedButton.icon(
                      onPressed: tracks.isEmpty
                          ? null
                          : () => runTrackAction(
                              context,
                              TrackAction.shuffle,
                              tracks,
                            ),
                      icon: const Icon(Icons.shuffle),
                      label: const Text('Zufällig'),
                    ),
                    Builder(
                      builder: (c) => IconButton(
                        tooltip: 'Weitere Aktionen',
                        onPressed: tracks.isEmpty
                            ? null
                            : () => showTrackMenu(
                                c,
                                tracks,
                                actions: groupActions.sublist(2),
                              ),
                        icon: const Icon(Icons.more_horiz),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
