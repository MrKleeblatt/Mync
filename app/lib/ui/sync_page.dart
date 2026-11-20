import 'package:flutter/material.dart';

import '../sync/sync_service.dart';
import '../sync/sync_session.dart';
import '../log.dart';
import 'scope.dart';
import 'status_line.dart';
import 'track_actions.dart';

/// Die eine Instanz des Sync-Dienstes (in main gesetzt).
class SyncScope {
  static SyncService? service;
}

/// Sync mit dem Handy: koppeln, abgleichen, Änderungen bestätigen.
class SyncPage extends StatelessWidget {
  const SyncPage({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = SyncScope.service;
    if (sync == null) {
      return const Center(child: Text('Sync ist nicht verfügbar.'));
    }
    return ListenableBuilder(
      listenable: Listenable.merge([sync, context.settings]),
      builder: (context, _) {
        final s = sync.session;
        if (s != null) return _SessionView(sync: sync, session: s);
        return _Overview(sync: sync);
      },
    );
  }
}

class _Overview extends StatefulWidget {
  const _Overview({required this.sync});
  final SyncService sync;

  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  List<Discovered>? _found;
  bool _searching = false;

  SyncService get sync => widget.sync;

  Future<void> _search() async {
    setState(() => _searching = true);
    final f = await sync.discover();
    if (mounted) {
      setState(() {
        _found = f.where((d) => !sync.store.peers.containsKey(d.id)).toList();
        _searching = false;
      });
    }
  }

  Future<(String, int)?> _askAddress(String title) async {
    final v = await askText(
      context,
      title: title,
      label: 'Adresse (z. B. 192.168.1.23 oder 192.168.1.23:47788)',
    );
    if (v == null) return null;
    final parts = v.split(':');
    return (
      parts.first.trim(),
      parts.length > 1
          ? int.tryParse(parts[1]) ?? SyncService.defaultPort
          : SyncService.defaultPort,
    );
  }

  Future<void> _pair(String host, int port) async {
    try {
      await sync.pairWith(host, port);
    } catch (e, st) {
      logError('Kopplung mit $host:$port fehlgeschlagen', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kopplung fehlgeschlagen – Details im Logbuch'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = context.settings;
    final p = sync.pairing;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Sync mit dem Handy', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Gleicht den Musikordner mit gekoppelten Geräten im Heimnetz ab. Jede Änderung wird erst nach '
          'Bestätigung auf dem empfangenden Gerät übernommen. Die Verbindung ist Ende-zu-Ende verschlüsselt.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Dieses Gerät: ${sync.store.identity.name}'),
          subtitle: Text(
            sync.running
                ? 'Im Heimnetz erreichbar (Port ${sync.listeningPort})'
                : 'Für andere Geräte nicht erreichbar',
          ),
          value: settings.syncEnabled,
          onChanged: (v) async {
            await settings.setSyncEnabled(v);
            if (v) {
              await sync.startServer();
            } else {
              await sync.stopServer();
            }
          },
          secondary: IconButton(
            tooltip: 'Gerätenamen ändern',
            icon: const Icon(Icons.edit),
            onPressed: () async {
              final n = await askText(
                context,
                title: 'Gerätename',
                initial: sync.store.identity.name,
              );
              if (n != null) await sync.renameDevice(n);
            },
          ),
        ),
        if (sync.message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: StatusLine(OpStatus.error(sync.message!)),
          ),
        if (p != null) _PairingCard(sync: sync, pairing: p),
        const SizedBox(height: 16),
        Text('Gekoppelte Geräte', style: theme.textTheme.titleMedium),
        if (sync.peers.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Noch keine. Unten ein Gerät koppeln.'),
          ),
        for (final peer in sync.peers)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.smartphone),
            title: Text(peer.name),
            subtitle: Text(
              peer.lastSyncMs == 0
                  ? 'Noch nie abgeglichen'
                  : 'Zuletzt: ${_date(DateTime.fromMillisecondsSinceEpoch(peer.lastSyncMs))}',
            ),
            trailing: Wrap(
              spacing: 4,
              children: [
                FilledButton.icon(
                  onPressed: () => sync.syncWith(peer),
                  icon: const Icon(Icons.sync),
                  label: const Text('Abgleichen'),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'addr') {
                      final a = await _askAddress('Adresse von ${peer.name}');
                      if (a != null) {
                        await sync.syncWith(
                          peer,
                          hostOverride: a.$1,
                          portOverride: a.$2,
                        );
                      }
                    } else if (v == 'remove') {
                      await sync.removePeer(peer);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'addr',
                      child: Text('Über Adresse abgleichen …'),
                    ),
                    PopupMenuItem(
                      value: 'remove',
                      child: Text('Kopplung entfernen'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Text('Neues Gerät koppeln', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Auf einem Gerät „Koppelbar machen“ wählen, auf dem anderen „Geräte suchen“. Danach zeigen '
          'beide einen 6-stelligen Code – nur bestätigen, wenn er übereinstimmt.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            sync.pairingAllowed
                ? OutlinedButton.icon(
                    onPressed: sync.stopPairing,
                    icon: const Icon(Icons.hourglass_top),
                    label: const Text('Wartet auf Kopplung … (abbrechen)'),
                  )
                : OutlinedButton.icon(
                    onPressed: sync.running ? sync.allowPairing : null,
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('Koppelbar machen (2 min)'),
                  ),
            FilledButton.tonalIcon(
              onPressed: _searching ? null : _search,
              icon: _searching
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
              label: const Text('Geräte suchen'),
            ),
            TextButton(
              onPressed: () async {
                final a = await _askAddress('Gerät über Adresse koppeln');
                if (a != null) await _pair(a.$1, a.$2);
              },
              child: const Text('Adresse eingeben …'),
            ),
          ],
        ),
        if (_found case final found?) ...[
          const SizedBox(height: 8),
          if (found.where((d) => !sync.store.peers.containsKey(d.id)).isEmpty)
            const Text(
              'Kein neues Gerät gefunden. Läuft mync dort und ist „Koppelbar machen“ aktiv?',
            ),
          for (final d in found.where(
            (d) => !sync.store.peers.containsKey(d.id),
          ))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.devices),
              title: Text(d.name),
              subtitle: Text(
                '${d.host}:${d.port}${d.pairing ? ' · wartet auf Kopplung' : ''}',
              ),
              trailing: FilledButton(
                onPressed: () => _pair(d.host, d.port),
                child: const Text('Koppeln'),
              ),
            ),
        ],
      ],
    );
  }
}

class _PairingCard extends StatelessWidget {
  const _PairingCard({required this.sync, required this.pairing});
  final SyncService sync;
  final Pairing pairing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = !pairing.localDecision.isCompleted;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Kopplung mit ${pairing.peerName}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                '${pairing.code.substring(0, 3)} ${pairing.code.substring(3)}',
                style: theme.textTheme.displaySmall?.copyWith(
                  letterSpacing: 6,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(pairing.status),
            const SizedBox(height: 12),
            if (pairing.result == null && waiting)
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => sync.confirmPairing(true),
                    child: const Text('Code stimmt überein'),
                  ),
                  OutlinedButton(
                    onPressed: () => sync.confirmPairing(false),
                    child: const Text('Abbrechen'),
                  ),
                ],
              )
            else if (pairing.result != null)
              TextButton(
                onPressed: sync.dismissPairing,
                child: const Text('Schließen'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Inbox einer laufenden Sitzung.
class _SessionView extends StatelessWidget {
  const _SessionView({required this.sync, required this.session});
  final SyncService sync;
  final SyncSession session;

  static const _groups = [
    (ChangeKind.add, 'Neu'),
    (ChangeKind.rename, 'Umbenannt / verschoben'),
    (ChangeKind.tags, 'Tags geändert'),
    (ChangeKind.replace, 'Inhalt ersetzt'),
    (ChangeKind.delete, 'Gelöscht'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = session;
    final conflicts = s.items.where((i) => i.isConflict).toList();
    final open = s.items
        .where((i) => !i.done && i.decision == Decision.open)
        .length;
    final accepted = s.items
        .where((i) => !i.done && i.decision == Decision.accept)
        .length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Sync mit ${s.peer.name}',
                style: theme.textTheme.headlineSmall,
              ),
            ),
            TextButton.icon(
              onPressed: sync.dismissSession,
              icon: const Icon(Icons.close),
              label: const Text('Trennen'),
            ),
          ],
        ),
        Text(
          s.status,
          style: TextStyle(
            color: s.error != null ? theme.colorScheme.error : null,
          ),
        ),
        if (!s.ready && s.error == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(),
          ),
        if (s.applying)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(value: s.progress),
          ),
        if (s.ready && !s.finished) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: open == 0 ? null : () => s.acceptAll(),
                child: const Text('Alle annehmen (ohne Löschen)'),
              ),
              FilledButton.icon(
                onPressed:
                    accepted == 0 &&
                            !s.items.any(
                              (i) => i.decision == Decision.ignore && !i.done,
                            ) ||
                        s.applying
                    ? null
                    : s.applyDecisions,
                icon: const Icon(Icons.done_all),
                label: Text('Übernehmen ($accepted)'),
              ),
              FilledButton.tonal(
                onPressed: s.applying ? null : s.finish,
                child: const Text('Fertig'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Nicht übernommene Änderungen werden beim nächsten Abgleich wieder angeboten – außer „Ignorieren“.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (s.finished)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: FilledButton(
              onPressed: sync.dismissSession,
              child: const Text('Schließen'),
            ),
          ),
        if (conflicts.isNotEmpty) ...[
          _GroupTitle('Auf beiden Geräten geändert (${conflicts.length})'),
          for (final i in conflicts) _ItemTile(session: s, item: i),
        ],
        for (final (kind, label) in _groups)
          if (s.items
                  .where((i) => !i.isConflict && i.remote.kind == kind)
                  .toList()
              case final list when list.isNotEmpty) ...[
            _GroupTitle('$label (${list.length})'),
            for (final i in list) _ItemTile(session: s, item: i),
          ],
      ],
    );
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.session, required this.item});
  final SyncSession session;
  final InboxItem item;

  String _title() {
    final r = item.remote;
    return switch (r.kind) {
      ChangeKind.rename =>
        '${r.oldEntry!.path}\n→ ${r.newEntry!.path}${r.tagsChanged ? ' (und Tags)' : ''}',
      ChangeKind.delete => r.oldEntry!.path,
      _ => r.newEntry!.path,
    };
  }

  static String _kind(ChangeKind k) => switch (k) {
    ChangeKind.add => 'neu',
    ChangeKind.delete => 'gelöscht',
    ChangeKind.rename => 'umbenannt',
    ChangeKind.tags => 'Tags geändert',
    ChangeKind.replace => 'ersetzt',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peer = session.peer.name;
    final subtitle = item.isConflict
        ? 'Hier: ${_kind(item.local!.kind)} · auf $peer: ${_kind(item.remote.kind)}'
        : item.remote.kind == ChangeKind.delete
        ? 'Wird in den Papierkorb verschoben (30 Tage wiederherstellbar)'
        : null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        item.done
            ? Icons.check_circle
            : item.error != null
            ? Icons.error
            : item.isConflict
            ? Icons.warning_amber
            : item.remote.kind == ChangeKind.delete
            ? Icons.delete_outline
            : Icons.music_note,
        color: item.done
            ? theme.colorScheme.primary
            : item.error != null
            ? theme.colorScheme.error
            : null,
      ),
      title: Text(_title(), style: theme.textTheme.bodyMedium),
      subtitle: item.error != null
          ? const StatusLine(
              OpStatus.error('Übernehmen fehlgeschlagen'),
              dense: true,
            )
          : subtitle == null
          ? null
          : Text(subtitle),
      trailing: item.done
          ? Text(item.decision == Decision.ignore ? 'ignoriert' : 'übernommen')
          : SegmentedButton<Decision>(
              showSelectedIcon: false,
              emptySelectionAllowed: true,
              segments: [
                ButtonSegment(
                  value: Decision.accept,
                  label: Text(item.isConflict ? 'Von $peer' : 'Annehmen'),
                ),
                ButtonSegment(
                  value: Decision.reject,
                  label: Text(item.isConflict ? 'Eigene' : 'Nicht jetzt'),
                ),
                const ButtonSegment(
                  value: Decision.ignore,
                  label: Text('Ignorieren'),
                ),
              ],
              selected: item.decision == Decision.open
                  ? const {}
                  : {item.decision},
              onSelectionChanged: session.applying
                  ? null
                  : (v) => session.decide(
                      item,
                      v.isEmpty ? Decision.open : v.first,
                    ),
            ),
    );
  }
}

/// Hinweis oben, wenn ein anderes Gerät einen Abgleich gestartet hat oder koppeln will.
class SyncBanner extends StatelessWidget {
  const SyncBanner({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final sync = SyncScope.service;
    if (sync == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final s = sync.session;
        String? text;
        if (sync.pairing != null && sync.pairing!.result == null) {
          text =
              '${sync.pairing!.peerName} möchte koppeln – Code ${sync.pairing!.code}';
        } else if (s != null &&
            !s.closed &&
            s.ready &&
            s.items.any((i) => !i.done)) {
          text =
              'Sync mit ${s.peer.name}: ${s.items.where((i) => !i.done).length} Änderung(en) zu bestätigen';
        } else if (s != null && !s.closed && !s.initiator && !s.ready) {
          text = '${s.peer.name} gleicht ab …';
        }
        if (text == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Material(
          color: theme.colorScheme.tertiaryContainer,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.sync,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                  Text(
                    'Öffnen',
                    style: TextStyle(
                      color: theme.colorScheme.onTertiaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

String _date(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year} '
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
