import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'channel.dart';
import 'sync_session.dart';
import 'sync_store.dart';

/// Ein im WLAN gefundenes Gerät.
class Discovered {
  Discovered(this.id, this.name, this.host, this.port, {this.pairing = false});
  final String id;
  final String name;
  final String host;
  final int port;

  /// Wartet gerade auf eine Kopplung.
  final bool pairing;
}

/// Eine laufende Kopplung: beide Seiten bestätigen, dass der Code übereinstimmt.
class Pairing {
  Pairing(this.channel, {required this.initiator});
  final SecureChannel channel;
  final bool initiator;
  String get code => channel.sas!;
  String get peerName => channel.peerName;

  final localDecision = Completer<bool>();
  String status = 'Bitte prüfen, ob auf beiden Geräten derselbe Code steht.';
  bool? result;
}

/// Sync mit gekoppelten Geräten im Heimnetz.
class SyncService extends ChangeNotifier {
  SyncService({
    required String dataDir,
    required this.host,
    required this.deviceName,
    this.port = defaultPort,
  }) : store = SyncStore(dataDir);

  static const defaultPort = 47788;
  static const discoveryPort = 47789;

  final SyncStore store;
  final SyncHost host;
  final String deviceName;
  final int port;

  ServerSocket? _server;
  RawDatagramSocket? _discovery;
  int? get listeningPort => _server?.port;
  bool get running => _server != null;

  /// Kopplung erlaubt (bis [pairingUntil]).
  DateTime? pairingUntil;
  bool get pairingAllowed =>
      pairingUntil != null && DateTime.now().isBefore(pairingUntil!);

  Pairing? pairing;
  SyncSession? session;
  String? message;

  List<Peer> get peers =>
      store.peers.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  Future<void> init() async {
    await store.load(defaultName: deviceName);
    await _cleanupTrash();
  }

  // ─── Server und Geräteerkennung ───────────────────────────────────────

  Future<void> startServer() async {
    if (_server != null) return;
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _server!.listen(_onConnection);
    try {
      _discovery = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      _discovery!.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = _discovery?.receive();
        if (d == null ||
            utf8.decode(d.data, allowMalformed: true) != 'MYNC?1') {
          return;
        }
        final reply = jsonEncode({
          'mync': 1,
          'id': store.identity.id,
          'name': store.identity.name,
          'port': _server!.port,
          'pairing': pairingAllowed,
        });
        _discovery?.send(utf8.encode(reply), d.address, d.port);
      });
    } catch (_) {
      // Port belegt (zweite Instanz) – gefunden werden geht dann nur per Adresse
    }
    notifyListeners();
  }

  Future<void> stopServer() async {
    await _server?.close();
    _server = null;
    _discovery?.close();
    _discovery = null;
    notifyListeners();
  }

  /// Sucht Geräte im lokalen Netz (UDP-Broadcast).
  Future<List<Discovered>> discover({
    Duration wait = const Duration(milliseconds: 1500),
  }) async {
    final found = <String, Discovered>{};
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    s.broadcastEnabled = true;
    s.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final d = s.receive();
      if (d == null) return;
      try {
        final j = jsonDecode(utf8.decode(d.data)) as Map<String, dynamic>;
        if (j['mync'] != 1 || j['id'] == store.identity.id) return;
        found[j['id'] as String] = Discovered(
          j['id'] as String,
          j['name'] as String,
          d.address.address,
          j['port'] as int,
          pairing: j['pairing'] == true,
        );
      } catch (_) {}
    });
    final msg = utf8.encode('MYNC?1');
    for (final target in ['255.255.255.255', '127.0.0.1']) {
      try {
        s.send(msg, InternetAddress(target), discoveryPort);
      } catch (_) {}
    }
    await Future<void>.delayed(wait);
    s.close();
    // bekannte Adressen aktualisieren
    for (final d in found.values) {
      final p = store.peers[d.id];
      if (p != null) {
        p.host = d.host;
        p.port = d.port;
      }
    }
    if (found.isNotEmpty) await store.savePeers();
    return found.values.toList();
  }

  Future<void> _onConnection(Socket socket) async {
    try {
      final ch = await SecureChannel.accept(
        socket,
        store.identity,
        lookupPeer: (id) {
          final p = store.peers[id];
          return p == null ? null : unhex(p.publicKey);
        },
        allowPairing: pairingAllowed && pairing == null,
      );
      if (ch.sas != null) {
        await _runPairing(Pairing(ch, initiator: false));
      } else {
        final peer = store.peers[ch.peerId]!;
        peer.host = socket.remoteAddress.address;
        if (session != null && !session!.closed) {
          await ch.close(); // es läuft schon eine Sitzung
          return;
        }
        _startSession(ch, peer, initiator: false);
      }
    } catch (e) {
      message = 'Verbindung abgelehnt: $e';
      notifyListeners();
    }
  }

  // ─── Kopplung ─────────────────────────────────────────────────────────

  /// Kopplung für 2 Minuten erlauben (das andere Gerät sucht und verbindet sich).
  void allowPairing({Duration duration = const Duration(minutes: 2)}) {
    pairingUntil = DateTime.now().add(duration);
    notifyListeners();
    Timer(duration, notifyListeners);
  }

  void stopPairing() {
    pairingUntil = null;
    notifyListeners();
  }

  /// Koppelt mit dem Gerät unter [hostName]:[port].
  Future<void> pairWith(String hostName, int port) async {
    message = null;
    final ch = await SecureChannel.connect(hostName, port, store.identity);
    await _runPairing(Pairing(ch, initiator: true), host: hostName, port: port);
  }

  /// Nutzer bestätigt (true) oder verwirft (false) den angezeigten Code.
  void confirmPairing(bool ok) {
    final p = pairing;
    if (p != null && !p.localDecision.isCompleted) p.localDecision.complete(ok);
  }

  Future<void> _runPairing(Pairing p, {String? host, int? port}) async {
    pairing = p;
    notifyListeners();
    try {
      final mine = await p.localDecision.future.timeout(
        const Duration(minutes: 3),
        onTimeout: () => false,
      );
      await p.channel.sendJson({'t': 'pair', 'ok': mine});
      if (!mine) throw SyncProtocolException('Kopplung abgebrochen.');
      p.status = 'Warte auf Bestätigung von ${p.peerName} …';
      notifyListeners();
      final theirs = await p.channel.receive().timeout(
        const Duration(minutes: 3),
      );
      if (theirs is! Map || theirs['t'] != 'pair' || theirs['ok'] != true) {
        throw SyncProtocolException(
          '${p.peerName} hat die Kopplung abgelehnt.',
        );
      }
      store.peers[p.channel.peerId] = Peer(
        id: p.channel.peerId,
        name: p.peerName,
        publicKey: hex(p.channel.peerStatic),
        host: host,
        port: port,
      );
      await store.savePeers();
      p.result = true;
      p.status = 'Gekoppelt mit ${p.peerName}.';
      pairingUntil = null;
    } catch (e) {
      p.result = false;
      p.status = e is SyncProtocolException
          ? e.message
          : 'Kopplung fehlgeschlagen: $e';
    } finally {
      await p.channel.close();
      notifyListeners();
    }
  }

  void dismissPairing() {
    pairing = null;
    notifyListeners();
  }

  Future<void> removePeer(Peer p) async {
    await store.removePeer(p.id);
    notifyListeners();
  }

  Future<void> renameDevice(String name) async {
    store.identity.name = name;
    await store.saveIdentity();
    notifyListeners();
  }

  // ─── Sync ─────────────────────────────────────────────────────────────

  /// Startet den Sync mit [peer] (sucht dessen Adresse vorher im Netz).
  Future<SyncSession?> syncWith(
    Peer peer, {
    String? hostOverride,
    int? portOverride,
  }) async {
    message = null;
    if (hostOverride == null) {
      await discover(wait: const Duration(milliseconds: 800));
    }
    final h = hostOverride ?? peer.host;
    final pt = portOverride ?? peer.port ?? defaultPort;
    if (h == null) {
      message = '${peer.name} wurde im Netz nicht gefunden. Läuft mync dort?';
      notifyListeners();
      return null;
    }
    try {
      final ch = await SecureChannel.connect(
        h,
        pt,
        store.identity,
        knownPeerStatic: unhex(peer.publicKey),
      );
      return _startSession(ch, peer, initiator: true);
    } catch (e) {
      message = 'Verbindung zu ${peer.name} fehlgeschlagen: $e';
      notifyListeners();
      return null;
    }
  }

  SyncSession _startSession(
    SecureChannel ch,
    Peer peer, {
    required bool initiator,
  }) {
    final s = SyncSession(ch, peer, host, store, initiator: initiator);
    session = s;
    s.addListener(notifyListeners);
    unawaited(s.start());
    notifyListeners();
    return s;
  }

  void dismissSession() {
    session?.removeListener(notifyListeners);
    unawaited(session?.close());
    session = null;
    notifyListeners();
  }

  /// Papierkorb-Einträge älter als 30 Tage löschen.
  Future<void> _cleanupTrash() async {
    final trash = Directory('${host.root}/.mync-trash');
    if (!await trash.exists()) return;
    final limit = DateTime.now().subtract(const Duration(days: 30));
    await for (final d in trash.list()) {
      final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final day = DateTime.tryParse(name);
      if (d is Directory && day != null && day.isBefore(limit)) {
        try {
          await d.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    unawaited(stopServer());
    super.dispose();
  }
}
