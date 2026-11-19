import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../player/player_controller.dart';
import 'scope.dart';

/// Dekorative Visualisierung hinter der Zeitleiste: die Silhouette des
/// laufenden Titels (aus seiner Hüllkurve), der gespielte Teil farbig, und
/// um die aktuelle Stelle herum bewegen sich die Balken mit dem Pegel.
/// Erkannter Applaus ist leicht hinterlegt.
class TrackVisualizer extends StatefulWidget {
  const TrackVisualizer({
    super.key,
    required this.controller,
    this.height = 56,
    this.barWidth = 3,
    this.mirrored = true,
  });

  final PlayerController controller;
  final double height;
  final double barWidth;

  /// Balken spiegelbildlich um die Mitte (sonst von unten).
  final bool mirrored;

  @override
  State<TrackVisualizer> createState() => _TrackVisualizerState();
}

class _TrackVisualizerState extends State<TrackVisualizer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _tick());
  final _repaint = ValueNotifier<int>(0);

  // Position zwischen den (seltenen) Meldungen von mpv fortschreiben
  Duration _lastPos = Duration.zero;
  DateTime _lastAt = DateTime.now();
  double _smoothLevel = 0;

  PlayerController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onPlayer);
    _onPlayer();
  }

  void _onPlayer() {
    final want = c.playing && context.mounted;
    if (want && !_ticker.isActive) _ticker.start();
    if (!want && _ticker.isActive) _ticker.stop();
    _repaint.value++;
  }

  Duration get _pos {
    if (c.position != _lastPos) {
      _lastPos = c.position;
      _lastAt = DateTime.now();
    }
    if (!c.playing) return _lastPos;
    final dt = DateTime.now().difference(_lastAt);
    // höchstens 0,5 s fortschreiben (falls mpv hängt)
    final ms = min(dt.inMilliseconds, 500) * c.speed;
    return _lastPos + Duration(milliseconds: ms.round());
  }

  void _tick() => _repaint.value++;

  @override
  void didUpdateWidget(TrackVisualizer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onPlayer);
      c.addListener(_onPlayer);
    }
  }

  @override
  void dispose() {
    c.removeListener(_onPlayer);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.settings;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, child) =>
          settings.visualizer ? child! : SizedBox(height: widget.height),
      child: _paint(scheme),
    );
  }

  Widget _paint(ColorScheme scheme) {
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _VisualizerPainter(
            repaint: _repaint,
            state: this,
            played: scheme.primary,
            rest: scheme.onSurfaceVariant,
            applause: scheme.tertiary,
            barWidth: widget.barWidth,
            mirrored: widget.mirrored,
          ),
        ),
      ),
    );
  }
}

class _VisualizerPainter extends CustomPainter {
  _VisualizerPainter({
    required Listenable repaint,
    required this.state,
    required this.played,
    required this.rest,
    required this.applause,
    required this.barWidth,
    required this.mirrored,
  }) : super(repaint: repaint);

  final _TrackVisualizerState state;
  final Color played, rest, applause;
  final double barWidth;
  final bool mirrored;

  @override
  void paint(Canvas canvas, Size size) {
    final c = state.c;
    final a = c.currentAnalysis;
    final w = a?.waveform;
    final dur = c.duration > Duration.zero
        ? c.duration
        : (c.currentTrack?.duration ?? Duration.zero);
    if (dur <= Duration.zero || size.width <= 0) return;
    final pos = state._pos;
    final frac = (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);

    // Applaus-Bereiche dezent hinterlegen
    final ap = Paint()..color = applause.withValues(alpha: 0.10);
    final intro = a?.introApplause;
    if (intro != null) {
      canvas.drawRect(
        Rect.fromLTWH(
          0,
          0,
          size.width * intro.inMilliseconds / dur.inMilliseconds,
          size.height,
        ),
        ap,
      );
    }
    final outro = a?.outroApplause;
    if (outro != null) {
      final x = size.width * (1 - outro.inMilliseconds / dur.inMilliseconds);
      canvas.drawRect(Rect.fromLTWH(x, 0, size.width - x, size.height), ap);
    }

    final gap = max(1.0, barWidth * 0.6);
    final count = max(1, (size.width / (barWidth + gap)).floor());
    final level = w == null ? 0.0 : w.levelAt(pos);
    // Pegel weich nachführen, damit es nicht flackert
    state._smoothLevel += (level - state._smoothLevel) * 0.25;
    final lv = state._smoothLevel;
    final head = frac * count;
    final pPlayed = Paint()..color = played.withValues(alpha: 0.55);
    final pRest = Paint()..color = rest.withValues(alpha: 0.18);
    final pGlow = Paint()..color = played.withValues(alpha: 0.85);
    final t = DateTime.now().millisecondsSinceEpoch / 1000;
    final r = Radius.circular(barWidth / 2);
    for (var i = 0; i < count; i++) {
      double v;
      if (w != null && w.bars.isNotEmpty) {
        final k = (i * w.bars.length / count).floor().clamp(
          0,
          w.bars.length - 1,
        );
        v = w.bars[k] / 255;
      } else {
        // noch keine Analyse: ruhige Platzhalter-Welle
        v = 0.25 + 0.12 * sin(i * 0.35) + 0.08 * sin(i * 0.11 + 1);
      }
      // Bewegung um die Abspielstelle: Pegel × weicher Abfall × leichtes Wogen
      final d = (i - head).abs();
      final near = exp(-d * d / 60);
      final wave = 0.5 + 0.5 * sin(t * 7 + i * 0.9);
      v = (v * (1 - 0.35 * near) + near * lv * (0.55 + 0.45 * wave)).clamp(
        0.04,
        1.0,
      );
      final h = v * (mirrored ? size.height : size.height * 0.95);
      final x = i * (barWidth + gap);
      final top = mirrored ? (size.height - h) / 2 : size.height - h;
      final paint = i < head
          ? (near > 0.4 && c.playing ? pGlow : pPlayed)
          : pRest;
      canvas.drawRRect(
        RRect.fromLTRBR(x, top, x + barWidth, top + h, r),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_VisualizerPainter old) =>
      old.played != played || old.rest != rest || old.barWidth != barWidth;
}
