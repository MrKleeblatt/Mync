import 'package:flutter/material.dart';

import 'screens/library_screen.dart';
import 'screens/placeholder_screen.dart';
import 'settings.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final settings = await AppSettings.load();
  runApp(MyncApp(settings: settings));
}

class MyncApp extends StatelessWidget {
  const MyncApp({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2E7D6B),
            brightness: b,
          ),
          useMaterial3: true,
        );
    return MaterialApp(
      title: 'mync',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: HomeShell(settings: settings),
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const _destinations = [
  _Destination('Bibliothek', Icons.library_music_outlined, Icons.library_music),
  _Destination('Warteschlangen', Icons.queue_music_outlined, Icons.queue_music),
  _Destination('Sync', Icons.sync_alt_outlined, Icons.sync_alt),
];

/// Grundgerüst: Navigationsleiste links (breite Fenster) oder unten (Handy).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  Widget _page() => switch (_index) {
        0 => LibraryScreen(settings: widget.settings),
        1 => const PlaceholderScreen(
            icon: Icons.queue_music,
            title: 'Warteschlangen',
            text: 'Mehrere Warteschlangen, die sich ihre Position merken – '
                'kommt mit dem Player (Meilenstein M3).',
          ),
        _ => const PlaceholderScreen(
            icon: Icons.sync_alt,
            title: 'Sync-Inbox',
            text: 'Hier erscheinen eingehende Änderungen vom anderen Gerät '
                'zum Annehmen oder Ablehnen (Meilenstein M1).',
          ),
      };

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _page()),
          ],
        ),
      );
    }
    return Scaffold(
      body: SafeArea(child: _page()),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}
