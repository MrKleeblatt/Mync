import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../log.dart';
import '../update/update_service.dart';
import 'scope.dart';
import 'status_line.dart';

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
          case UpdateState.available when info != null && !u.canInstall:
            // Nix/AppImage: nur Hinweis, wie man aktualisiert
            content = Text(
              'mync ${info.version} ist verfügbar – ${u.externalUpdateHint}',
            );
            actions = [
              TextButton(
                onPressed: () => showUpdateDetails(context),
                child: const Text('Details'),
              ),
              const ExternalUpdateButton(),
            ];
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
              if (u.canInstall)
                Text(
                  'Teil-Update: ${info.missing.length} von ${info.files.length} Dateien, '
                  '${formatBytes(info.downloadBytes)} statt ${formatBytes(info.fullBytes)}',
                )
              else
                SelectableText(u.externalUpdateHint),
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
        if (u.canInstall)
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              u.install();
            },
            child: const Text('Installieren'),
          )
        else
          const ExternalUpdateButton(),
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
            subtitle: u.message == null
                ? Text(
                    u.signatureRequired
                        ? 'Updates werden auf ihre Signatur geprüft.'
                        : '',
                  )
                : StatusLine(
                    OpStatus(switch (u.state) {
                      UpdateState.checking ||
                      UpdateState.downloading => OpKind.busy,
                      UpdateState.error => OpKind.error,
                      _ => OpKind.ok,
                    }, u.message!),
                    dense: true,
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
          if (!u.canInstall)
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(
                u.isAppImage ? 'Läuft als AppImage' : 'Installiert über Nix',
              ),
              subtitle: Text(
                'mync meldet neue Versionen – ${u.externalUpdateHint}.',
              ),
              trailing: const ExternalUpdateButton(),
            ),
          if (u.canInstall)
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
                u.canInstall
                    ? '${formatBytes(u.available!.downloadBytes)} herunterzuladen'
                    : u.externalUpdateHint,
              ),
              trailing: u.canInstall
                  ? FilledButton(
                      onPressed: u.install,
                      child: const Text('Installieren'),
                    )
                  : const ExternalUpdateButton(),
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

/// Nix: Befehl kopieren, AppImage: Release-Seite öffnen.
class ExternalUpdateButton extends StatelessWidget {
  const ExternalUpdateButton({super.key});

  @override
  Widget build(BuildContext context) {
    final u = UpdateService.instance;
    if (u != null && u.isAppImage) {
      return FilledButton.icon(
        onPressed: u.openReleasePage,
        icon: const Icon(Icons.open_in_new, size: 18),
        label: const Text('Release öffnen'),
      );
    }
    return FilledButton.icon(
      onPressed: () async {
        await Clipboard.setData(
          const ClipboardData(text: UpdateService.nixUpgradeCommand),
        );
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(const SnackBar(content: Text('Befehl kopiert')));
        }
      },
      icon: const Icon(Icons.copy, size: 18),
      label: const Text('Befehl kopieren'),
    );
  }
}
