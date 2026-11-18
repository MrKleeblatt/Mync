import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/mync_core.dart';
import '../library/chapters.dart';
import '../library/lrc.dart';
import '../library/track.dart';
import '../player/player_controller.dart';
import '../player/queue.dart';
import 'cover_art.dart';
import 'compact_window.dart';
import 'lrc_editor.dart';
import 'scope.dart';
import 'sound_sheets.dart';
import 'track_actions.dart';

/// Spul-Knopf passend zur eingestellten Schrittweite.
class SeekButton extends StatelessWidget {
  const SeekButton({super.key, required this.forward, this.size});
  final bool forward;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final p = context.player;
    final step = context.settings.seekStep;
    final icon = forward
        ? switch (step) {
            5 => Icons.forward_5,
            10 => Icons.forward_10,
            30 => Icons.forward_30,
            _ => Icons.fast_forward,
          }
        : switch (step) {
            5 => Icons.replay_5,
            10 => Icons.replay_10,
            30 => Icons.replay_30,
            _ => Icons.fast_rewind,
          };
    return IconButton(
      iconSize: size,
      tooltip: forward
          ? '$step s vor (→, Umschalt+→: 1 min)'
          : '$step s zurück (←, Umschalt+←: 1 min)',
      onPressed: p.queue.isEmpty ? null : () => p.skipBy(forward ? 1 : -1),
      icon: Icon(icon),
    );
  }
}

/// Öffnet den großen Wiedergabebildschirm (von unten eingeschoben).
void openNowPlaying(BuildContext context) {
  final s = MyncScope.of(context);
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => MyncScope(
        settings: s.settings,
        library: s.library,
        player: s.player,
        child: const NowPlayingPage(),
      ),
      transitionsBuilder: (_, anim, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(anim),
        child: child,
      ),
    ),
  );
}

/// Wiedergabeleiste für Unterseiten (Album, Künstler, Playlist).
class PageMiniPlayer extends StatelessWidget {
  const PageMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: MiniPlayer(onOpen: () => openNowPlaying(context)),
  );
}

/// Schmale Wiedergabeleiste am unteren Rand.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final player = context.player;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final t = player.currentTrack;
        final wide = MediaQuery.sizeOf(context).width >= 720;
        return Material(
          color: theme.colorScheme.surfaceContainer,
          child: InkWell(
            onTap: t == null ? null : onOpen,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 4,
                  child: PositionSlider(controller: player, compact: true),
                ),
                SizedBox(
                  height: 64,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      CoverArt(track: t, size: 44),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t?.title ?? 'Nichts in der Warteschlange',
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
                                    ch == null
                                        ? t.artist
                                        : '${t.artist} · ${ch.title}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                      if (wide) ...[
                        PositionText(controller: player),
                        const SizedBox(width: 8),
                      ],
                      IconButton(
                        tooltip: 'Vorheriger (Strg+←)',
                        onPressed: player.previous,
                        icon: const Icon(Icons.skip_previous),
                      ),
                      if (wide) const SeekButton(forward: false),
                      IconButton.filled(
                        tooltip: 'Abspielen/Pause (Leertaste)',
                        onPressed: player.queue.isEmpty
                            ? null
                            : player.playPause,
                        icon: Icon(
                          player.playing ? Icons.pause : Icons.play_arrow,
                        ),
                      ),
                      if (wide) const SeekButton(forward: true),
                      IconButton(
                        tooltip: 'Nächster (Strg+→)',
                        onPressed: player.next,
                        icon: const Icon(Icons.skip_next),
                      ),
                      if (wide) ...[
                        const SizedBox(width: 8),
                        _RepeatButton(player: player),
                        SizedBox(
                          width: 140,
                          child: _VolumeSlider(player: player),
                        ),
                        if (CompactWindow.instance.supported)
                          IconButton(
                            tooltip: 'Mini-Player (Strg+M)',
                            onPressed: CompactWindow.instance.toggle,
                            icon: const Icon(Icons.picture_in_picture_alt),
                          ),
                      ],
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Fortschrittsbalken mit eigener Aktualisierung (ohne den ganzen Baum neu zu bauen).
class PositionSlider extends StatefulWidget {
  const PositionSlider({
    super.key,
    required this.controller,
    this.compact = false,
  });
  final PlayerController controller;
  final bool compact;

  @override
  State<PositionSlider> createState() => _PositionSliderState();
}

/// Zeichnet kurze senkrechte Striche an den Kapitelanfängen.
class _ChapterTicks extends CustomPainter {
  _ChapterTicks(this.fractions, this.color);
  final List<double> fractions;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final mid = size.height / 2;
    for (final f in fractions) {
      final x = size.width * f.clamp(0.0, 1.0);
      canvas.drawLine(Offset(x, mid - 9), Offset(x, mid - 5), paint);
    }
  }

  @override
  bool shouldRepaint(_ChapterTicks old) =>
      old.fractions != fractions || old.color != color;
}

class _PositionSliderState extends State<PositionSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return StreamBuilder<Duration>(
      stream: c.player.stream.position,
      builder: (context, _) {
        final dur = c.duration > Duration.zero
            ? c.duration
            : (c.currentTrack?.duration ?? Duration.zero);
        final max = dur.inMilliseconds.toDouble();
        final pos = (_drag ?? c.position.inMilliseconds.toDouble()).clamp(
          0.0,
          max <= 0 ? 0.0 : max,
        );
        if (widget.compact) {
          return LinearProgressIndicator(
            value: max <= 0 ? 0 : pos / max,
            minHeight: 4,
          );
        }
        final starts = [
          for (final ch in c.chapters.chapters)
            if (ch.start > Duration.zero && max > 0)
              ch.start.inMilliseconds / max,
        ];
        return Column(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                // Kapitelanfänge als kleine Striche über der Leiste
                if (starts.isNotEmpty)
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: CustomPaint(
                        painter: _ChapterTicks(
                          starts,
                          Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                Slider(
                  value: pos,
                  max: max <= 0 ? 1 : max,
                  onChanged: max <= 0 ? null : (v) => setState(() => _drag = v),
                  onChangeEnd: (v) async {
                    await c.seek(Duration(milliseconds: v.round()));
                    setState(() => _drag = null);
                  },
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Text(formatDuration(Duration(milliseconds: pos.round()))),
                  const Spacer(),
                  Text(formatDuration(dur)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class PositionText extends StatelessWidget {
  const PositionText({super.key, required this.controller});
  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: controller.player.stream.position,
      builder: (context, _) {
        final dur = controller.duration > Duration.zero
            ? controller.duration
            : (controller.currentTrack?.duration ?? Duration.zero);
        return Text(
          '${formatDuration(controller.position)} / ${formatDuration(dur)}',
          style: Theme.of(context).textTheme.bodySmall,
        );
      },
    );
  }
}

class _RepeatButton extends StatelessWidget {
  const _RepeatButton({required this.player});
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final mode = player.queue.repeat;
    final (icon, tip) = switch (mode) {
      QueueRepeat.off => (Icons.repeat, 'Wiederholen: aus'),
      QueueRepeat.all => (Icons.repeat_on, 'Wiederholen: Warteschlange'),
      QueueRepeat.one => (Icons.repeat_one_on, 'Wiederholen: Titel'),
    };
    return IconButton(
      tooltip: tip,
      onPressed: player.cycleRepeat,
      icon: Icon(icon),
    );
  }
}

class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({required this.player});
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(player.volume == 0 ? Icons.volume_off : Icons.volume_up, size: 20),
        Expanded(
          child: Slider(
            value: player.volume,
            max: 100,
            onChanged: player.setVolume,
          ),
        ),
      ],
    );
  }
}

// ─── Großer Wiedergabebildschirm ────────────────────────────────────────

class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key});

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  /// Was anstelle des Covers gezeigt wird.
  _Panel _panel = _Panel.cover;

  @override
  Widget build(BuildContext context) {
    final player = context.player;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final t = player.currentTrack;
        final size = MediaQuery.sizeOf(context);
        final wide = size.width >= 900;
        final coverSize = (wide ? size.height * 0.5 : size.width * 0.75).clamp(
          160.0,
          460.0,
        );
        final controls = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t?.title ?? '–',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              t == null ? '' : t.artist,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (t?.album != null)
              Text(
                t!.album!,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            if (!player.chapters.isEmpty)
              StreamBuilder<Duration>(
                stream: player.player.stream.position,
                builder: (context, _) {
                  final i = player.chapterIndex;
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: 'Vorheriges Kapitel (Bild ↑)',
                          onPressed: player.previousChapter,
                          icon: const Icon(Icons.keyboard_double_arrow_left),
                        ),
                        Flexible(
                          child: TextButton(
                            onPressed: () =>
                                setState(() => _panel = _Panel.chapters),
                            child: Text(
                              i < 0
                                  ? '${player.chapters.length} Kapitel'
                                  : 'Kapitel ${i + 1}/${player.chapters.length} · ${player.chapters.chapters[i].title}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Nächstes Kapitel (Bild ↓)',
                          onPressed: player.nextChapter,
                          icon: const Icon(Icons.keyboard_double_arrow_right),
                        ),
                      ],
                    ),
                  );
                },
              ),
            const SizedBox(height: 16),
            PositionSlider(controller: player),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Warteschlange mischen',
                  onPressed: player.shuffleQueue,
                  icon: const Icon(Icons.shuffle),
                ),
                const SizedBox(width: 8),
                IconButton(
                  iconSize: 36,
                  tooltip: 'Vorheriger Titel',
                  onPressed: player.previous,
                  icon: const Icon(Icons.skip_previous),
                ),
                const SeekButton(forward: false, size: 30),
                const SizedBox(width: 4),
                IconButton.filled(
                  iconSize: 48,
                  onPressed: player.queue.isEmpty ? null : player.playPause,
                  icon: Icon(player.playing ? Icons.pause : Icons.play_arrow),
                ),
                const SizedBox(width: 4),
                const SeekButton(forward: true, size: 30),
                IconButton(
                  iconSize: 36,
                  tooltip: 'Nächster Titel',
                  onPressed: player.next,
                  icon: const Icon(Icons.skip_next),
                ),
                const SizedBox(width: 8),
                _RepeatButton(player: player),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 4,
              children: [
                IconButton(
                  tooltip: 'Lyrics',
                  isSelected: _panel == _Panel.lyrics,
                  onPressed: () => setState(
                    () => _panel = _panel == _Panel.lyrics
                        ? _Panel.cover
                        : _Panel.lyrics,
                  ),
                  icon: const Icon(Icons.lyrics_outlined),
                  selectedIcon: const Icon(Icons.lyrics),
                ),
                if (!player.chapters.isEmpty)
                  IconButton(
                    tooltip: 'Kapitel',
                    isSelected: _panel == _Panel.chapters,
                    onPressed: () => setState(
                      () => _panel = _panel == _Panel.chapters
                          ? _Panel.cover
                          : _Panel.chapters,
                    ),
                    icon: const Icon(Icons.list_alt_outlined),
                    selectedIcon: const Icon(Icons.list_alt),
                  ),
                IconButton(
                  tooltip: 'Klang',
                  onPressed: () => showSoundSheet(context),
                  icon: const Icon(Icons.tune),
                ),
                IconButton(
                  tooltip: 'Geschwindigkeit',
                  onPressed: () => showSpeedDialog(context),
                  icon: const Icon(Icons.speed),
                ),
                IconButton(
                  tooltip: 'Sleeptimer',
                  onPressed: () => showSleepTimer(context),
                  icon: Icon(
                    player.sleepAt != null || player.sleepAfterTrack
                        ? Icons.timer
                        : Icons.timer_outlined,
                  ),
                ),
                if (t != null)
                  Builder(
                    builder: (c) => IconButton(
                      tooltip: 'Mehr',
                      onPressed: () => showTrackMenu(c, [t]),
                      icon: const Icon(Icons.more_vert),
                    ),
                  ),
              ],
            ),
            if (wide)
              SizedBox(width: 360, child: _VolumeSlider(player: player)),
          ],
        );
        final panel = (_panel == _Panel.chapters && player.chapters.isEmpty)
            ? _Panel.cover
            : _panel;
        final art = switch (panel) {
          _Panel.lyrics when t != null => SizedBox(
            width: coverSize * 1.2,
            height: coverSize,
            child: LyricsView(track: t, controller: player),
          ),
          _Panel.chapters => SizedBox(
            width: coverSize * 1.2,
            height: coverSize,
            child: ChapterListView(controller: player),
          ),
          _ => CoverArt(track: t, size: coverSize, radius: 16),
        };
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.maybePop(context),
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  tooltip: 'Schließen (Esc)',
                  icon: const Icon(Icons.expand_more),
                  onPressed: () => Navigator.pop(context),
                ),
                title: Text(
                  player.queue.name,
                  style: theme.textTheme.titleSmall,
                ),
                centerTitle: true,
              ),
              body: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: wide
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            art,
                            const SizedBox(width: 48),
                            SizedBox(width: 460, child: controls),
                          ],
                        )
                      : Column(
                          children: [art, const SizedBox(height: 24), controls],
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

enum _Panel { cover, lyrics, chapters }

/// Kapitelliste; das laufende Kapitel ist hervorgehoben, Antippen springt dorthin.
class ChapterListView extends StatelessWidget {
  const ChapterListView({super.key, required this.controller});
  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = controller.chapters;
    return StreamBuilder<Duration>(
      stream: controller.player.stream.position,
      builder: (context, _) {
        final cur = controller.chapterIndex;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              list.source == ChapterSource.tags
                  ? 'Kapitel aus den Tags'
                  : 'Kapitel aus dem Beschreibungstext',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final ch = list.chapters[i];
                  final active = i == cur;
                  return ListTile(
                    dense: true,
                    selected: active,
                    leading: SizedBox(
                      width: 64,
                      child: Text(
                        formatDuration(ch.start),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    title: Text(
                      ch.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: active
                          ? const TextStyle(fontWeight: FontWeight.w600)
                          : null,
                    ),
                    trailing: active
                        ? Icon(
                            controller.playing ? Icons.graphic_eq : Icons.pause,
                            size: 18,
                          )
                        : null,
                    onTap: () => controller.jumpToChapter(i),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Lyrics: `.lrc` neben der Datei (bevorzugt) oder eingebettet.
/// Synchronisierte Lyrics laufen mit; Antippen einer Zeile springt dorthin.
class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.track, required this.controller});
  final Track track;
  final PlayerController controller;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  Future<Lyrics?>? _future;
  String? _for;
  int _version = -1;
  final _scroll = ScrollController();
  int _lastIndex = -2;

  Future<Lyrics?> _load(Track t) async {
    final lib = context.library;
    final lrc = File(
      lib.abs('${t.folder.isEmpty ? '' : '${t.folder}/'}${t.baseName}.lrc'),
    );
    if (await lrc.exists()) {
      final l = Lyrics.parse(await lrc.readAsString());
      if (l != null) return l;
    }
    try {
      final tags = await readTags(lib.abs(t.path));
      return Lyrics.parse(tags.fields['lyrics']?.join('\n'));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final version = context.library.lyricsVersion;
    if (_for != widget.track.path || version != _version) {
      _for = widget.track.path;
      _version = version;
      _future = _load(widget.track);
      _lastIndex = -2;
    }
    final theme = Theme.of(context);
    return Stack(
      children: [
        Positioned.fill(child: _content(theme)),
        Positioned(
          top: 0,
          right: 0,
          child: IconButton(
            tooltip: 'Lyrics synchronisieren',
            icon: const Icon(Icons.edit_note),
            onPressed: () => showLrcEditor(context, widget.track),
          ),
        ),
      ],
    );
  }

  Widget _content(ThemeData theme) {
    return FutureBuilder<Lyrics?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final l = snap.data;
        if (l == null) {
          return Center(
            child: Text(
              'Keine Lyrics vorhanden.\nÜber ✎ oben rechts Text einfügen und synchronisieren\noder eine .lrc-Datei neben den Titel legen.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          );
        }
        if (!l.synced) {
          return SingleChildScrollView(
            child: Text(
              l.plain!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
            ),
          );
        }
        return StreamBuilder<Duration>(
          stream: widget.controller.player.stream.position,
          builder: (context, _) {
            final idx = l.indexAt(widget.controller.position);
            if (idx != _lastIndex) {
              _lastIndex = idx;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_scroll.hasClients && idx >= 0) {
                  _scroll.animateTo(
                    (idx * 56.0 - 120).clamp(
                      0,
                      _scroll.position.maxScrollExtent,
                    ),
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                  );
                }
              });
            }
            return ListView.builder(
              controller: _scroll,
              itemCount: l.lines.length,
              itemExtent: 56,
              itemBuilder: (context, i) {
                final active = i == idx;
                return InkWell(
                  onTap: () => widget.controller.seek(l.lines[i].time),
                  child: Center(
                    child: Text(
                      l.lines[i].text.isEmpty ? '♪' : l.lines[i].text,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (active
                                  ? theme.textTheme.titleMedium
                                  : theme.textTheme.bodyLarge)
                              ?.copyWith(
                                color: active
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                                fontWeight: active
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}
