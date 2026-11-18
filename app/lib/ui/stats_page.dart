import 'package:flutter/material.dart';

import '../library/track.dart';
import '../stats/stats.dart';
import '../stats/suggestions.dart';
import 'bar_chart.dart';
import 'scope.dart';
import 'track_actions.dart';
import 'track_list.dart';

/// Hörstatistik („Diesen Monat am meisten gehört“ …) und Vorschläge.
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  StatsRange _range = StatsRange.thisMonth;
  List<Suggestion>? _suggestions;
  int _suggestionsFor = -1;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text('Statistik', style: theme.textTheme.headlineSmall),
        ),
        TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Hörgewohnheiten'),
            Tab(text: 'Vorschläge'),
          ],
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([context.player, context.library]),
            builder: (context, _) => TabBarView(
              controller: _tabs,
              children: [_statsView(context), _suggestionsView(context)],
            ),
          ),
        ),
      ],
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
                'Am meisten gehört · ${_range.label}',
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
                tooltip: 'Zufällig abspielen',
                onPressed: () =>
                    runTrackAction(context, TrackAction.shuffle, topTracks),
                icon: const Icon(Icons.shuffle),
              ),
              IconButton(
                tooltip: 'In neuer Warteschlange',
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
              'In diesem Zeitraum noch nichts gehört. Ein Titel zählt, sobald er mindestens 30 Sekunden '
              '(bzw. die Hälfte) gelaufen ist.',
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
              ),
            ),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, c) {
            final hourChart = BarChart(
              title: 'Hörzeit nach Tageszeit',
              values: s.byHour,
              labels: [for (var h = 0; h < 24; h++) '$h Uhr'],
              labelEvery: 6,
              format: formatListening,
            );
            final dayChart = BarChart(
              title: 'Hörzeit nach Wochentag',
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
        Text('Meistgehörte Ordner', style: theme.textTheme.titleMedium),
        for (final f in s.topFolders.take(8))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder),
            title: Text(f.folder.isEmpty ? 'Musik' : f.folder.split('/').last),
            subtitle: Text(
              '${f.folder.isEmpty ? '/' : f.folder} · ${f.plays}× · ${formatListening(f.listenedMs)}',
            ),
            trailing: IconButton(
              tooltip: 'Ordner zufällig abspielen',
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
    final theme = Theme.of(context);
    final player = context.player;
    final list = _currentSuggestions(context);
    final tracks = list.map((s) => s.track).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(
          'Aus der eigenen Bibliothek, passend zu den Hörgewohnheiten: lange nicht Gehörtes, '
          'Unbekanntes aus viel gehörten Ordnern, Titel für diese Tageszeit. '
          'Oft übersprungene Titel bleiben außen vor.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: tracks.isEmpty
                  ? null
                  : () => player.playTracks(tracks.map((t) => t.path).toList()),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Mix abspielen'),
            ),
            OutlinedButton.icon(
              onPressed: tracks.isEmpty
                  ? null
                  : () => player.newQueue(
                      paths: tracks.map((t) => t.path).toList(),
                      name: 'Vorschläge',
                    ),
              icon: const Icon(Icons.add_to_queue),
              label: const Text('In neuer Warteschlange'),
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
            child: Text('Keine Titel in der Bibliothek.'),
          ),
        for (var i = 0; i < list.length; i++)
          TrackTile(
            track: list[i].track,
            selected: list[i].track.path == player.currentPath,
            subtitle: '${list[i].track.artist} · ${list[i].reason}',
            onTap: () =>
                player.playTracks(tracks.map((t) => t.path).toList(), start: i),
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
