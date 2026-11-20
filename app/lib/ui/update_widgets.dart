import 'package:flutter/material.dart';

import '../update/update_service.dart';
import 'scope.dart';

/// Hinweisleiste oben: Update verfügbar / wird geladen / installiert.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final u = UpdateService.instance;
    if (u == null || !u.supported) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) {
        final theme = Theme.of(context);
        final info = u.available;
        Widget? content;
        List<Widget> actions = const [];
        switch (u.state) {
          case UpdateState.available when info != null:
            content = Text(
              'Update auf ${info.version} verfügbar – ${formatBytes(info.downloadBytes)} '
              '(${info.missing.length} von ${info.files.length} Dateien)',
            );
            actions = [
              TextButton(
                onPressed: () => showUpdateDetails(context),
                child: const Text('Details'),
              ),
              FilledButton(
                onPressed: u.install,
                child: const Text('Installieren'),
              ),
            ];
          case UpdateState.downloading:
            content = Row(
              children: [
                const Text('Update wird geladen …'),
                const SizedBox(width: 12),
                Expanded(child: LinearProgressIndicator(value: u.progress)),
              ],
            );
          case UpdateState.installed:
            content = Text('Version ${u.installedVersion} installiert.');
            actions = [
              FilledButton(
                onPressed: u.restart,
                child: const Text('Jetzt neu starten'),
              ),
            ];
          default:
            return const SizedBox.shrink();
        }
        return Material(
          color: theme.colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                Icon(
                  Icons.system_update,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                    child: content,
                  ),
                ),
                ...[
                  for (final a in actions)
                    Padding(padding: const EdgeInsets.only(left: 8), child: a),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

Future<void> showUpdateDetails(BuildContext context) {
  final u = UpdateService.instance!;
  final info = u.available;
  if (info == null) return Future.value();
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('mync ${info.version}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Installiert: ${u.currentVersion}'),
              Text(
                'Teil-Update: ${info.missing.length} von ${info.files.length} Dateien, '
                '${formatBytes(info.downloadBytes)} statt ${formatBytes(info.fullBytes)}',
              ),
              Text(
                info.signed
                    ? 'Signatur geprüft ✓'
                    : 'Nicht signiert (nur Prüfsummen geprüft)',
              ),
              if (info.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Änderungen',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                SelectableText(info.notes.trim()),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Später'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            u.install();
          },
          child: const Text('Installieren'),
        ),
      ],
    ),
  );
}

/// Abschnitt „Updates“ in den Einstellungen.
class UpdateSettings extends StatelessWidget {
  const UpdateSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final u = UpdateService.instance;
    final s = context.settings;
    if (u == null || !u.supported) {
      return ListTile(
        leading: const Icon(Icons.system_update),
        title: const Text('Updates'),
        subtitle: Text(
          u?.unsupportedReason ??
              'Auf diesem Gerät über die APK aus den GitHub-Releases.',
        ),
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([u, s]),
      builder: (context, _) => Column(
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text('Installiert: mync ${u.currentVersion}'),
            subtitle: Text(
              u.message ??
                  (u.signatureRequired
                      ? 'Updates werden auf ihre Signatur geprüft.'
                      : ''),
            ),
            trailing:
                u.state == UpdateState.checking ||
                    u.state == UpdateState.downloading
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : OutlinedButton(
                    onPressed: () => u.check(manual: true),
                    child: const Text('Jetzt suchen'),
                  ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.update),
            title: const Text('Automatisch nach Updates suchen'),
            subtitle: const Text(
              'Beim Start und alle 6 Stunden (GitHub-Releases)',
            ),
            value: s.updateCheck,
            onChanged: s.setUpdateCheck,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.download_for_offline_outlined),
            title: const Text(
              'Updates automatisch herunterladen und installieren',
            ),
            subtitle: const Text(
              'Nur geänderte Dateien; aktiv nach dem nächsten Start',
            ),
            value: s.autoUpdate,
            onChanged: s.updateCheck ? s.setAutoUpdate : null,
          ),
          if (u.state == UpdateState.available)
            ListTile(
              leading: const Icon(Icons.new_releases_outlined),
              title: Text('Version ${u.available!.version} verfügbar'),
              subtitle: Text(
                '${formatBytes(u.available!.downloadBytes)} herunterzuladen',
              ),
              trailing: FilledButton(
                onPressed: u.install,
                child: const Text('Installieren'),
              ),
              onTap: () => showUpdateDetails(context),
            ),
          if (u.state == UpdateState.installed)
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: Text('Version ${u.installedVersion} installiert'),
              trailing: FilledButton(
                onPressed: u.restart,
                child: const Text('Neu starten'),
              ),
            ),
        ],
      ),
    );
  }
}
