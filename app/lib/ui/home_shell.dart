import 'package:flutter/gestures.dart';
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

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  final _libraryKey = GlobalKey<LibraryPageState>();
  final _queuesKey = GlobalKey<QueuesPageState>();

  /// Handy: Reiter per Wischen nach links/rechts wechseln. Die Statistik
  /// hat zwei Seiten (Hörgewohnheiten, Vorschläge), damit das Wischen
  /// durchläuft: Seite → Reiter unten.
  final _pages = PageController();
  static const _statsPage = 2;

  static int _destOf(int page) => page <= _statsPage
      ? page
      : page == _statsPage + 1
      ? _statsPage
      : page - 1;

  static int _pageOf(int dest) => dest <= _statsPage ? dest : dest + 1;

  /// Seiten der Wischreihe (Handy).
  List<Widget> _swipePages() => [
    _page(0),
    _page(1),
    StatsPage(
      view: 0,
      pages: _pages,
      firstPage: _statsPage,
      onSelectView: (v) => _goPage(_statsPage + v),
    ),
    StatsPage(
      view: 1,
      pages: _pages,
      firstPage: _statsPage,
      onSelectView: (v) => _goPage(_statsPage + v),
    ),
    _page(3),
    _page(4),
  ];

  /// War die Bildschirmtastatur zuletzt offen?
  bool _keyboard = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// Tastatur zugeklappt (z. B. per Zurück-Taste): Cursor aus dem Textfeld
  /// nehmen, sonst springt die Tastatur später (etwa nach dem Schließen des
  /// Wiedergabebildschirms) von selbst wieder auf.
  @override
  void didChangeMetrics() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final open = views.first.viewInsets.bottom > 0;
    if (_keyboard && !open) unfocusTextInput();
    _keyboard = open;
  }

  void _go(int i) => _goPage(_pageOf(i));

  void _goPage(int page) {
    setState(() => _index = _destOf(page));
    if (_pages.hasClients && (_pages.page?.round() ?? page) != page) {
      _pages.animateToPage(
        page,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// Zurücktaste (Android): im Ordner eine Ebene nach oben bis zum
  /// Musikordner; aus einem anderen Reiter zurück zu „Ordner“; sonst Ende.
  void _back() {
    if (_index == 0 && (_libraryKey.currentState?.handleBack() ?? false)) {
      return;
    }
    if (_index == 1 && (_queuesKey.currentState?.handleBack() ?? false)) {
      return;
    }
    if (_index != 0) return _go(0);
    SystemNavigator.pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pages.dispose();
    super.dispose();
  }

  void _openNowPlaying() => openNowPlaying(context);

  Widget _page(int index) => switch (index) {
    0 => LibraryPage(key: _libraryKey),
    1 => QueuesPage(key: _queuesKey),
    2 => const StatsPage(),
    3 => const SyncPage(),
    _ => const SettingsPage(),
  };

  Map<ShortcutActivator, VoidCallback> _shortcuts() => {
    const SingleActivator(LogicalKeyboardKey.f5): context.library.refresh,
    const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
      _go(0);
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

    if (!wide) {
      // z. B. Fenster schmaler gezogen: Seite zum gewählten Reiter
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pages.hasClients && _destOf(_pages.page?.round() ?? 0) != _index) {
          _pages.jumpToPage(_pageOf(_index));
        }
      });
    }
    Widget body = wide
        ? _page(_index)
        : ScrollConfiguration(
            // Wischen auch mit Maus/Touchpad (schmales Fenster am PC)
            behavior: ScrollConfiguration.of(context)
                .copyWith(dragDevices: PointerDeviceKind.values.toSet()),
            child: PageView(
              controller: _pages,
              onPageChanged: (p) => setState(() => _index = _destOf(p)),
              children: [for (final p in _swipePages()) _KeepAlive(p)],
            ),
          );
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
                  SyncBanner(onOpen: () => _go(3)),
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
                  onDestinationSelected: _go,
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: CallbackShortcuts(bindings: _shortcuts(), child: scaffold),
    );
  }
}

/// Hält eine Seite im PageView am Leben (Ordnerposition, Scrollstand).
class _KeepAlive extends StatefulWidget {
  const _KeepAlive(this.child);
  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
