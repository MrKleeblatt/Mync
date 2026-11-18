import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'library_page.dart';
import 'now_playing.dart';
import 'placeholder_screen.dart';
import 'playlists_page.dart';
import 'queues_page.dart';
import 'scope.dart';
import 'settings_page.dart';

class _Dest {
  const _Dest(this.label, this.icon, this.selected, [this.short]);
  final String label;

  /// Kurze Beschriftung für die untere Leiste auf schmalen Bildschirmen.
  final String? short;
  final IconData icon;
  final IconData selected;
}

const _dests = [
  _Dest('Bibliothek', Icons.library_music_outlined, Icons.library_music),
  _Dest(
    'Warteschlangen',
    Icons.queue_music_outlined,
    Icons.queue_music,
    'Queues',
  ),
  _Dest(
    'Playlists',
    Icons.featured_play_list_outlined,
    Icons.featured_play_list,
  ),
  _Dest('Sync', Icons.sync_alt_outlined, Icons.sync_alt),
  _Dest('Einstellungen', Icons.settings_outlined, Icons.settings, 'Optionen'),
];

/// Grundgerüst: Navigation links (Desktop) bzw. unten (Handy), Wiedergabe-
/// leiste am unteren Rand, auf breiten Fenstern die Warteschlange rechts.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  final _libraryKey = GlobalKey<LibraryPageState>();

  void _openNowPlaying() => openNowPlaying(context);

  Widget _page(bool sidePanel) => switch (_index) {
    0 => LibraryPage(key: _libraryKey),
    1 => const QueuesPage(),
    2 => const PlaylistsPage(),
    3 => const PlaceholderScreen(
      icon: Icons.sync_alt,
      title: 'Sync mit dem Handy',
      text: 'Hier erscheinen eingehende Änderungen vom Handy zum Annehmen oder Ablehnen (Meilenstein M1).',
    ),
    _ => const SettingsPage(),
  };

  Map<ShortcutActivator, VoidCallback> _shortcuts() => {
    const SingleActivator(LogicalKeyboardKey.f5): context.library.refresh,
    const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
      setState(() => _index = 0);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _libraryKey.currentState?.focusSearch(),
      );
    },
  };

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 720;
    final sidePanel = width >= 1200 && _index == 0;
    final mini = MiniPlayer(onOpen: _openNowPlaying);

    Widget body = _page(sidePanel);
    if (sidePanel) {
      body = Row(
        children: [
          Expanded(child: body),
          const VerticalDivider(width: 1),
          const SizedBox(width: 380, child: QueuesPage(compact: true)),
        ],
      );
    }

    final scaffold = wide
        ? Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      NavigationRail(
                        selectedIndex: _index,
                        onDestinationSelected: (i) =>
                            setState(() => _index = i),
                        labelType: NavigationRailLabelType.all,
                        destinations: [
                          for (final d in _dests)
                            NavigationRailDestination(
                              icon: Icon(d.icon),
                              selectedIcon: Icon(d.selected),
                              label: Text(d.label),
                            ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: body),
                    ],
                  ),
                ),
                mini,
              ],
            ),
          )
        : Scaffold(
            body: SafeArea(child: body),
            bottomNavigationBar: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                mini,
                NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  destinations: [
                    for (final d in _dests)
                      NavigationDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selected),
                        label: d.short ?? d.label,
                      ),
                  ],
                ),
              ],
            ),
          );

    return CallbackShortcuts(bindings: _shortcuts(), child: scaffold);
  }
}
