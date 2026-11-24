import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'dart:io';

import '../backup/backup.dart';
import '../core/music_fs.dart';
import '../log.dart';
import 'folder_picker.dart';
import 'scope.dart';
import 'log_page.dart';
import 'status_line.dart';
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
          const _Section('Ordner'),
          ListTile(
            leading: const Icon(Icons.folder),
            title: const Text('Musikordner'),
            subtitle: Text(
              '${folderLabel(s.musicDir)}\nWird mit dem Handy abgeglichen',
            ),
            isThreeLine: true,
            onTap: () async {
              final old = s.musicDir;
              final p = await pickMusicFolder(initial: old);
              if (p == null || p == old) return;
              await s.setMusicDir(p);
              if (!s.extraMusicDirs.contains(old)) await MusicFs.release(old);
            },
          ),
          for (final d in s.extraMusicDirs)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(
                folderLabel(d)
                        .split('/')
                        .where((x) => x.isNotEmpty)
                        .lastOrNull ??
                    d,
              ),
              subtitle: Text(folderLabel(d)),
              trailing: IconButton(
                tooltip: 'Entfernen',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () async {
                  await s.setExtraMusicDirs([...s.extraMusicDirs]..remove(d));
                  if (d != s.musicDir) await MusicFs.release(d);
                },
              ),
            ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('Ordner hinzufügen'),
            onTap: () async {
              final p = await pickMusicFolder(confirm: 'Hinzufügen');
              if (p == null) return;
              if (p == s.musicDir || s.extraMusicDirs.contains(p)) return;
              await s.setExtraMusicDirs([...s.extraMusicDirs, p]);
            },
          ),
          ListTile(
            leading: const Icon(Icons.block),
            title: Text('Ausschlüsse'),
            subtitle: s.excludes.isEmpty
                ? null
                : Text(
                    s.excludes.join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
            onTap: () => _editExcludes(context),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.autorenew),
            title: const Text('Beim Start einlesen'),
            value: s.scanOnStart,
            onChanged: s.setScanOnStart,
          ),
          ListTile(
            leading: const Icon(Icons.timer_off_outlined),
            title: const Text('Kurze Titel ausblenden'),
            subtitle: const Text('Z. B. Jingles, Intros'),
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
            title: const Text('Klang'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showSoundSheet(context),
          ),
          ListTile(
            leading: const Icon(Icons.fast_forward),
            title: const Text('Spulen'),
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
            title: const Text('Tempo'),
            trailing: Text(
              '${s.speed.toStringAsFixed(2)}×'
              '${s.pitch == 0 ? '' : ' · ${s.pitch > 0 ? '+' : ''}${s.pitch.toStringAsFixed(1)}'}',
            ),
            onTap: () => showSpeedDialog(context),
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: const Text('Überblenden'),
            subtitle: const Text('Titelübergänge'),
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
              title: const Text('Nicht im Album'),
              subtitle: const Text('Alben lückenlos spielen'),
              value: s.crossfadeSkipAlbum,
              onChanged: s.setCrossfadeSkipAlbum,
            ),
          SwitchListTile(
            secondary: const Icon(Icons.sign_language),
            title: const Text('Applaus überspringen'),
            subtitle: const Text('Bei Live-Aufnahmen'),
            value: s.autoSkipApplause,
            onChanged: s.setAutoSkipApplause,
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: const Text('Position merken'),
            subtitle: const Text('Hörbücher an derselben Stelle fortsetzen'),
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
          SwitchListTile(
            secondary: const Icon(Icons.graphic_eq),
            title: const Text('Visualisierung'),
            subtitle: const Text('Wellenform hinter der Zeitleiste'),
            value: s.visualizer,
            onChanged: s.setVisualizer,
          ),
          // Tastenkürzel nur am Rechner (auf dem Handy gibt es keine Tastatur)
          if (!Platform.isAndroid) ...[
            const _Section('Tastenkürzel'),
            const _Shortcuts(),
          ],
          const _Section('Sicherung'),
          const _BackupSection(),
          const _Section('Info'),
          ListenableBuilder(
            listenable: appLog,
            builder: (context, _) => ListTile(
              leading: Badge(
                isLabelVisible: appLog.problems > 0,
                label: Text('${appLog.problems}'),
                child: const Icon(Icons.receipt_long_outlined),
              ),
              title: const Text('Logbuch'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openLogPage(context),
            ),
          ),
          const UpdateSettings(),
        ],
      ),
    );
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
    ('Leertaste', 'Play / Pause'),
    ('Strg + → / ←', 'Titel ±'),
    ('→ / ←', 'Spulen'),
    ('Umschalt + → / ←', '± 1 min'),
    ('Strg + ↑ / ↓', 'Lautstärke'),
    ('Bild ↑ / Bild ↓', 'Kapitel ±'),
    ('Strg + F', 'Suche'),
    ('Strg + R', 'Wiederholen'),
    ('Strg + S', 'Mischen'),
    ('F5', 'Einlesen'),
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
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 5,
              maxLines: 10,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '*.wav\nHörproben\nPodcasts/**/*.mp3',
              ),
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
            title: const Text('Mit Kopplungen'),
            subtitle: const Text('Enthält geheime Schlüssel'),
            secondary: const Tooltip(
              message: 'Enthält geheime Schlüssel',
              child: Icon(Icons.key),
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

/// Sicherung erstellen und wiederherstellen, mit Zustandszeile.
class _BackupSection extends StatefulWidget {
  const _BackupSection();

  @override
  State<_BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends State<_BackupSection> {
  OpStatus? _status;

  void _report(OpStatus s) {
    if (mounted) setState(() => _status = s);
  }

  @override
  Widget build(BuildContext context) {
    final busy = _status?.busy ?? false;
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.save_alt),
          title: const Text('Sichern'),
          subtitle: const Text('Einstellungen, Listen, Statistik'),
          enabled: !busy,
          onTap: () => _createBackup(context, _report),
        ),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore),
          title: const Text('Wiederherstellen'),
          subtitle: const Text('Ersetzt den aktuellen Stand'),
          enabled: !busy,
          onTap: () => _restoreBackup(context, _report),
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: StatusLine(_status, dense: true),
            ),
          ),
      ],
    );
  }
}

Future<void> _createBackup(
  BuildContext context,
  void Function(OpStatus) report,
) async {
  final settings = context.settings;
  final player = context.player;
  final pairings = await _askPairings(context, 'Sichern', 'Speichern');
  if (pairings == null) return;
  final d = DateTime.now();
  final name =
      'mync-${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.${Backup.extension}';
  if (Platform.isAndroid) {
    // Ohne Speicherberechtigung: erst in den Cache, dann „Speichern unter“
    // des Systems (Downloads, Drive, …)
    await runStatus<int?>(
      report,
      () async {
        await player.saveNow();
        final tmp = await Backup.create(
          settings,
          '${settings.cacheDir}/$name',
          pairings: pairings,
        );
        try {
          final bytes = await tmp.readAsBytes();
          final uri = await MusicFs.saveDocument(name, bytes);
          return uri == null ? null : bytes.length;
        } finally {
          await tmp.delete();
        }
      },
      busy: 'Sichere …',
      ok: (n) => n == null ? 'Abgebrochen' : formatSize(n),
      failText: 'Fehlgeschlagen',
      logWhat: 'Sicherung',
    );
    return;
  }
  String? path;
  {
    final loc = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'mync-Sicherung', extensions: [Backup.extension]),
      ],
    );
    path = loc?.path;
  }
  if (path == null) return;
  final target = path;
  await runStatus<File>(
    report,
    () async {
      await player.saveNow();
      return Backup.create(settings, target, pairings: pairings);
    },
    busy: 'Sichere …',
    ok: (f) => 'Gesichert: ${f.path} (${formatSize(f.lengthSync())})',
    failText: 'Sicherung fehlgeschlagen',
    logWhat: 'Sicherung',
  );
}

String formatSize(int b) => b >= 1e6
    ? '${(b / 1e6).toStringAsFixed(1).replaceAll('.', ',')} MB'
    : '${(b / 1e3).ceil()} kB';

Future<void> _restoreBackup(
  BuildContext context,
  void Function(OpStatus) report,
) async {
  final settings = context.settings;
  final player = context.player;
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'mync-Sicherung', extensions: [Backup.extension]),
    ],
  );
  if (file == null || !context.mounted) return;
  final BackupInfo info;
  try {
    info = await Backup.inspect(file.path);
  } catch (e, st) {
    logError('Sicherung nicht lesbar: ${file.name}', e, st);
    report(const OpStatus.error('Ungültige Datei'));
    return;
  }
  if (!context.mounted) return;
  final c = info.created;
  final pairings = await _askPairings(
    context,
    '${c.day}.${c.month}.${c.year}, '
        '${c.hour}:${c.minute.toString().padLeft(2, '0')}',
    'Wiederherstellen',
  );
  if (pairings == null) return;
  // ab jetzt nichts mehr speichern, sonst überschreibt das Beenden die Sicherung
  player.frozen = true;
  final done = await runStatus<bool>(
    report,
    () async {
      await Backup.restore(
        settings,
        file.path,
        pairings: pairings && info.hasPairings,
      );
      return true;
    },
    busy: 'Stelle wieder her …',
    ok: (_) => 'Wiederhergestellt',
    failText: 'Fehlgeschlagen',
    logWhat: 'Wiederherstellen',
  );
  if (done == null) {
    player.frozen = false;
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Icon(Icons.check_circle_outline, size: 40),
      content: Text(
        Platform.isAndroid ? 'Bitte mync neu öffnen.' : 'mync startet neu.',
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
