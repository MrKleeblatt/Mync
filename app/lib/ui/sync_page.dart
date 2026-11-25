// Sync mit dem Handy, geführt wie der Bonscan bei Kassenbon: Koppeln und
// Abgleichen laufen Schritt für Schritt mit Fortschrittsbalken – erst
// suchen, dann den Code vergleichen; beim Abgleich je Art von Änderung eine
// Frage („12 neue Titel – übernehmen?“), am Ende eine Zusammenfassung.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../sync/sync_service.dart';
import '../sync/sync_session.dart';
import '../sync/sync_store.dart';
import '../log.dart';
import 'log_page.dart';
import 'menu_sheet.dart';
import 'scope.dart';
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
      return const Center(child: Icon(Icons.sync_disabled, size: 48));
    }
    return ListenableBuilder(
      listenable: Listenable.merge([sync, context.settings]),
      builder: (context, _) {
        final s = sync.session;
        final Widget page;
        if (s != null) {
          page = _SessionGuide(key: ObjectKey(s), sync: sync, session: s);
        } else if (sync.pairingMode || sync.pairing != null) {
          page = _PairGuide(key: const ValueKey('pair'), sync: sync);
        } else {
          page = _Overview(key: const ValueKey('overview'), sync: sync);
        }
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: page,
        );
      },
    );
  }
}

Future<(String, int)?> _askAddress(BuildContext context, String title) async {
  final v = await askText(context, title: title, label: '192.168.1.23[:47788]');
  if (v == null) return null;
  final parts = v.split(':');
  return (
    parts.first.trim(),
    parts.length > 1
        ? int.tryParse(parts[1]) ?? SyncService.defaultPort
        : SyncService.defaultPort,
  );
}

// ─── Übersicht ───────────────────────────────────────────────────────────

class _Overview extends StatelessWidget {
  const _Overview({super.key, required this.sync});
  final SyncService sync;

  Future<void> _startPairing(BuildContext context) async {
    final settings = context.settings;
    // Koppeln heißt: das andere Gerät soll dieses finden – dafür muss der
    // Sync an sein
    if (!settings.syncEnabled) await settings.setSyncEnabled(true);
    await sync.startServer();
    sync.startPairingMode();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final settings = context.settings;
    final peers = sync.peers;
    return _Page(
      children: [
        _DeviceCard(sync: sync, enabled: settings.syncEnabled),
        if (sync.message != null)
          _Notice(icon: Icons.error_outline, text: sync.message!, error: true),
        const SizedBox(height: 24),
        if (peers.isEmpty)
          _EmptyPeers(onPair: () => _startPairing(context))
        else ...[
          _SectionTitle('Gekoppelte Geräte'),
          for (final (i, peer) in peers.indexed)
            _FadeSlideIn(
              index: i,
              child: _PeerCard(sync: sync, peer: peer),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _startPairing(context),
              icon: const Icon(Icons.add_link),
              label: const Text('Weiteres Gerät koppeln'),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Text(
          'Abgeglichen wird verschlüsselt und nur mit gekoppelten Geräten. '
          'Jede Änderung bestätigst du vorher; Gelöschtes liegt 30 Tage im '
          'Papierkorb des Musikordners.',
          style: theme.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Dieses Gerät: Name, ob andere es erreichen, Schalter.
class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.sync, required this.enabled});
  final SyncService sync;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final settings = context.settings;
    final on = enabled && sync.running;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Badge(Icons.devices_other, active: on),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              sync.store.identity.name,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Gerätename ändern',
                            visualDensity: VisualDensity.compact,
                            iconSize: 18,
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () async {
                              final n = await askText(
                                context,
                                title: 'Gerätename',
                                initial: sync.store.identity.name,
                              );
                              if (n != null) await sync.renameDevice(n);
                            },
                          ),
                        ],
                      ),
                      _Dot(
                        on: on,
                        text: on
                            ? 'Bereit für den Sync · Port ${sync.listeningPort}'
                            : 'Sync aus',
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: enabled,
                  onChanged: (v) async {
                    await settings.setSyncEnabled(v);
                    if (v) {
                      await sync.startServer();
                    } else {
                      await sync.stopServer();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              enabled
                  ? 'Gekoppelte Geräte im selben WLAN finden dieses Gerät und '
                        'können einen Abgleich starten.'
                  : 'Andere Geräte finden dieses Gerät nicht. Von hier aus '
                        'abgleichen geht trotzdem, solange das andere Gerät '
                        'den Sync an hat.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: c.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPeers extends StatelessWidget {
  const _EmptyPeers({required this.onPair});
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _FadeSlideIn(
      child: Card(
        margin: EdgeInsets.zero,
        color: theme.colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
          child: Column(
            children: [
              const _Badge(Icons.phonelink_ring_outlined, size: 64),
              const SizedBox(height: 16),
              Text(
                'Noch kein Gerät gekoppelt',
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                'Einmal koppeln – danach gleicht mync mit einem Tipp ab, '
                'und du entscheidest bei jeder Änderung.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onPair,
                icon: const Icon(Icons.add_link),
                label: const Text('Gerät koppeln'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PeerCard extends StatelessWidget {
  const _PeerCard({required this.sync, required this.peer});
  final SyncService sync;
  final Peer peer;

  Future<void> _more(BuildContext context) async {
    final v = await showActionSheet<String>(
      context,
      title: peer.name,
      subtitle: 'Gekoppeltes Gerät',
      icon: Icons.smartphone,
      items: const [
        MenuItem('addr', Icons.lan_outlined, 'Über Adresse abgleichen'),
        MenuItem('remove', Icons.link_off, 'Kopplung entfernen'),
      ],
    );
    if (!context.mounted) return;
    if (v == 'addr') {
      final a = await _askAddress(context, 'Adresse von ${peer.name}');
      if (a != null) {
        await sync.syncWith(peer, hostOverride: a.$1, portOverride: a.$2);
      }
    } else if (v == 'remove') {
      await sync.removePeer(peer);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = sync.connectingTo == peer.id;
    final idle = sync.connectingTo == null;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: idle ? () => sync.syncWith(peer) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              const _Badge(Icons.smartphone, size: 40),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(peer.name, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      busy
                          ? 'Suche im Netz …'
                          : peer.lastSyncMs == 0
                          ? 'Noch nie abgeglichen'
                          : 'Abgeglichen ${_ago(peer.lastSyncMs)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: idle ? () => sync.syncWith(peer) : null,
                icon: busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: const Text('Abgleichen'),
              ),
              IconButton(
                tooltip: 'Mehr',
                icon: const Icon(Icons.more_vert),
                onPressed: () => _more(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Koppeln ─────────────────────────────────────────────────────────────

enum _PairStep { search, code, done }

/// Gerät koppeln: suchen (und dabei selbst sichtbar sein), Code vergleichen,
/// fertig.
class _PairGuide extends StatefulWidget {
  const _PairGuide({super.key, required this.sync});
  final SyncService sync;

  @override
  State<_PairGuide> createState() => _PairGuideState();
}

class _PairGuideState extends State<_PairGuide> {
  SyncService get sync => widget.sync;

  final _found = <String, Discovered>{};
  List<String>? _subnets;
  List<String> _own = const [];
  bool _searching = false;
  bool _connecting = false;
  Timer? _again;
  StreamSubscription<Discovered>? _sub;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _again?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  /// Sucht und wiederholt die Suche, solange der Schritt offen ist – das
  /// andere Gerät kann ja erst später dazukommen.
  void _search() {
    _again?.cancel();
    _sub?.cancel();
    setState(() => _searching = true);
    _sub = sync
        .discoverStream(
          onSubnets: (n) {
            if (mounted) setState(() => _subnets = n);
          },
          onAddresses: (a) {
            if (mounted) setState(() => _own = a);
          },
        )
        .listen(
          (d) {
            if (mounted) setState(() => _found[d.id] = d);
          },
          onDone: () {
            if (!mounted) return;
            setState(() => _searching = false);
            _again = Timer(const Duration(seconds: 3), () {
              if (mounted && sync.pairing == null) _search();
            });
          },
          onError: (Object e) {
            logWarning('Gerätesuche: $e');
          },
        );
  }

  Future<void> _pair(String host, int port) async {
    setState(() => _connecting = true);
    try {
      await sync.pairWith(host, port);
    } catch (e, st) {
      logError('Kopplung mit $host:$port fehlgeschlagen', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Verbindung fehlgeschlagen')),
        );
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _restart() {
    sync.startPairingMode();
    _search();
  }

  @override
  Widget build(BuildContext context) {
    final p = sync.pairing;
    final step = p == null
        ? _PairStep.search
        : p.result == null
        ? _PairStep.code
        : _PairStep.done;
    return _Guide(
      title: 'Gerät koppeln',
      progress: (step.index + 1) / _PairStep.values.length,
      onClose: sync.endPairingMode,
      stepKey: step,
      child: switch (step) {
        _PairStep.search => _searchStep(context),
        _PairStep.code => _codeStep(context, p!),
        _PairStep.done => _doneStep(context, p!),
      },
    );
  }

  Widget _searchStep(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final known = sync.store.peers;
    final found = _found.values.where((d) => !known.containsKey(d.id)).toList()
      ..sort((a, b) => (b.pairing ? 1 : 0) - (a.pairing ? 1 : 0));
    final visible = sync.pairingAllowed;
    final nets = _subnets;
    return _StepFrame(
      title: 'Anderes Gerät suchen',
      subtitle:
          'Öffne auf dem anderen Gerät ebenfalls Sync → Gerät koppeln. '
          'Beide müssen im selben WLAN oder Hotspot sein.',
      body: [
        Center(child: _Radar(active: _searching || _connecting)),
        const SizedBox(height: 8),
        Center(
          child: Text(
            _connecting
                ? 'Verbinde …'
                : nets == null
                ? 'Suche …'
                : nets.isEmpty
                ? 'Kein WLAN oder Hotspot gefunden'
                : [
                    if (_own.isNotEmpty) 'Dieses Gerät: ${_own.join(', ')}',
                    'Durchsuche ${nets.join(', ')}',
                  ].join('\n'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: c.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: _Dot(
            on: visible,
            text: visible
                ? 'Sichtbar als „${sync.store.identity.name}“'
                : 'Nicht mehr sichtbar',
          ),
        ),
        if (!visible)
          Center(
            child: TextButton(
              onPressed: _restart,
              child: const Text('Wieder sichtbar machen'),
            ),
          ),
        const SizedBox(height: 20),
        if (found.isEmpty)
          Text(
            'Noch nichts gefunden. Die Suche läuft weiter.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: c.onSurfaceVariant,
            ),
          )
        else ...[
          _SectionTitle('Gefunden'),
          for (final (i, d) in found.indexed)
            _FadeSlideIn(
              key: ValueKey(d.id),
              index: i,
              child: Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: _Badge(
                    Icons.smartphone,
                    size: 40,
                    active: d.pairing,
                  ),
                  title: Text(d.name),
                  subtitle: Text(
                    d.pairing ? 'Bereit zum Koppeln' : '${d.host}:${d.port}',
                  ),
                  trailing: FilledButton(
                    onPressed: _connecting ? null : () => _pair(d.host, d.port),
                    child: const Text('Koppeln'),
                  ),
                ),
              ),
            ),
        ],
      ],
      actions: [
        OutlinedButton.icon(
          onPressed: _connecting
              ? null
              : () async {
                  final a = await _askAddress(context, 'Adresse');
                  if (a != null) await _pair(a.$1, a.$2);
                },
          icon: const Icon(Icons.lan_outlined),
          label: const Text('Adresse eingeben'),
        ),
      ],
    );
  }

  Widget _codeStep(BuildContext context, Pairing p) {
    final theme = Theme.of(context);
    final waiting = p.localDecision.isCompleted;
    return _StepFrame(
      title: 'Steht dort derselbe Code?',
      subtitle: waiting
          ? 'Warte auf ${p.peerName} …'
          : 'Vergleiche ihn mit dem Code auf „${p.peerName}“.',
      body: [
        Card(
          margin: EdgeInsets.zero,
          color: theme.colorScheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: Text(
                '${p.code.substring(0, 3)} ${p.code.substring(3)}',
                style: theme.textTheme.displayMedium?.copyWith(
                  letterSpacing: 8,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
        if (waiting)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: LinearProgressIndicator(),
          ),
      ],
      actions: waiting
          ? const []
          : [
              FilledButton.icon(
                onPressed: () => sync.confirmPairing(true),
                icon: const Icon(Icons.check),
                label: const Text('Ja, gleicher Code'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => sync.confirmPairing(false),
                child: const Text('Nein, abbrechen'),
              ),
            ],
    );
  }

  Widget _doneStep(BuildContext context, Pairing p) {
    final ok = p.result == true;
    final peer = ok ? sync.store.peers[p.channel.peerId] : null;
    return _Result(
      ok: ok,
      title: ok ? 'Gekoppelt!' : 'Nicht gekoppelt',
      text: ok
          ? 'Ab jetzt kannst du mit „${p.peerName}“ abgleichen.'
          : p.status,
      actions: [
        if (peer != null)
          FilledButton.icon(
            onPressed: () {
              sync.endPairingMode();
              sync.syncWith(peer);
            },
            icon: const Icon(Icons.sync),
            label: const Text('Jetzt abgleichen'),
          )
        else
          FilledButton(
            onPressed: _restart,
            child: const Text('Nochmal versuchen'),
          ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: sync.endPairingMode,
          child: const Text('Fertig'),
        ),
      ],
    );
  }
}

// ─── Abgleich ────────────────────────────────────────────────────────────

/// Ein Schritt des Abgleichs: Verbinden, Konflikte, eine Art von Änderung,
/// Zusammenfassung oder Ergebnis.
class _SyncStep {
  const _SyncStep.connect() : kind = null, conflicts = false, last = false;
  const _SyncStep.conflicts() : kind = null, conflicts = true, last = false;
  const _SyncStep.group(ChangeKind this.kind) : conflicts = false, last = false;
  const _SyncStep.summary() : kind = null, conflicts = false, last = false;
  const _SyncStep.done() : kind = null, conflicts = false, last = true;
  final ChangeKind? kind;
  final bool conflicts;
  final bool last;
}

class _SessionGuide extends StatefulWidget {
  const _SessionGuide({super.key, required this.sync, required this.session});
  final SyncService sync;
  final SyncSession session;

  @override
  State<_SessionGuide> createState() => _SessionGuideState();
}

class _SessionGuideState extends State<_SessionGuide> {
  SyncSession get s => widget.session;

  static const _order = [
    ChangeKind.add,
    ChangeKind.rename,
    ChangeKind.tags,
    ChangeKind.replace,
    ChangeKind.delete,
  ];

  List<_SyncStep>? _steps;
  int _index = 0;

  /// Nach dem Übernehmen schlug etwas fehl: Zusammenfassung zeigt es an.
  bool _failed = false;

  List<_SyncStep> _compute() {
    final items = s.items;
    if (items.isEmpty) {
      // nichts zu entscheiden: gemeinsamen Stand gleich speichern (nicht
      // mitten im Bildaufbau)
      unawaited(Future.microtask(s.finish));
      return const [_SyncStep.connect(), _SyncStep.done()];
    }
    return [
      const _SyncStep.connect(),
      if (items.any((i) => i.isConflict)) const _SyncStep.conflicts(),
      for (final k in _order)
        if (items.any((i) => !i.isConflict && i.remote.kind == k))
          _SyncStep.group(k),
      const _SyncStep.summary(),
      const _SyncStep.done(),
    ];
  }

  void _go(int i) => setState(() => _index = i.clamp(0, _steps!.length - 1));
  void _next() => _go(_index + 1);

  List<InboxItem> _itemsOf(_SyncStep st) => [
    for (final i in s.items)
      if (st.conflicts
          ? i.isConflict
          : !i.isConflict && i.remote.kind == st.kind)
        i,
  ];

  Future<void> _apply() async {
    await s.applyDecisions();
    if (!mounted) return;
    if (s.items.any((i) => i.error != null && !i.done)) {
      setState(() => _failed = true);
      return;
    }
    await s.finish();
    if (mounted) _go(_steps!.length - 1);
  }

  Future<void> _finishAnyway() async {
    await s.finish();
    if (mounted) _go(_steps!.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final sync = widget.sync;
    if (s.ready && _steps == null) {
      _steps = _compute();
      _index = 1;
    }
    final steps = _steps ?? const [_SyncStep.connect()];
    final step = steps[_index];
    // fehlgeschlagen, bevor es fertig war
    final broken = s.error != null && !s.finished;
    final total = steps.length;
    return _Guide(
      title: 'Abgleich mit ${s.peer.name}',
      progress: broken ? 1 : (_index + 1) / math.max(total, 4),
      onBack: _index > 1 && !step.last && !s.applying && !broken
          ? () => _go(_index - 1)
          : null,
      onClose: sync.dismissSession,
      stepKey: broken ? 'error' : _index,
      child: broken
          ? _Result(
              ok: false,
              title: s.status,
              text:
                  'Der Abgleich mit „${s.peer.name}“ wurde abgebrochen. '
                  'Einzelheiten stehen im Logbuch.',
              actions: [
                FilledButton(
                  onPressed: sync.dismissSession,
                  child: const Text('Schließen'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => openLogPage(context),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('Logbuch'),
                ),
              ],
            )
          : step.last
          ? _doneStep(context)
          : step.kind != null || step.conflicts
          ? _groupStep(context, step)
          : _index == 0
          ? _connectStep(context)
          : _summaryStep(context),
    );
  }

  Widget _connectStep(BuildContext context) => _StepFrame(
    title: s.initiator
        ? 'Verbinde mit ${s.peer.name}'
        : '${s.peer.name} möchte abgleichen',
    subtitle: 'Beide Bibliotheken werden eingelesen und verglichen.',
    body: [
      const Center(child: _Radar(active: true, icon: Icons.sync)),
      const SizedBox(height: 12),
      Center(child: Text(s.status)),
    ],
  );

  Widget _groupStep(BuildContext context, _SyncStep st) {
    final items = _itemsOf(st);
    final n = items.length;
    final peer = s.peer.name;
    final (icon, title, subtitle) = st.conflicts
        ? (
            Icons.call_split,
            n == 1 ? '1 Konflikt' : '$n Konflikte',
            'Auf beiden Geräten geändert. Welche Fassung soll gelten?',
          )
        : switch (st.kind!) {
            ChangeKind.add => (
              Icons.library_add_outlined,
              n == 1 ? '1 neuer Titel' : '$n neue Titel',
              'Kamen auf $peer dazu.',
            ),
            ChangeKind.rename => (
              Icons.drive_file_move_outline,
              n == 1 ? '1 Titel umbenannt' : '$n Titel umbenannt',
              'Auf $peer umbenannt oder verschoben.',
            ),
            ChangeKind.tags => (
              Icons.sell_outlined,
              n == 1 ? '1 Titel mit neuen Tags' : '$n Titel mit neuen Tags',
              'Auf $peer bearbeitet: Titel, Interpret, Cover …',
            ),
            ChangeKind.replace => (
              Icons.swap_horiz,
              n == 1 ? '1 Titel ersetzt' : '$n Titel ersetzt',
              'Auf $peer durch eine andere Fassung ersetzt.',
            ),
            ChangeKind.delete => (
              Icons.delete_outline,
              n == 1 ? '1 Titel gelöscht' : '$n Titel gelöscht',
              'Auf $peer gelöscht. Hier kommen sie in den Papierkorb und '
                  'bleiben 30 Tage wiederherstellbar.',
            ),
          };
    final decided = items.where((i) => i.decision != Decision.open).length;
    final isDelete = st.kind == ChangeKind.delete;
    void all(Decision d) {
      for (final i in items) {
        if (!i.done) s.decide(i, d);
      }
      _next();
    }

    return _StepFrame(
      icon: icon,
      title: title,
      subtitle: subtitle,
      body: [
        if (!st.conflicts)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: _Legend()),
        for (final i in items)
          st.conflicts
              ? _ConflictCard(session: s, item: i)
              : _ItemRow(session: s, item: i),
      ],
      actions: [
        if (decided > 0)
          FilledButton(
            onPressed: _next,
            child: Text('Weiter · $decided von $n entschieden'),
          )
        else if (st.conflicts)
          FilledButton(
            onPressed: () => all(Decision.accept),
            child: Text('Überall die Fassung von $peer'),
          )
        else
          FilledButton.icon(
            onPressed: () => all(Decision.accept),
            style: isDelete
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
            icon: Icon(isDelete ? Icons.delete_outline : Icons.done_all),
            label: Text(
              isDelete
                  ? 'Alle löschen'
                  : n == 1
                  ? 'Übernehmen'
                  : 'Alle $n übernehmen',
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => all(Decision.reject),
          child: Text(
            st.conflicts ? 'Überall die eigene behalten' : 'Nicht jetzt',
          ),
        ),
      ],
    );
  }

  Widget _summaryStep(BuildContext context) {
    final theme = Theme.of(context);
    final open = s.items.where((i) => !i.done).toList();
    final accept = open.where((i) => i.decision == Decision.accept).length;
    final ignore = open.where((i) => i.decision == Decision.ignore).length;
    final later = open.length - accept - ignore;
    final failed = s.items.where((i) => i.error != null && !i.done).length;
    return _StepFrame(
      icon: Icons.checklist,
      title: s.applying ? 'Übernehme …' : 'Alles entschieden',
      subtitle: s.applying
          ? s.status
          : 'Hier siehst du, was jetzt passiert. Zurück kommst du oben links.',
      body: [
        if (s.applying)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _Bar(value: s.progress),
          ),
        _CountTile(
          icon: Icons.check,
          label: 'Übernehmen',
          count: accept,
          strong: true,
        ),
        _CountTile(icon: Icons.schedule, label: 'Nicht jetzt', count: later),
        _CountTile(
          icon: Icons.visibility_off_outlined,
          label: 'Immer ignorieren',
          count: ignore,
        ),
        if (_failed && failed > 0)
          _Notice(
            icon: Icons.error_outline,
            text:
                '$failed ${failed == 1 ? 'Änderung' : 'Änderungen'} konnten '
                'nicht übernommen werden – Einzelheiten im Logbuch.',
            error: true,
          ),
        if (later > 0 && !s.applying)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Was du nicht jetzt übernimmst, fragt mync beim nächsten '
              'Abgleich wieder.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
      actions: s.applying
          ? const []
          : _failed && failed > 0
          ? [
              FilledButton(
                onPressed: _apply,
                child: const Text('Nochmal versuchen'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _finishAnyway,
                child: const Text('Trotzdem abschließen'),
              ),
            ]
          : [
              FilledButton.icon(
                onPressed: _apply,
                icon: const Icon(Icons.check),
                label: Text(
                  accept == 0
                      ? 'Abschließen'
                      : accept == 1
                      ? '1 Änderung übernehmen'
                      : '$accept Änderungen übernehmen',
                ),
              ),
            ],
    );
  }

  Widget _doneStep(BuildContext context) {
    final done = s.items
        .where((i) => i.done && i.decision == Decision.accept)
        .length;
    final failed = s.items.where((i) => i.error != null && !i.done).length;
    final String text;
    if (s.items.isEmpty) {
      text = 'Hier und auf „${s.peer.name}“ ist alles auf demselben Stand.';
    } else {
      text = [
        done == 1 ? '1 Änderung übernommen' : '$done Änderungen übernommen',
        if (failed > 0) '$failed fehlgeschlagen',
      ].join(' · ');
    }
    return _Result(
      ok: true,
      busy: !s.finished,
      title: s.items.isEmpty ? 'Schon gleich' : 'Abgeglichen',
      text: !s.finished
          ? s.status
          : s.peerFinished || s.closed
          ? text
          : '$text\n${s.peer.name} entscheidet noch.',
      actions: [
        FilledButton(
          onPressed: s.finished ? widget.sync.dismissSession : null,
          child: const Text('Schließen'),
        ),
      ],
    );
  }
}

/// Bedeutung der drei Knöpfe je Titel.
class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    Widget item(IconData i, String s) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(i, size: 14, color: t?.color),
        const SizedBox(width: 4),
        Text(s, style: t),
      ],
    );
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        item(Icons.check, 'übernehmen'),
        item(Icons.schedule, 'nicht jetzt'),
        item(Icons.visibility_off_outlined, 'immer ignorieren'),
      ],
    );
  }
}

(String, String) _split(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? (path, '') : (path.substring(i + 1), path.substring(0, i));
}

/// Ein Titel einer Gruppe: Dateiname, Ordner, drei Knöpfe.
class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.session, required this.item});
  final SyncSession session;
  final InboxItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final r = item.remote;
    final path = r.kind == ChangeKind.delete
        ? r.oldEntry!.path
        : r.newEntry!.path;
    final (name, dir) = _split(path);
    final String sub;
    if (r.kind == ChangeKind.rename) {
      sub = 'vorher ${r.oldEntry!.path}${r.tagsChanged ? ' · und Tags' : ''}';
    } else {
      sub = dir;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                if (sub.isNotEmpty)
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                if (item.error != null)
                  Text(
                    'Fehlgeschlagen',
                    style: muted?.copyWith(color: theme.colorScheme.error),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (item.done)
            Icon(
              item.decision == Decision.ignore
                  ? Icons.visibility_off_outlined
                  : Icons.check_circle,
              color: theme.colorScheme.primary,
            )
          else
            _DecisionButtons(session: session, item: item),
        ],
      ),
    );
  }
}

class _DecisionButtons extends StatelessWidget {
  const _DecisionButtons({
    required this.session,
    required this.item,
    this.labels,
  });
  final SyncSession session;
  final InboxItem item;

  /// Beschriftung für Annehmen und Ablehnen (bei Konflikten), sonst nur
  /// Symbole.
  final (String, String)? labels;

  @override
  Widget build(BuildContext context) {
    final l = labels;
    return SegmentedButton<Decision>(
      showSelectedIcon: false,
      emptySelectionAllowed: true,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: [
        ButtonSegment(
          value: Decision.accept,
          tooltip: 'Übernehmen',
          icon: const Icon(Icons.check),
          label: l == null ? null : Text(l.$1),
        ),
        ButtonSegment(
          value: Decision.reject,
          tooltip: l == null ? 'Nicht jetzt' : 'Eigene behalten',
          icon: Icon(l == null ? Icons.schedule : Icons.home_outlined),
          label: l == null ? null : Text(l.$2),
        ),
        const ButtonSegment(
          value: Decision.ignore,
          tooltip: 'Immer ignorieren',
          icon: Icon(Icons.visibility_off_outlined),
        ),
      ],
      selected: item.decision == Decision.open ? const {} : {item.decision},
      onSelectionChanged: session.applying
          ? null
          : (v) => session.decide(item, v.isEmpty ? Decision.open : v.first),
    );
  }
}

/// Ein Konflikt: was hier und was drüben geändert wurde, und die Wahl.
class _ConflictCard extends StatelessWidget {
  const _ConflictCard({required this.session, required this.item});
  final SyncSession session;
  final InboxItem item;

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
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final peer = session.peer.name;
    final r = item.remote;
    final path = (r.newEntry ?? r.oldEntry)!.path;
    final (name, dir) = _split(path);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: theme.textTheme.titleSmall),
            if (dir.isNotEmpty) Text(dir, style: muted),
            const SizedBox(height: 6),
            Text(
              'Hier: ${_kind(item.local!.kind)} · $peer: ${_kind(r.kind)}',
              style: muted,
            ),
            const SizedBox(height: 10),
            if (item.done)
              Icon(Icons.check_circle, color: theme.colorScheme.primary)
            else
              _DecisionButtons(
                session: session,
                item: item,
                labels: (peer, 'Eigene'),
              ),
          ],
        ),
      ),
    );
  }
}

class _CountTile extends StatelessWidget {
  const _CountTile({
    required this.icon,
    required this.label,
    required this.count,
    this.strong = false,
  });
  final IconData icon;
  final String label;
  final int count;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final color = strong && count > 0 ? c.primary : c.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 14),
          Expanded(child: Text(label, style: theme.textTheme.titleMedium)),
          Text(
            '$count',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: count == 0 ? c.onSurfaceVariant : color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Bausteine ───────────────────────────────────────────────────────────

/// Seite mit begrenzter Breite.
class _Page extends StatelessWidget {
  const _Page({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView(padding: const EdgeInsets.all(16), children: children),
    ),
  );
}

/// Rahmen eines geführten Ablaufs: Kopfzeile mit Zurück und Schließen,
/// Fortschrittsbalken, darunter der aktuelle Schritt (mit Überblendung).
class _Guide extends StatelessWidget {
  const _Guide({
    required this.title,
    required this.progress,
    required this.onClose,
    required this.stepKey,
    required this.child,
    this.onBack,
  });
  final String title;
  final double progress;
  final VoidCallback onClose;
  final VoidCallback? onBack;
  final Object stepKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Row(
                children: [
                  if (onBack != null)
                    IconButton(
                      tooltip: 'Zurück',
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back),
                    )
                  else
                    const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Schließen',
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _Bar(value: progress),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOutCubic,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0.04, 0),
                      end: Offset.zero,
                    ).animate(a),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(key: ValueKey(stepKey), child: child),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fortschritt in Kupfer, gleitet zum neuen Wert.
class _Bar extends StatelessWidget {
  const _Bar({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Container(
        height: 4,
        color: c.surfaceContainerHighest,
        alignment: Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: value.clamp(0, 1)),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (_, v, _) => FractionallySizedBox(
            widthFactor: v,
            child: Container(color: c.primary),
          ),
        ),
      ),
    );
  }
}

/// Ein Schritt: Symbol, große Frage, Inhalt, Knöpfe unten.
class _StepFrame extends StatelessWidget {
  const _StepFrame({
    this.icon,
    required this.title,
    this.subtitle,
    required this.body,
    this.actions = const [],
  });
  final IconData? icon;
  final String title;
  final String? subtitle;
  final List<Widget> body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            children: [
              _FadeSlideIn(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (icon != null) ...[
                      _Badge(icon!, size: 48, active: true),
                      const SizedBox(height: 14),
                    ],
                    Text(title, style: theme.textTheme.headlineSmall),
                    if (subtitle != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              for (final (i, w) in body.indexed)
                // lange Listen nicht einzeln einblenden
                i < 12 ? _FadeSlideIn(index: i + 1, child: w) : w,
            ],
          ),
        ),
        if (actions.isNotEmpty)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: actions,
              ),
            ),
          ),
      ],
    );
  }
}

/// Ergebnis eines Ablaufs: großes Häkchen oder Kreuz, Text, Knöpfe.
class _Result extends StatelessWidget {
  const _Result({
    required this.ok,
    required this.title,
    required this.text,
    required this.actions,
    this.busy = false,
  });
  final bool ok;
  final bool busy;
  final String title;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final color = ok ? c.primary : c.error;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy)
                    const SizedBox.square(
                      dimension: 88,
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0.6, end: 1),
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.elasticOut,
                      builder: (_, s, child) =>
                          Transform.scale(scale: s, child: child),
                      child: Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: color, width: 2),
                          color: color.withValues(alpha: 0.12),
                        ),
                        child: Icon(
                          ok ? Icons.check_rounded : Icons.close_rounded,
                          size: 48,
                          color: color,
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: c.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: actions,
            ),
          ),
        ),
      ],
    );
  }
}

/// Symbol auf getönter Fläche; [active] in Kupfer.
class _Badge extends StatelessWidget {
  const _Badge(this.icon, {this.size = 48, this.active = false});
  final IconData icon;
  final double size;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: active ? c.primaryContainer : c.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(
        icon,
        size: size * 0.5,
        color: active ? c.onPrimaryContainer : c.onSurfaceVariant,
      ),
    );
  }
}

/// Punkt mit Zustand: Kupfer = an, grau = aus.
class _Dot extends StatelessWidget {
  const _Dot({required this.on, required this.text});
  final bool on;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? c.primary : c.outline,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: c.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.error = false});
  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final fg = error ? c.onErrorContainer : c.onSurface;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      color: error ? c.errorContainer : c.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(icon, color: fg),
            const SizedBox(width: 12),
            Expanded(
              child: Text(text, style: TextStyle(color: fg)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        letterSpacing: 1.2,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// Blendet ein und schiebt leicht nach oben, um [index] Schritte versetzt.
class _FadeSlideIn extends StatelessWidget {
  const _FadeSlideIn({super.key, required this.child, this.index = 0});
  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: Duration(milliseconds: 280 + 50 * index),
    curve: Curves.easeOutCubic,
    builder: (_, v, child) => Opacity(
      opacity: v,
      child: Transform.translate(offset: Offset(0, 12 * (1 - v)), child: child),
    ),
    child: child,
  );
}

/// Suchanzeige: Wellen laufen vom Symbol nach außen.
class _Radar extends StatefulWidget {
  const _Radar({required this.active, this.icon = Icons.wifi_tethering});
  final bool active;
  final IconData icon;

  @override
  State<_Radar> createState() => _RadarState();
}

class _RadarState extends State<_Radar> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(_Radar old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 160,
      child: CustomPaint(
        painter: _RadarPainter(_c, c.primary, widget.active),
        child: Center(child: _Badge(widget.icon, size: 56, active: true)),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.t, this.color, this.active) : super(repaint: t);
  final Animation<double> t;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final max = size.shortestSide / 2;
    const rings = 3;
    for (var i = 0; i < rings; i++) {
      final p = active ? (t.value + i / rings) % 1 : (i + 1) / (rings + 1);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color.withValues(alpha: active ? 0.55 * (1 - p) : 0.15);
      canvas.drawCircle(center, 30 + (max - 30) * p, paint);
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.color != color || old.active != active;
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
          text = '${sync.pairing!.peerName} möchte koppeln · Code vergleichen';
        } else if (s != null &&
            !s.closed &&
            s.ready &&
            s.items.any((i) => !i.done)) {
          final n = s.items.where((i) => !i.done).length;
          text =
              '${s.peer.name} · $n ${n == 1 ? 'Änderung' : 'Änderungen'} '
              'zu entscheiden';
        } else if (s != null && !s.closed && !s.initiator && !s.ready) {
          text = '${s.peer.name} möchte abgleichen …';
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
                  Icon(
                    Icons.chevron_right,
                    color: theme.colorScheme.onTertiaryContainer,
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

/// „gerade eben“, „vor 5 Min.“, „gestern“, „vor 3 Tagen“, sonst Datum.
String _ago(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'gerade eben';
  if (diff.inHours < 1) return 'vor ${diff.inMinutes} Min.';
  if (diff.inDays < 1) return 'vor ${diff.inHours} Std.';
  if (diff.inDays == 1) return 'gestern';
  if (diff.inDays < 14) return 'vor ${diff.inDays} Tagen';
  String two(int n) => n.toString().padLeft(2, '0');
  return 'am ${two(d.day)}.${two(d.month)}.${d.year}';
}
