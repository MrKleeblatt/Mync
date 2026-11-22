import 'dart:io';

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
        final details = IconButton(
          tooltip: 'Details',
          onPressed: () => showUpdateDetails(context),
          icon: const Icon(Icons.info_outline),
        );
        switch (u.state) {
          case UpdateState.available when info != null && !u.canInstall:
            content = Text('mync ${info.version}');
            actions = [details, const ExternalUpdateButton()];
          case UpdateState.available when info != null:
            content = Text('mync ${info.version} · ${info.summary}');
            actions = [
              details,
              FilledButton.icon(
                onPressed: u.install,
                icon: const Icon(Icons.download),
                label: const Text('Installieren'),
              ),
            ];
          case UpdateState.downloading:
            content = LinearProgressIndicator(value: u.progress);
          case UpdateState.installed:
            content = Text('mync ${u.installedVersion} installiert');
            actions = [
              FilledButton.icon(
                onPressed: u.restart,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Neu starten'),
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
                    Padding(padding: const EdgeInsets.only(left: 4), child: a),
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
      title: Row(
        children: [
          Text('${u.currentVersion} → ${info.version}'),
          const Spacer(),
          Tooltip(
            message: info.signed ? 'Signiert' : 'Nicht signiert',
            child: Icon(
              info.signed ? Icons.verified_user : Icons.gpp_maybe_outlined,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (u.canInstall)
                Text(info.summary)
              else
                SelectableText(u.externalUpdateHint),
              if (info.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                SelectableText(info.notes.trim()),
              ],
            ],
          ),
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'Später',
          onPressed: () => Navigator.pop(ctx),
          icon: const Icon(Icons.close),
        ),
        if (u.canInstall)
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              u.install();
            },
            icon: const Icon(Icons.download),
            label: const Text('Installieren'),
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
    if (u == null || !u.supported) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([u, s]),
      builder: (context, _) => Column(
        children: [
          ListTile(
            leading: const Icon(Icons.system_update),
            title: Text('mync ${u.currentVersion}'),
            subtitle: u.message == null
                ? null
                : StatusLine(
                    OpStatus(switch (u.state) {
                      UpdateState.checking ||
                      UpdateState.downloading => OpKind.busy,
                      UpdateState.error => OpKind.error,
                      _ => OpKind.ok,
                    }, u.message!),
                    dense: true,
                  ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (u.state == UpdateState.available) ...[
                  IconButton(
                    tooltip: 'Details',
                    onPressed: () => showUpdateDetails(context),
                    icon: const Icon(Icons.info_outline),
                  ),
                  if (u.canInstall)
                    FilledButton.icon(
                      onPressed: u.install,
                      icon: const Icon(Icons.download),
                      label: const Text('Installieren'),
                    )
                  else
                    const ExternalUpdateButton(),
                ] else if (u.state == UpdateState.installed)
                  FilledButton.icon(
                    onPressed: u.restart,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Neu starten'),
                  )
                else if (u.state == UpdateState.checking ||
                    u.state == UpdateState.downloading)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    tooltip: 'Suchen',
                    onPressed: () => u.check(manual: true),
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.update),
            title: const Text('Automatisch suchen'),
            value: s.updateCheck,
            onChanged: s.setUpdateCheck,
          ),
          if (u.canInstall && !Platform.isAndroid)
            SwitchListTile(
              secondary: const Icon(Icons.download_for_offline_outlined),
              title: const Text('Automatisch installieren'),
              value: s.autoUpdate,
              onChanged: s.updateCheck ? s.setAutoUpdate : null,
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
        icon: const Icon(Icons.open_in_new),
        label: const Text('Release öffnen'),
      );
    }
    return IconButton.filled(
      tooltip: UpdateService.nixUpgradeCommand,
      onPressed: () async {
        await Clipboard.setData(
          const ClipboardData(text: UpdateService.nixUpgradeCommand),
        );
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(const SnackBar(content: Text('Kopiert')));
        }
      },
      icon: const Icon(Icons.copy),
    );
  }
}
