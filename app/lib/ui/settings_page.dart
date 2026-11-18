import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/mync_core.dart';
import 'scope.dart';
import 'sound_sheets.dart';
import 'update_widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.settings;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Einstellungen', style: theme.textTheme.headlineSmall),
          ),
          const _Section('Bibliothek'),
          ListTile(
            leading: const Icon(Icons.folder),
            title: const Text('Musikordner'),
            subtitle: Text(s.musicDir),
            onTap: () async {
              final p = await getDirectoryPath(
                initialDirectory: s.musicDir,
                confirmButtonText: 'Wählen',
              );
              if (p != null && p.isNotEmpty) await s.setMusicDir(p);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.autorenew),
            title: const Text('Beim Start neu einlesen'),
            subtitle: const Text(
              'Neue, geänderte und gelöschte Dateien erkennen',
            ),
            value: s.scanOnStart,
            onChanged: s.setScanOnStart,
          ),
          ListTile(
            leading: const Icon(Icons.timer_off_outlined),
            title: const Text('Kurze Titel ausblenden'),
            subtitle: Text(
              s.hideShorterThan == 0
                  ? 'Alle anzeigen'
                  : 'Kürzer als ${s.hideShorterThan} s',
            ),
            trailing: DropdownButton<int>(
              value: s.hideShorterThan,
              onChanged: (v) => s.setHideShorterThan(v ?? 0),
              items: [
                for (final v in [0, 10, 30, 60])
                  DropdownMenuItem(
                    value: v,
                    child: Text(v == 0 ? 'Aus' : '< $v s'),
                  ),
              ],
            ),
          ),
          const _Section('Wiedergabe'),
          ListTile(
            leading: const Icon(Icons.equalizer),
            title: const Text('Equalizer und ReplayGain'),
            onTap: () => showEqualizer(context),
          ),
          ListTile(
            leading: const Icon(Icons.fast_forward),
            title: const Text('Spulen'),
            subtitle: Text(
              '${s.seekStep} s pro Schritt (Umschalt+Pfeil: 1 min)',
            ),
            trailing: DropdownButton<int>(
              value: s.seekStep,
              onChanged: (v) => s.setSeekStep(v ?? 10),
              items: [
                for (final v in [5, 10, 15, 30, 60])
                  DropdownMenuItem(value: v, child: Text('$v s')),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('Geschwindigkeit'),
            subtitle: Text('${s.speed.toStringAsFixed(2)}×'),
            onTap: () => showSpeedDialog(context),
          ),
          const _Section('Darstellung'),
          ListTile(
            leading: const Icon(Icons.dark_mode),
            title: const Text('Design'),
            trailing: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(value: ThemeMode.light, label: Text('Hell')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dunkel')),
              ],
              selected: {s.themeMode},
              onSelectionChanged: (v) => s.setThemeMode(v.first),
            ),
          ),
          const _Section('Tastenkürzel'),
          const _Shortcuts(),
          const _Section('Updates'),
          const UpdateSettings(),
          const _Section('Info'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('mync'),
            subtitle: Text('Kern ${_coreVersion()} · Daten in ${s.dataDir}'),
          ),
        ],
      ),
    );
  }

  static String _coreVersion() {
    try {
      return coreVersion();
    } catch (_) {
      return '?';
    }
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class _Shortcuts extends StatelessWidget {
  const _Shortcuts();

  static const rows = [
    ('Leertaste', 'Abspielen / Pause'),
    ('Strg + → / ←', 'Nächster / vorheriger Titel'),
    ('→ / ←', 'Spulen (Schrittweite einstellbar)'),
    ('Umschalt + → / ←', '1 min vor / zurück'),
    ('Strg + ↑ / ↓', 'Lauter / leiser'),
    ('Bild ↑ / Bild ↓', 'Vorheriges / nächstes Kapitel'),
    ('Strg + F', 'Suche'),
    ('Strg + R', 'Wiederholen umschalten'),
    ('Strg + S', 'Warteschlange mischen'),
    ('F5', 'Bibliothek neu einlesen'),
  ];

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Table(
      columnWidths: const {0: IntrinsicColumnWidth()},
      children: [
        for (final r in rows)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(56, 4, 24, 4),
                child: Text(
                  r.$1,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(r.$2),
              ),
            ],
          ),
      ],
    ),
  );
}
