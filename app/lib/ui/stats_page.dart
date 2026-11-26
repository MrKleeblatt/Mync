import 'package:flutter/material.dart';

import '../library/track.dart';
import '../stats/stats.dart';
import '../stats/suggestions.dart';
import 'bar_chart.dart';
import 'scope.dart';
import 'track_actions.dart';
import 'track_list.dart';

/// Hörstatistik („Diesen Monat am meisten gehört“ …) und Vorschläge.
///
/// Am Handy sind die beiden Unterreiter eigene Seiten der Wischreihe der
/// App ([view] fest, [onSelectView] beim Antippen) – so läuft das Wischen
/// durch, statt in den Unterreitern festzuhängen.
class StatsPage extends StatefulWidget {
  const StatsPage({
    super.key,
    this.view,
    this.onSelectView,
    this.pages,
    this.firstPage = 0,
  });

  /// Fest gewählter Unterreiter (0 Hörgewohnheiten, 1 Vorschläge); null =
  /// beide mit eigenem Wischen (PC).
  final int? view;
  final ValueChanged<int>? onSelectView;

  /// Seiten der App und Index der ersten Statistik-Seite: Beim Wischen
  /// zwischen den beiden Unterreitern bleibt der Kopf (Überschrift,
  /// Reiter) stehen, nur der Inhalt gleitet.
  final PageController? pages;
  final int firstPage;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.view ?? 0,
  );

  @override
  void initState() {
    super.initState();
    widget.pages?.addListener(_onPages);
  }

  @override
  void didUpdateWidget(StatsPage old) {
    super.didUpdateWidget(old);
    if (old.pages != widget.pages) {
      old.pages?.removeListener(_onPages);
      widget.pages?.addListener(_onPages);
    }
    if (widget.view != null) _tabs.index = widget.view!;
  }

  /// Stand der App-Seiten relativ zur ersten Statistik-Seite
  /// (0 = Hörgewohnheiten, 1 = Vorschläge, dazwischen beim Wischen).
  double get _local {
    final c = widget.pages;
    if (c == null || c.positions.length != 1) return (widget.view ?? 0) * 1.0;
    final pos = c.position;
    if (!pos.hasContentDimensions || !pos.hasPixels) {
      return (widget.view ?? 0) * 1.0;
    }
    return (c.page ?? 0) - widget.firstPage;
  }

  void _onPages() {
    if (!mounted || _tabs.indexIsChanging) return;
    final v = widget.view ?? 0;
    // Markierung unter den Reitern folgt dem Wischen
    final off = v == 0 ? _local.clamp(0.0, 1.0) : (_local - 1).clamp(-1.0, 0.0);
    if (_tabs.offset != off) _tabs.offset = off;
    setState(() {});
  }

  StatsRange _range = StatsRange.thisMonth;
  List<Suggestion>? _suggestions;
  int _suggestionsFor = -1;

  @override
  void dispose() {
    widget.pages?.removeListener(_onPages);
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text('Statistik', style: theme.textTheme.headlineSmall),
        ),
        TabBar(
          controller: _tabs,
          onTap: widget.view == null
              ? null
              : (i) {
                  _tabs.index = widget.view!; // die Seite wechselt außen
                  widget.onSelectView?.call(i);
                },
          tabs: const [
            Tab(text: 'Hörgewohnheiten'),
            Tab(text: 'Vorschläge'),
          ],
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _pinned(header, box.maxWidth),
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([context.player, context.library]),
              builder: (context, _) => switch (widget.view) {
                0 => _statsView(context),
                1 => _suggestionsView(context),
                _ => TabBarView(
                  controller: _tabs,
                  children: [_statsView(context), _suggestionsView(context)],
                ),
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Kopf beim Wischen zwischen den Unterreitern an Ort und Stelle halten:
  /// Die Seite „Hörgewohnheiten“ zeigt ihn während des Wechsels, um den
  /// Weg der Seite verschoben; „Vorschläge“ erst, wenn sie ganz da ist.
  Widget _pinned(Widget header, double width) {
    if (widget.pages == null || widget.view == null) return header;
    final l = _local;
    final first = widget.view == 0;
    final dx = first ? l.clamp(0.0, 1.0) : (l - 1).clamp(-1.0, 0.0);
    final visible = first ? l < 0.999 : l >= 0.999;
    return IgnorePointer(
      ignoring: !visible,
      child: Opacity(
        opacity: visible ? 1 : 0,
        child: Transform.translate(
          offset: Offset(dx * width, 0),
          child: header,
        ),
      ),
    );
  }

  // ─── Hörgewohnheiten ──────────────────────────────────────────────────

  Widget _statsView(BuildContext context) {
    final theme = Theme.of(context);
    final player = context.player;
    final lib = context.library;
    final s = summarize(player.history.events, _range);
    final top = <(Track, TrackStat)>[
      for (final ts in s.top)
        if ((lib.byFileId(ts.fileId) ?? lib.byPath(ts.path)) case final t?)
          (t, ts),
    ];
    final topTracks = top.map((e) => e.$1).toList();
    const weekdays = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        SegmentedButton<StatsRange>(
          segments: [
            for (final r in StatsRange.values)
              ButtonSegment(value: r, label: Text(r.label)),
          ],
          selected: {_range},
          onSelectionChanged: (v) => setState(() => _range = v.first),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _Tile('Hörzeit', formatListening(s.listenedMs)),
            _Tile('Wiedergaben', '${s.plays}'),
            _Tile('Verschiedene Titel', '${s.distinctTracks}'),
            _Tile('Aktive Tage', '${s.activeDays}'),
            _Tile('Übersprungen', '${s.skips}'),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                'Top · ${_range.label}',
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (topTracks.isNotEmpty) ...[
              IconButton(
                tooltip: 'Abspielen',
                onPressed: () =>
                    runTrackAction(context, TrackAction.play, topTracks),
                icon: const Icon(Icons.play_arrow),
              ),
              IconButton(
                tooltip: 'Zufällig',
                onPressed: () =>
                    runTrackAction(context, TrackAction.shuffle, topTracks),
                icon: const Icon(Icons.shuffle),
              ),
              IconButton(
                tooltip: 'Neue Warteschlange',
                onPressed: () => player.newQueue(
                  paths: topTracks.map((t) => t.path).toList(),
                  name: 'Top · ${_range.label}',
                ),
                icon: const Icon(Icons.add_to_queue),
              ),
            ],
          ],
        ),
        if (top.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'Noch nichts gehört',
              style: theme.textTheme.bodyMedium,
            ),
          )
        else
          for (var i = 0; i < top.length && i < 25; i++)
            TrackTile(
              track: top[i].$1,
              selected: top[i].$1.path == player.currentPath,
              leadingNumber: i + 1,
              subtitle:
                  '${top[i].$1.artist} · ${top[i].$2.plays}× · ${formatListening(top[i].$2.listenedMs)}',
              onTap: () => player.playTracks(
                topTracks.map((t) => t.path).toList(),
                start: i,
                name: 'Meistgehört',
              ),
            ),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, c) {
            final hourChart = BarChart(
              title: 'Uhrzeit',
              values: s.byHour,
              labels: [for (var h = 0; h < 24; h++) '$h Uhr'],
              labelEvery: 6,
              format: formatListening,
            );
            final dayChart = BarChart(
              title: 'Wochentag',
              values: s.byWeekday,
              labels: weekdays,
              format: formatListening,
            );
            if (c.maxWidth < 700) {
              return Column(
                children: [hourChart, const SizedBox(height: 24), dayChart],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: hourChart),
                const SizedBox(width: 32),
                Expanded(flex: 2, child: dayChart),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        Text('Ordner', style: theme.textTheme.titleMedium),
        for (final f in s.topFolders.take(8))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder),
            title: Text(f.folder.isEmpty ? 'Musik' : f.folder.split('/').last),
            subtitle: Text(
              '${f.folder.isEmpty ? '/' : f.folder} · ${f.plays}× · ${formatListening(f.listenedMs)}',
            ),
            trailing: IconButton(
              tooltip: 'Zufällig',
              icon: const Icon(Icons.shuffle),
              onPressed: () => runTrackAction(
                context,
                TrackAction.shuffle,
                lib.tracksBelow(f.folder),
              ),
            ),
          ),
      ],
    );
  }

  // ─── Vorschläge ───────────────────────────────────────────────────────

  List<Suggestion> _currentSuggestions(
    BuildContext context, {
    bool reroll = false,
  }) {
    final player = context.player;
    final key = player.historyVersion * 100003 + context.library.tracks.length;
    if (reroll || _suggestions == null || _suggestionsFor != key) {
      _suggestions = suggest(
        events: player.history.events,
        tracks: context.library.tracks,
      );
      _suggestionsFor = key;
    }
    return _suggestions!;
  }

  Widget _suggestionsView(BuildContext context) {
    final player = context.player;
    final list = _currentSuggestions(context);
    final tracks = list.map((s) => s.track).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: tracks.isEmpty
                  ? null
                  : () => player.playTracks(
                      tracks.map((t) => t.path).toList(),
                      name: 'Vorschläge',
                    ),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Abspielen'),
            ),
            OutlinedButton.icon(
              onPressed: tracks.isEmpty
                  ? null
                  : () => player.newQueue(
                      paths: tracks.map((t) => t.path).toList(),
                      name: 'Vorschläge',
                    ),
              icon: const Icon(Icons.add_to_queue),
              label: const Text('Neue Warteschlange'),
            ),
            OutlinedButton.icon(
              onPressed: () =>
                  setState(() => _currentSuggestions(context, reroll: true)),
              icon: const Icon(Icons.casino_outlined),
              label: const Text('Neu würfeln'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (list.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Keine Titel'),
          ),
        for (var i = 0; i < list.length; i++)
          TrackTile(
            track: list[i].track,
            selected: list[i].track.path == player.currentPath,
            subtitle: '${list[i].track.artist} · ${list[i].reason}',
            onTap: () => player.playTracks(
              tracks.map((t) => t.path).toList(),
              start: i,
              name: 'Vorschläge',
            ),
          ),
      ],
    );
  }
}

/// Kennzahl-Kachel.
class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(value, style: theme.textTheme.headlineSmall),
        ],
      ),
    );
  }
}
