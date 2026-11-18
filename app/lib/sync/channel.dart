import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../core/mync_core.dart';

/// Eigenes Gerät: ID, Name und statisches X25519-Schlüsselpaar.
class DeviceIdentity {
  DeviceIdentity({
    required this.id,
    required this.name,
    required this.secret,
    required this.public,
  });
  final String id;
  String name;
  final Uint8List secret;
  final Uint8List public;
}

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List unhex(String s) {
  if (s.length.isOdd) throw const FormatException('hex');
  return Uint8List.fromList([
    for (var i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ]);
}

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

class SyncProtocolException implements Exception {
  SyncProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Liest Rahmen „u32 Länge + Daten“ aus einem Socket.
class _FrameReader {
  _FrameReader(Stream<Uint8List> s) {
    _sub = s.listen(
      _onData,
      onDone: _onDone,
      onError: _onError,
      cancelOnError: true,
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  final _frames = StreamController<Uint8List>();

  static const maxFrame = 16 << 20;

  Stream<Uint8List> get frames => _frames.stream;

  void _onData(Uint8List d) {
    _buf.add(_pending);
    _buf.add(d);
    var data = _buf.takeBytes();
    var off = 0;
    while (data.length - off >= 4) {
      final len = ByteData.sublistView(data, off, off + 4).getUint32(0);
      if (len > maxFrame) {
        _onError(SyncProtocolException('Rahmen zu groß'));
        return;
      }
      if (data.length - off - 4 < len) break;
      _frames.add(Uint8List.sublistView(data, off + 4, off + 4 + len));
      off += 4 + len;
    }
    _pending = Uint8List.fromList(Uint8List.sublistView(data, off));
  }

  void _onDone() => _frames.close();
  void _onError(Object e) {
    _frames.addError(e);
    _frames.close();
    _sub.cancel();
  }
}

/// Verschlüsselter Kanal zwischen zwei Geräten.
///
/// Handshake (Initiator I, Responder R; s = statisch, e = Wegwerf-Schlüssel):
///   I→R  hello {id, name, s_I, e_I, mode, [commit = H(s_I‖n_I)]}
///   R→I  hello {id, name, s_R, e_R, [n_R]}
///   I→R  reveal {n_I}                                  (nur beim Koppeln)
///   Schlüssel = HKDF(DH(e_I,e_R) ‖ DH(s_I,e_R) ‖ DH(e_I,s_R), Transkript)
///   → je Richtung ein ChaCha20-Poly1305-Schlüssel, Zähler als Nonce.
/// Nur wer den geheimen statischen Schlüssel besitzt, kann die Schlüssel
/// ableiten – bekannte Partner sind damit gegenseitig authentisiert.
/// Beim Koppeln zeigen beide den Code H(s_I‖s_R‖n_I‖n_R) mod 10⁶; durch die
/// vorher festgelegte Zufallszahl (commit) kann ein Angreifer im Netz den Code
/// nicht passend „hinrechnen“.
class SecureChannel {
  SecureChannel._(
    this._socket,
    this._reader,
    this.peerId,
    this.peerName,
    this.peerStatic,
    this.sas,
    this._sendKey,
    this._recvKey,
  );

  final Socket _socket;
  final StreamIterator<Uint8List> _reader;
  final String peerId;
  final String peerName;
  final Uint8List peerStatic;

  /// Kopplungscode (nur im Kopplungsmodus), 6 Ziffern.
  final String? sas;

  final Uint8List _sendKey;
  final Uint8List _recvKey;
  int _sendCounter = 0;
  int _recvCounter = 0;

  static const _salt = 'mync-sync-v1';

  static Uint8List _nonce(int counter) {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint64(4, counter);
    return n;
  }

  static Future<void> _sendRaw(Socket s, List<int> data) async {
    final len = ByteData(4)..setUint32(0, data.length);
    s.add(len.buffer.asUint8List());
    s.add(data);
    await s.flush();
  }

  static Future<Map<String, dynamic>> _recvJson(
    StreamIterator<Uint8List> it,
  ) async {
    if (!await it.moveNext().timeout(const Duration(seconds: 30))) {
      throw SyncProtocolException('Verbindung beendet');
    }
    final m = jsonDecode(utf8.decode(it.current)) as Map<String, dynamic>;
    if (m['t'] == 'error') {
      throw SyncProtocolException(m['msg'] as String? ?? 'abgelehnt');
    }
    return m;
  }

  static String _sasOf(List<int> sI, List<int> sR, List<int> nI, List<int> nR) {
    final h = sha256Bytes([
      ...utf8.encode('mync-sas'),
      ...sI,
      ...sR,
      ...nI,
      ...nR,
    ]);
    final v = ByteData.sublistView(h).getUint32(0) % 1000000;
    return v.toString().padLeft(6, '0');
  }

  static (Uint8List, Uint8List) _keys(List<int> ikm, List<int> transcript) {
    final k = hkdf(utf8.encode(_salt), ikm, sha256Bytes(transcript), 64);
    return (Uint8List.sublistView(k, 0, 32), Uint8List.sublistView(k, 32, 64));
  }

  /// Verbindet sich als Initiator. [knownPeerStatic]: erwarteter Schlüssel
  /// des Partners (Sync); null = Kopplung.
  static Future<SecureChannel> connect(
    String host,
    int port,
    DeviceIdentity me, {
    Uint8List? knownPeerStatic,
  }) async {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 10),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    final it = StreamIterator(_FrameReader(socket).frames);
    try {
      final pairing = knownPeerStatic == null;
      final (eS, eP) = x25519Keypair();
      final nI = randomBytes(16);
      final hello = utf8.encode(
        jsonEncode({
          't': 'hello',
          'v': 1,
          'id': me.id,
          'name': me.name,
          's': hex(me.public),
          'e': hex(eP),
          'mode': pairing ? 'pair' : 'sync',
          if (pairing) 'commit': hex(sha256Bytes([...me.public, ...nI])),
        }),
      );
      await _sendRaw(socket, hello);
      if (!await it.moveNext().timeout(const Duration(seconds: 30))) {
        throw SyncProtocolException('keine Antwort');
      }
      final helloRBytes = it.current;
      final r = jsonDecode(utf8.decode(helloRBytes)) as Map<String, dynamic>;
      if (r['t'] == 'error') {
        throw SyncProtocolException(r['msg'] as String? ?? 'abgelehnt');
      }
      final sR = unhex(r['s'] as String);
      final eR = unhex(r['e'] as String);
      if (!pairing && hex(sR) != hex(knownPeerStatic)) {
        throw SyncProtocolException(
          'Gerät meldet sich mit einem anderen Schlüssel – Verbindung abgebrochen.',
        );
      }
      String? sas;
      if (pairing) {
        await _sendRaw(
          socket,
          utf8.encode(jsonEncode({'t': 'reveal', 'nonce': hex(nI)})),
        );
        sas = _sasOf(me.public, sR, nI, unhex(r['nonce'] as String));
      }
      final ikm = [
        ...x25519(eS, eR),
        ...x25519(me.secret, eR),
        ...x25519(eS, sR),
      ];
      final (kIR, kRI) = _keys(ikm, [...hello, ...helloRBytes]);
      final ch = SecureChannel._(
        socket,
        it,
        r['id'] as String,
        r['name'] as String,
        sR,
        sas,
        kIR,
        kRI,
      );
      await ch._confirm();
      return ch;
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  /// Nimmt eine Verbindung als Responder an. [lookupPeer] liefert zu einer
  /// Geräte-ID den gespeicherten Schlüssel (null = unbekannt);
  /// [allowPairing]: Kopplung gerade erlaubt?
  static Future<SecureChannel> accept(
    Socket socket,
    DeviceIdentity me, {
    required Uint8List? Function(String id) lookupPeer,
    required bool allowPairing,
  }) async {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final it = StreamIterator(_FrameReader(socket).frames);
    try {
      if (!await it.moveNext().timeout(const Duration(seconds: 30))) {
        throw SyncProtocolException('keine Anfrage');
      }
      final helloI = it.current;
      final h = jsonDecode(utf8.decode(helloI)) as Map<String, dynamic>;
      if (h['t'] != 'hello' || h['v'] != 1) {
        throw SyncProtocolException('unbekanntes Protokoll');
      }
      final pairing = h['mode'] == 'pair';
      final sI = unhex(h['s'] as String);
      final eI = unhex(h['e'] as String);
      Future<Never> reject(String msg) async {
        await _sendRaw(
          socket,
          utf8.encode(jsonEncode({'t': 'error', 'msg': msg})),
        );
        throw SyncProtocolException(msg);
      }

      if (pairing && !allowPairing) {
        await reject('Kopplung ist auf ${me.name} gerade nicht freigegeben.');
      }
      if (!pairing) {
        final known = lookupPeer(h['id'] as String);
        if (known == null) await reject('Dieses Gerät ist nicht gekoppelt.');
        if (hex(known) != hex(sI)) {
          await reject('Schlüssel passt nicht zum gekoppelten Gerät.');
        }
      }
      final (eS, eP) = x25519Keypair();
      final nR = randomBytes(16);
      final helloR = utf8.encode(
        jsonEncode({
          't': 'hello',
          'v': 1,
          'id': me.id,
          'name': me.name,
          's': hex(me.public),
          'e': hex(eP),
          if (pairing) 'nonce': hex(nR),
        }),
      );
      await _sendRaw(socket, helloR);
      String? sas;
      if (pairing) {
        final rev = await _recvJson(it);
        final nI = unhex(rev['nonce'] as String);
        if (hex(sha256Bytes([...sI, ...nI])) != h['commit']) {
          throw SyncProtocolException('Kopplung manipuliert');
        }
        sas = _sasOf(sI, me.public, nI, nR);
      }
      final ikm = [
        ...x25519(eS, eI),
        ...x25519(eS, sI),
        ...x25519(me.secret, eI),
      ];
      final (kIR, kRI) = _keys(ikm, [...helloI, ...helloR]);
      final ch = SecureChannel._(
        socket,
        it,
        h['id'] as String,
        h['name'] as String,
        sI,
        sas,
        kRI,
        kIR,
      );
      await ch._confirm();
      return ch;
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  /// Schlüsselbestätigung: beide senden „ready“ verschlüsselt.
  Future<void> _confirm() async {
    await sendJson({'t': 'ready'});
    final m = await receive().timeout(const Duration(seconds: 30));
    if (m is! Map || m['t'] != 'ready') {
      throw SyncProtocolException('Schlüsselbestätigung fehlgeschlagen');
    }
  }

  Future<void> _sendEncrypted(List<int> plain) async {
    final ct = aeadSeal(_sendKey, _nonce(_sendCounter++), const [], plain);
    await _sendRaw(_socket, ct);
  }

  /// JSON-Nachricht senden.
  Future<void> sendJson(Map<String, Object?> m) =>
      _sendEncrypted([1, ...utf8.encode(jsonEncode(m))]);

  /// Binärstück für Anfrage [id] senden (leer = Ende).
  Future<void> sendBinary(int id, List<int> data) {
    final b = Uint8List(5 + data.length);
    b[0] = 2;
    ByteData.sublistView(b).setUint32(1, id);
    b.setAll(5, data);
    return _sendEncrypted(b);
  }

  /// Nächste Nachricht: Map (JSON) oder (id, Bytes) bei Binärdaten; null = Ende.
  Future<Object?> receive() async {
    if (!await _reader.moveNext()) return null;
    final plain = aeadOpen(
      _recvKey,
      _nonce(_recvCounter++),
      const [],
      _reader.current,
    );
    if (plain == null) {
      throw SyncProtocolException(
        'Nachricht manipuliert oder falscher Schlüssel',
      );
    }
    if (plain.isEmpty) throw SyncProtocolException('leere Nachricht');
    if (plain[0] == 1) {
      return jsonDecode(utf8.decode(Uint8List.sublistView(plain, 1)));
    }
    if (plain[0] == 2 && plain.length >= 5) {
      return (
        ByteData.sublistView(plain, 1, 5).getUint32(0),
        Uint8List.sublistView(plain, 5),
      );
    }
    throw SyncProtocolException('unbekannter Nachrichtentyp');
  }

  Future<void> close() async {
    try {
      await _socket.flush();
      await _socket.close();
    } catch (_) {}
    _socket.destroy();
  }
}
