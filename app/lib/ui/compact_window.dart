import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../player/player_controller.dart';
import 'global_shortcuts.dart';
import 'cover_art.dart';
import 'now_playing.dart';

/// Schaltet das Fenster in einen kompakten Mini-Player (immer im
/// Vordergrund) und zurück. Nur unter Linux (GTK-Runner, Kanal
/// `mync/window`); unter Wayland entscheidet der Compositor, ob
/// „immer im Vordergrund“ befolgt wird.
class CompactWindow extends ChangeNotifier {
  CompactWindow._();
  static final instance = CompactWindow._();
  static const _channel = MethodChannel('mync/window');

  bool get supported => Platform.isLinux;
  bool active = false;

  Future<void> toggle() => set(!active);

  Future<void> set(bool v) async {
    if (!supported || v == active) return;
    try {
      await _channel.invokeMethod<bool>('setMini', v);
    } on MissingPluginException {
      return;
    }
    active = v;
    notifyListeners();
  }
}

/// Inhalt des Mini-Player-Fensters.
class CompactPlayerView extends StatelessWidget {
  const CompactPlayerView({super.key, required this.player});
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final t = player.currentTrack;
          return Column(
            children: [
              SizedBox(
                height: 4,
                child: PositionSlider(controller: player, compact: true),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 4, 0),
                  child: Row(
                    children: [
                      CoverArt(track: t, size: 64),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t?.title ?? '–',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ),
                            if (t != null)
                              StreamBuilder<Duration>(
                                stream: player.player.stream.position,
                                builder: (context, _) {
                                  final ch = player.currentChapter;
                                  return Text(
                                    ch == null ? t.artist : ch.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  );
                                },
                              ),
                            PositionText(controller: player),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Groß${keyHint('Strg+M')}',
                        onPressed: CompactWindow.instance.toggle,
                        icon: const Icon(Icons.open_in_full),
                      ),
                    ],
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Vorheriger',
                    onPressed: player.previous,
                    icon: const Icon(Icons.skip_previous),
                  ),
                  const SeekButton(forward: false),
                  IconButton.filled(
                    tooltip: 'Abspielen/Pause',
                    onPressed: player.queue.isEmpty ? null : player.playPause,
                    icon: Icon(player.playing ? Icons.pause : Icons.play_arrow),
                  ),
                  const SeekButton(forward: true),
                  IconButton(
                    tooltip: 'Nächster',
                    onPressed: player.next,
                    icon: const Icon(Icons.skip_next),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
          );
        },
      ),
    );
  }
}
