import 'package:flutter/material.dart';

import 'scope.dart';

/// Klang: Balance und ReplayGain.
Future<void> showSoundSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => MyncScope(
    settings: context.settings,
    library: context.library,
    player: context.player,
    child: const _SoundSheet(),
  ),
);

class _SoundSheet extends StatelessWidget {
  const _SoundSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = context.player;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final b = player.balance;
          final label = b == 0
              ? 'Mitte'
              : '${(b.abs() * 100).round()} % ${b < 0 ? 'links' : 'rechts'}';
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Klang', style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('Balance', style: theme.textTheme.titleSmall),
                  Expanded(
                    child: Slider(
                      value: b,
                      min: -1,
                      max: 1,
                      divisions: 20,
                      label: label,
                      onChanged: player.setBalance,
                    ),
                  ),
                  SizedBox(
                    width: 104,
                    child: TextButton(
                      onPressed: b == 0 ? null : () => player.setBalance(0),
                      child: Text(label),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('ReplayGain', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'no', label: Text('Aus')),
                  ButtonSegment(value: 'track', label: Text('Titel')),
                  ButtonSegment(value: 'album', label: Text('Album')),
                ],
                selected: {context.settings.replayGain},
                onSelectionChanged: (s) => player.setReplayGain(s.first),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Wiedergabegeschwindigkeit.
Future<void> showSpeedDialog(BuildContext context) {
  final player = context.player;
  return showDialog<void>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: player,
      builder: (ctx, _) => AlertDialog(
        title: const Text('Geschwindigkeit und Tonhöhe'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${player.speed.toStringAsFixed(2)}×',
              style: Theme.of(ctx).textTheme.headlineSmall,
            ),
            Slider(
              value: player.speed,
              min: 0.5,
              max: 2.0,
              divisions: 30,
              onChanged: player.setSpeed,
            ),
            Wrap(
              spacing: 6,
              children: [
                for (final v in [0.75, 1.0, 1.25, 1.5, 2.0])
                  ActionChip(
                    label: Text('$v×'),
                    onPressed: () => player.setSpeed(v),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Tonhöhe: ${player.pitch == 0 ? 'unverändert' : '${player.pitch > 0 ? '+' : ''}${player.pitch.toStringAsFixed(1)} Halbtöne'}',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
            Slider(
              value: player.pitch,
              min: -6,
              max: 6,
              divisions: 24,
              onChanged: player.setPitch,
            ),
            if (player.pitchUnavailable && player.pitch != 0)
              Text(
                'Tonhöhe nicht verfügbar: mpv/ffmpeg ohne „rubberband“.',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
            TextButton(
              onPressed: player.pitch == 0 ? null : () => player.setPitch(0),
              child: const Text('Tonhöhe zurücksetzen'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Schließen'),
          ),
        ],
      ),
    ),
  );
}

/// Sleeptimer: nach Zeit oder nach dem aktuellen Titel.
Future<void> showSleepTimer(BuildContext context) {
  final player = context.player;
  return showDialog<void>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: player,
      builder: (ctx, _) {
        final at = player.sleepAt;
        return SimpleDialog(
          title: const Text('Sleeptimer'),
          children: [
            if (at != null)
              ListTile(
                leading: const Icon(Icons.timer),
                title: Text(
                  'Stoppt um ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
                ),
                trailing: TextButton(
                  onPressed: () => player.setSleepTimer(null),
                  child: const Text('Aus'),
                ),
              ),
            for (final m in [10, 15, 30, 45, 60, 90, 120])
              SimpleDialogOption(
                onPressed: () {
                  player.setSleepTimer(Duration(minutes: m));
                  Navigator.pop(ctx);
                },
                child: Text('In $m Minuten'),
              ),
            CheckboxListTile(
              value: player.sleepAfterTrack,
              onChanged: (v) => player.setSleepAfterTrack(v ?? false),
              title: const Text('Nach dem aktuellen Titel anhalten'),
            ),
          ],
        );
      },
    ),
  );
}
