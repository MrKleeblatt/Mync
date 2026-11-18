import 'package:flutter/material.dart';

import '../settings.dart';
import 'scope.dart';

/// Equalizer mit 10 Bändern und Presets.
Future<void> showEqualizer(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => MyncScope(
    settings: context.settings,
    library: context.library,
    player: context.player,
    child: const _EqualizerSheet(),
  ),
);

class _EqualizerSheet extends StatefulWidget {
  const _EqualizerSheet();

  @override
  State<_EqualizerSheet> createState() => _EqualizerSheetState();
}

class _EqualizerSheetState extends State<_EqualizerSheet> {
  late List<double> _gains = context.settings.eqGains;
  late bool _enabled = context.settings.eqEnabled;

  Future<void> _apply() =>
      context.player.setEqualizer(enabled: _enabled, gains: _gains);

  static String _label(int hz) => hz >= 1000 ? '${hz ~/ 1000}k' : '$hz';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Equalizer', style: theme.textTheme.titleLarge),
              const Spacer(),
              Switch(
                value: _enabled,
                onChanged: (v) {
                  setState(() => _enabled = v);
                  _apply();
                },
              ),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in eqPresets.entries)
                ChoiceChip(
                  label: Text(e.key),
                  selected: _listEq(_gains, e.value),
                  onSelected: (_) {
                    setState(() {
                      _gains = [...e.value];
                      _enabled = true;
                    });
                    _apply();
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 220,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var i = 0; i < eqBands.length; i++)
                  Column(
                    children: [
                      Text(
                        '${_gains[i] > 0 ? '+' : ''}${_gains[i].toStringAsFixed(0)}',
                        style: theme.textTheme.labelSmall,
                      ),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: Slider(
                            value: _gains[i],
                            min: -12,
                            max: 12,
                            divisions: 24,
                            onChanged: _enabled
                                ? (v) => setState(() => _gains[i] = v)
                                : null,
                            onChangeEnd: (_) => _apply(),
                          ),
                        ),
                      ),
                      Text(
                        _label(eqBands[i]),
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: context.player,
            builder: (context, _) {
              final b = context.player.balance;
              final label = b == 0
                  ? 'Mitte'
                  : '${(b.abs() * 100).round()} % ${b < 0 ? 'links' : 'rechts'}';
              return Row(
                children: [
                  Text('Balance', style: theme.textTheme.titleSmall),
                  Expanded(
                    child: Slider(
                      value: b,
                      min: -1,
                      max: 1,
                      divisions: 20,
                      label: label,
                      onChanged: context.player.setBalance,
                    ),
                  ),
                  SizedBox(
                    width: 96,
                    child: TextButton(
                      onPressed: b == 0
                          ? null
                          : () => context.player.setBalance(0),
                      child: Text(label),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Text('ReplayGain', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          ListenableBuilder(
            listenable: context.player,
            builder: (context, _) => SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'no', label: Text('Aus')),
                ButtonSegment(value: 'track', label: Text('Titel')),
                ButtonSegment(value: 'album', label: Text('Album')),
              ],
              selected: {context.settings.replayGain},
              onSelectionChanged: (s) => context.player.setReplayGain(s.first),
            ),
          ),
        ],
      ),
    );
  }

  static bool _listEq(List<double> a, List<double> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
