import 'package:flutter/material.dart';

import 'menu_sheet.dart';
import 'scope.dart';

/// Klang: Balance und ReplayGain.
Future<void> showSoundSheet(BuildContext context) => showMenuSheet<void>(
  context,
  title: 'Klang',
  subtitle: 'Balance, ReplayGain',
  icon: Icons.tune,
  builder: (_) => const _SoundBody(),
);

class _SoundBody extends StatelessWidget {
  const _SoundBody();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = context.player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final b = player.balance;
        final label = b == 0
            ? 'Mitte'
            : '${(b.abs() * 100).round()} % ${b < 0 ? 'links' : 'rechts'}';
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Label('Balance', label),
              Slider(
                value: b,
                min: -1,
                max: 1,
                divisions: 20,
                label: label,
                onChanged: player.setBalance,
              ),
              _ResetButton(
                onPressed: b == 0 ? null : () => player.setBalance(0),
              ),
              const SizedBox(height: 8),
              Text('ReplayGain', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
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
          ),
        );
      },
    );
  }
}

/// Wiedergabegeschwindigkeit und Tonhöhe.
Future<void> showSpeedDialog(BuildContext context) => showMenuSheet<void>(
  context,
  title: 'Tempo',
  subtitle: 'Geschwindigkeit, Tonhöhe',
  icon: Icons.speed,
  builder: (_) => const _SpeedBody(),
);

class _SpeedBody extends StatelessWidget {
  const _SpeedBody();

  @override
  Widget build(BuildContext context) {
    final player = context.player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final p = player.pitch;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Label('Geschwindigkeit', '${player.speed.toStringAsFixed(2)}×'),
              Slider(
                value: player.speed,
                min: 0.5,
                max: 2.0,
                divisions: 30,
                onChanged: player.setSpeed,
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  for (final v in [0.75, 1.0, 1.25, 1.5, 2.0])
                    ChoiceChip(
                      label: Text('$v×'),
                      selected: (player.speed - v).abs() < 0.001,
                      onSelected: (_) => player.setSpeed(v),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _Label(
                'Tonhöhe',
                p == 0
                    ? '±0'
                    : '${p > 0 ? '+' : ''}${p.toStringAsFixed(1)} Halbtöne',
              ),
              Slider(
                value: p,
                min: -6,
                max: 6,
                divisions: 24,
                onChanged: player.setPitch,
              ),
              if (player.pitchUnavailable && p != 0)
                Text(
                  'Tonhöhe hier nicht verfügbar (mpv ohne rubberband)',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              _ResetButton(
                onPressed: player.speed == 1 && p == 0
                    ? null
                    : () {
                        player.setSpeed(1);
                        player.setPitch(0);
                      },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Sleeptimer: nach Zeit oder nach dem laufenden Titel.
Future<void> showSleepTimer(BuildContext context) {
  final player = context.player;
  final at = player.sleepAt;
  return showMenuSheet<void>(
    context,
    title: 'Sleeptimer',
    subtitle: at != null
        ? 'Hält um ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')} an'
        : player.sleepAfterTrack
        ? 'Hält nach diesem Titel an'
        : 'Aus',
    icon: Icons.timer_outlined,
    builder: (ctx) => ListenableBuilder(
      listenable: player,
      builder: (ctx, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            secondary: const Icon(Icons.pause_circle_outline),
            title: const Text('Nach diesem Titel anhalten'),
            value: player.sleepAfterTrack,
            onChanged: player.setSleepAfterTrack,
          ),
          const Divider(indent: 24, endIndent: 24),
          if (player.sleepAt != null)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.timer_off_outlined),
              title: const Text('Timer aus'),
              onTap: () {
                player.setSleepTimer(null);
                Navigator.pop(ctx);
              },
            ),
          for (final m in [10, 15, 30, 45, 60, 90, 120])
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.timer_outlined),
              title: Text('In $m min'),
              onTap: () {
                player.setSleepTimer(Duration(minutes: m));
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    ),
  );
}

/// Name eines Reglers links, Wert rechts.
class _Label extends StatelessWidget {
  const _Label(this.name, this.value);
  final String name;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(name, style: theme.textTheme.titleSmall),
        const Spacer(),
        Text(value, style: theme.textTheme.titleMedium),
      ],
    );
  }
}

class _ResetButton extends StatelessWidget {
  const _ResetButton({required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.restart_alt),
      label: const Text('Zurücksetzen'),
    ),
  );
}
