import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'library_page.dart';
import 'now_playing.dart';
import 'stats_page.dart';
import 'sync_page.dart';
import 'update_widgets.dart';
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
  _Dest('Ordner', Icons.folder_outlined, Icons.folder),
  _Dest(
    'Warteschlangen',
    Icons.queue_music_outlined,
    Icons.queue_music,
    'Queues',
  ),
  _Dest('Statistik', Icons.insights_outlined, Icons.insights),
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
    2 => const StatsPage(),
    3 => const SyncPage(),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: body),
          const SizedBox(width: 24),
          // Warteschlange als abgesetzte Karte neben der Bibliothek
          SizedBox(
            width: 360,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Card.filled(
                clipBehavior: Clip.antiAlias,
                child: const QueuesPage(compact: true),
              ),
            ),
          ),
        ],
      );
    }
    if (wide) {
      // Inhalt nicht an die Fensterränder kleben: mittig mit begrenzter Breite
      body = Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: sidePanel ? 1400 : 980),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: width >= 1000 ? 40 : 16),
            child: body,
          ),
        ),
      );
    }

    final scaffold = wide
        ? Scaffold(
            body: Column(
              children: [
                const UpdateBanner(),
                SyncBanner(onOpen: () => setState(() => _index = 3)),
                Expanded(
                  child: Row(
                    children: [
                      NavigationRail(
                        selectedIndex: _index,
                        onDestinationSelected: (i) =>
                            setState(() => _index = i),
                        labelType: NavigationRailLabelType.all,
                        groupAlignment: 0, // Navigation senkrecht mittig
                        destinations: [
                          for (final d in _dests)
                            NavigationRailDestination(
                              icon: Tooltip(
                                message: d.label,
                                child: Icon(d.icon),
                              ),
                              selectedIcon: Tooltip(
                                message: d.label,
                                child: Icon(d.selected),
                              ),
                              label: Text(d.label),
                            ),
                        ],
                      ),
                      Expanded(child: body),
                    ],
                  ),
                ),
                mini,
              ],
            ),
          )
        : Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  const UpdateBanner(),
                  SyncBanner(onOpen: () => setState(() => _index = 3)),
                  Expanded(child: body),
                ],
              ),
            ),
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
