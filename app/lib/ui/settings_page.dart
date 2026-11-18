import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'dart:io';

import '../backup/backup.dart';
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
            subtitle: Text(
              '${s.musicDir}\nHauptordner, wird mit dem Handy abgeglichen',
            ),
            isThreeLine: true,
            onTap: () async {
              final p = await getDirectoryPath(
                initialDirectory: s.musicDir,
                confirmButtonText: 'Wählen',
              );
              if (p != null && p.isNotEmpty) await s.setMusicDir(p);
            },
          ),
          for (final d in s.extraMusicDirs)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(
                d.split('/').where((x) => x.isNotEmpty).lastOrNull ?? d,
              ),
              subtitle: Text(
                '$d\nWeiterer Ordner, erscheint in der Bibliothek als eigener Ordner',
              ),
              isThreeLine: true,
              trailing: IconButton(
                tooltip: 'Ordner entfernen (Dateien bleiben erhalten)',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () =>
                    s.setExtraMusicDirs([...s.extraMusicDirs]..remove(d)),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('Weiteren Musikordner hinzufügen …'),
            onTap: () async {
              final p = await getDirectoryPath(confirmButtonText: 'Hinzufügen');
              if (p == null || p.isEmpty) return;
              if (p == s.musicDir || s.extraMusicDirs.contains(p)) return;
              await s.setExtraMusicDirs([...s.extraMusicDirs, p]);
            },
          ),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Ausschlüsse'),
            subtitle: Text(
              s.excludes.isEmpty
                  ? 'Keine – alle Audiodateien werden eingelesen'
                  : s.excludes.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _editExcludes(context),
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
            leading: const Icon(Icons.tune),
            title: const Text('Klang (Balance, ReplayGain)'),
            onTap: () => showSoundSheet(context),
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
            title: const Text('Geschwindigkeit und Tonhöhe'),
            subtitle: Text(
              '${s.speed.toStringAsFixed(2)}×'
              '${s.pitch == 0 ? '' : ' · ${s.pitch > 0 ? '+' : ''}${s.pitch.toStringAsFixed(1)} Halbtöne'}',
            ),
            onTap: () => showSpeedDialog(context),
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: const Text('Überblenden'),
            subtitle: const Text(
              'Ende und Anfang zweier Titel ineinander blenden',
            ),
            trailing: DropdownButton<int>(
              value: s.crossfadeSec,
              onChanged: (v) => s.setCrossfadeSec(v ?? 0),
              items: [
                for (final v in [0, 2, 4, 6, 8, 10, 12])
                  DropdownMenuItem(
                    value: v,
                    child: Text(v == 0 ? 'Aus' : '$v s'),
                  ),
              ],
            ),
          ),
          if (s.crossfadeSec > 0)
            SwitchListTile(
              secondary: const Icon(Icons.album_outlined),
              title: const Text('Nicht innerhalb eines Albums'),
              subtitle: const Text(
                'Aufeinanderfolgende Albumtitel lückenlos spielen',
              ),
              value: s.crossfadeSkipAlbum,
              onChanged: s.setCrossfadeSkipAlbum,
            ),
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: const Text('Position je Datei merken'),
            subtitle: const Text(
              'Hörbücher und lange Titel später an derselben Stelle fortsetzen',
            ),
            trailing: DropdownButton<int>(
              value: s.resumeMinutes,
              onChanged: (v) => s.setResumeMinutes(v ?? 0),
              items: [
                for (final v in [0, 10, 20, 30, 60])
                  DropdownMenuItem(
                    value: v,
                    child: Text(v == 0 ? 'Aus' : 'ab $v min'),
                  ),
              ],
            ),
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
          const _Section('Sicherung'),
          ListTile(
            leading: const Icon(Icons.save_alt),
            title: const Text('Sicherung erstellen …'),
            subtitle: const Text(
              'Einstellungen, Warteschlangen, Hörstatistik, gemerkte '
              'Positionen und Kopplungen in eine Datei',
            ),
            onTap: () => _createBackup(context),
          ),
          ListTile(
            leading: const Icon(Icons.settings_backup_restore),
            title: const Text('Sicherung wiederherstellen …'),
            subtitle: const Text(
              'Ersetzt den aktuellen Stand; mync startet neu',
            ),
            onTap: () => _restoreBackup(context),
          ),
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

Future<void> _editExcludes(BuildContext context) async {
  final s = context.settings;
  final ctrl = TextEditingController(text: s.excludes.join('\n'));
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Ausschlüsse'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ein Muster pro Zeile. Ohne „/“ gilt es für jeden Datei- oder '
              'Ordnernamen, mit „/“ für den Pfad ab dem Musikordner. '
              '„*“ steht für beliebige Zeichen, „**“ auch über Ordner hinweg.',
            ),
            const SizedBox(height: 8),
            Text(
              'Beispiele: *.wav · Hörproben · Podcasts/Alt · Hörbücher/**/*.m4b',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 5,
              maxLines: 10,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Übernehmen'),
        ),
      ],
    ),
  );
  if (ok == true) await s.setExcludes(ctrl.text.split('\n'));
  // nicht sofort entsorgen: der Dialog blendet noch aus
  Future<void>.delayed(const Duration(seconds: 1), ctrl.dispose);
}

Future<bool?> _askPairings(BuildContext context, String title, String action) {
  var pairings = true;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: CheckboxListTile(
            value: pairings,
            onChanged: (v) => setState(() => pairings = v ?? false),
            title: const Text('Kopplungen einschließen'),
            subtitle: const Text(
              'Enthält den geheimen Schlüssel dieses Geräts – die Datei '
              'sicher aufbewahren.',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, pairings),
            child: Text(action),
          ),
        ],
      ),
    ),
  );
}

Future<void> _createBackup(BuildContext context) async {
  final settings = context.settings;
  final player = context.player;
  final messenger = ScaffoldMessenger.of(context);
  final pairings = await _askPairings(
    context,
    'Sicherung erstellen',
    'Speichern unter …',
  );
  if (pairings == null) return;
  final d = DateTime.now();
  final name =
      'mync-${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.${Backup.extension}';
  String? path;
  if (Platform.isAndroid) {
    path = '/storage/emulated/0/Download/$name';
  } else {
    final loc = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'mync-Sicherung', extensions: [Backup.extension]),
      ],
    );
    path = loc?.path;
  }
  if (path == null) return;
  try {
    await player.saveNow();
    final f = await Backup.create(settings, path, pairings: pairings);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Gesichert: ${f.path} (${formatSize(f.lengthSync())})'),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Sicherung fehlgeschlagen: $e')),
    );
  }
}

String formatSize(int b) => b >= 1e6
    ? '${(b / 1e6).toStringAsFixed(1).replaceAll('.', ',')} MB'
    : '${(b / 1e3).ceil()} kB';

Future<void> _restoreBackup(BuildContext context) async {
  final settings = context.settings;
  final player = context.player;
  final messenger = ScaffoldMessenger.of(context);
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'mync-Sicherung', extensions: [Backup.extension]),
    ],
  );
  if (file == null || !context.mounted) return;
  final BackupInfo info;
  try {
    info = await Backup.inspect(file.path);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return;
  }
  if (!context.mounted) return;
  final c = info.created;
  final pairings = await _askPairings(
    context,
    'Sicherung vom ${c.day}.${c.month}.${c.year}, '
        '${c.hour}:${c.minute.toString().padLeft(2, '0')} wiederherstellen?',
    'Wiederherstellen',
  );
  if (pairings == null) return;
  try {
    // ab jetzt nichts mehr speichern, sonst überschreibt das Beenden die Sicherung
    player.frozen = true;
    await Backup.restore(
      settings,
      file.path,
      pairings: pairings && info.hasPairings,
    );
  } catch (e) {
    player.frozen = false;
    messenger.showSnackBar(
      SnackBar(content: Text('Wiederherstellen fehlgeschlagen: $e')),
    );
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Wiederhergestellt'),
      content: Text(
        Platform.isAndroid
            ? 'mync wird jetzt beendet. Bitte die App wieder öffnen.'
            : 'mync startet jetzt neu.',
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  if (!Platform.isAndroid) {
    await Process.start(
      Platform.resolvedExecutable,
      const [],
      mode: ProcessStartMode.detached,
    );
  }
  exit(0);
}
