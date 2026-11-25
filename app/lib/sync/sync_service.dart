import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../log.dart';
import 'channel.dart';
import 'discovery.dart';
import 'mdns.dart';
import 'sync_session.dart';
import 'sync_store.dart';
import '../core/music_fs.dart';

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
  String status = 'Steht auf beiden Geräten derselbe Code?';
  bool? result;
}

/// Sync mit gekoppelten Geräten im Heimnetz.
class SyncService extends ChangeNotifier {
  SyncService({
    required String dataDir,
    required this.host,
    required this.deviceName,
    this.port = defaultPort,
    Mdns? mdns,
  }) : store = SyncStore(dataDir),
       _mdns = mdns ?? Mdns.platform();

  static const defaultPort = 47788;
  static const discoveryPort = 47789;

  final SyncStore store;
  final SyncHost host;
  final String deviceName;
  final int port;

  final Mdns _mdns;
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

  /// Id des Geräts, mit dem gerade ein Abgleich aufgebaut wird (Suche und
  /// Verbindung, bevor es eine [session] gibt).
  String? connectingTo;
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
    logNetwork('Sync-Server lauscht auf Port ${_server!.port}');
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
            utf8.decode(d.data, allowMalformed: true) != discoveryQuery) {
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
    unawaited(_advertise());
    notifyListeners();
  }

  /// Per mDNS bekannt machen: Kennung, Name und bis wann gekoppelt werden
  /// darf (TXT), Port (SRV). Erneut bei jeder Änderung der Kopplung.
  Future<void> _advertise() async {
    final s = _server;
    if (s == null) return;
    final until = pairingAllowed ? pairingUntil!.millisecondsSinceEpoch : 0;
    await _mdns.advertise(
      instance: 'mync-${store.identity.id}',
      port: s.port,
      txt: {
        'mync': '1',
        'id': store.identity.id,
        'name': store.identity.name,
        'pair': '${until ~/ 1000}',
      },
    );
  }

  Future<void> stopServer() async {
    await _server?.close();
    _server = null;
    _discovery?.close();
    _discovery = null;
    unawaited(_mdns.stopAdvertising());
    notifyListeners();
  }

  /// Sucht Geräte im lokalen Netz (siehe [queryNetwork]) und meldet jedes,
  /// sobald es antwortet. Bekannte Geräte bekommen dabei ihre aktuelle
  /// Adresse. [onSubnets] meldet die durchsuchten Netze.
  Stream<Discovered> discoverStream({
    Duration timeout = const Duration(seconds: 4),
    void Function(List<String> subnets)? onSubnets,
    void Function(List<String> own)? onAddresses,
  }) async* {
    final seen = <String>{};
    await for (final r in _merge([
      queryNetwork(
        port: discoveryPort,
        hints: {for (final p in store.peers.values) ?p.host},
        timeout: timeout,
        onSubnets: onSubnets,
        onAddresses: onAddresses,
      ),
      _mdns.browse(timeout: timeout).map(_fromMdns),
    ])) {
      final j = r.data;
      if (j['mync'] != 1 || j['id'] is! String || j['port'] is! int) continue;
      final id = j['id'] as String;
      if (id == store.identity.id || !seen.add(id)) continue;
      final d = Discovered(
        id,
        j['name'] as String? ?? 'mync',
        r.host,
        j['port'] as int,
        pairing: j['pairing'] == true,
      );
      final p = store.peers[id];
      if (p != null && (p.host != d.host || p.port != d.port)) {
        p.host = d.host;
        p.port = d.port;
        unawaited(store.savePeers());
      }
      yield d;
    }
  }

  /// mDNS-Fund wie eine Antwort auf dem Erkennungsport darstellen.
  static DiscoveryReply _fromMdns(MdnsFound f) {
    final pair = int.tryParse(f.txt['pair'] ?? '') ?? 0;
    return (
      host: f.host,
      data: {
        'mync': int.tryParse(f.txt['mync'] ?? ''),
        'id': f.txt['id'],
        'name': f.txt['name'],
        'port': f.port,
        'pairing': pair * 1000 > DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  /// Führt mehrere Ströme zusammen; endet, wenn alle geendet haben.
  static Stream<T> _merge<T>(List<Stream<T>> streams) {
    final out = StreamController<T>();
    final subs = <StreamSubscription<T>>[];
    var open = streams.length;
    for (final s in streams) {
      subs.add(
        s.listen(
          out.add,
          onError: (Object e) {}, // ein Weg fällt aus, der andere sucht weiter
          onDone: () {
            if (--open == 0) out.close();
          },
        ),
      );
    }
    out.onCancel = () async {
      for (final s in subs) {
        await s.cancel();
      }
    };
    return out.stream;
  }

  /// Wie [discoverStream], liefert aber alle Funde auf einmal.
  Future<List<Discovered>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) => discoverStream(timeout: timeout).toList();

  /// Sucht im Netz nur nach [peer] und hört auf, sobald es antwortet.
  Future<Discovered?> _find(Peer peer) =>
      discoverStream(timeout: const Duration(seconds: 3))
          .cast<Discovered?>()
          .firstWhere((d) => d!.id == peer.id, orElse: () => null);

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
    } catch (e, st) {
      logError(
        'Eingehende Verbindung von ${socket.remoteAddress.address} abgelehnt',
        e,
        st,
      );
      message = 'Verbindung abgelehnt';
      notifyListeners();
    }
  }

  // ─── Kopplung ─────────────────────────────────────────────────────────

  /// Kopplung für 2 Minuten erlauben (das andere Gerät sucht und verbindet sich).
  void allowPairing({Duration duration = const Duration(minutes: 2)}) {
    pairingUntil = DateTime.now().add(duration);
    unawaited(_advertise());
    notifyListeners();
    Timer(duration, notifyListeners);
  }

  void stopPairing() {
    pairingUntil = null;
    unawaited(_advertise());
    notifyListeners();
  }

  /// Der Ablauf „Gerät koppeln“ ist offen: Dieses Gerät ist für die
  /// Kopplung sichtbar, während es selbst nach anderen sucht – so ist egal,
  /// auf welchem der beiden Geräte man das andere antippt.
  bool pairingMode = false;

  void startPairingMode() {
    message = null;
    pairing = null;
    pairingMode = true;
    allowPairing(duration: const Duration(minutes: 5));
  }

  void endPairingMode() {
    confirmPairing(false); // falls noch ein Code auf Bestätigung wartet
    pairingMode = false;
    pairingUntil = null;
    unawaited(_advertise());
    pairing = null;
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
      p.status = '${p.peerName} …';
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
      p.status = 'Gekoppelt ✓';
      logNetwork('Gekoppelt mit ${p.peerName} (${p.channel.peerId})');
      pairingUntil = null;
      unawaited(_advertise());
    } catch (e, st) {
      p.result = false;
      logError('Kopplung mit ${p.peerName} fehlgeschlagen', e, st);
      p.status = e is SyncProtocolException ? e.message : 'Fehlgeschlagen';
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
    unawaited(_advertise());
    notifyListeners();
  }

  // ─── Sync ─────────────────────────────────────────────────────────────

  /// Startet den Sync mit [peer] (sucht dessen Adresse vorher im Netz).
  Future<SyncSession?> syncWith(
    Peer peer, {
    String? hostOverride,
    int? portOverride,
  }) async {
    if (connectingTo != null) return null;
    message = null;
    connectingTo = peer.id;
    notifyListeners();
    try {
      return await _syncWith(peer, hostOverride, portOverride);
    } finally {
      connectingTo = null;
      notifyListeners();
    }
  }

  Future<SyncSession?> _syncWith(
    Peer peer,
    String? hostOverride,
    int? portOverride,
  ) async {
    if (hostOverride == null) await _find(peer);
    final h = hostOverride ?? peer.host;
    final pt = portOverride ?? peer.port ?? defaultPort;
    if (h == null) {
      logWarning('Sync: ${peer.name} im Netz nicht gefunden');
      message = '${peer.name} nicht gefunden';
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
      logNetwork('Sync: verbunden mit ${peer.name} ($h:$pt)');
      return _startSession(ch, peer, initiator: true);
    } catch (e, st) {
      logError('Verbindung zu ${peer.name} ($h:$pt) fehlgeschlagen', e, st);
      message = '${peer.name}: keine Verbindung';
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
    final trash = '${host.root}/.mync-trash';
    if (host.root.isEmpty || !await MusicFs.isDir(trash)) return;
    final limit = DateTime.now().subtract(const Duration(days: 30));
    for (final d in await MusicFs.list(trash)) {
      final day = DateTime.tryParse(d.name);
      if (d.isDir && day != null && day.isBefore(limit)) {
        try {
          if (MusicFs.isTree(trash)) {
            await MusicFs.delete('$trash/${d.name}'); // löscht samt Inhalt
          } else {
            await Directory('$trash/${d.name}').delete(recursive: true);
          }
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
