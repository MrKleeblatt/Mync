import 'dart:convert';
import 'dart:io';

import '../core/mync_core.dart';
import 'channel.dart';

/// Ein Eintrag des Manifests, wie er beim Sync ausgetauscht wird.
class SyncEntry {
  const SyncEntry(this.path, this.audioHash, this.tagHash, {this.size = 0});
  final String path;
  final String audioHash;
  final String tagHash;
  final int size;

  factory SyncEntry.fromJson(Map<String, dynamic> j) => SyncEntry(
    j['path'] as String,
    j['audio_hash'] as String,
    j['tag_hash'] as String,
    size: j['size'] as int? ?? 0,
  );

  Map<String, Object> toJson() => {
    'path': path,
    'audio_hash': audioHash,
    'tag_hash': tagHash,
    'size': size,
  };

  bool sameAs(SyncEntry o) =>
      path == o.path && audioHash == o.audioHash && tagHash == o.tagHash;
  String get key => '$path\u0000$audioHash\u0000$tagHash';
}

/// Ein gekoppeltes Gerät.
class Peer {
  Peer({
    required this.id,
    required this.name,
    required this.publicKey,
    this.host,
    this.port,
    this.lastSyncMs = 0,
  });
  final String id;
  String name;
  final String publicKey; // hex
  String? host;
  int? port;
  int lastSyncMs;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'public': publicKey,
    'host': host,
    'port': port,
    'last_sync': lastSyncMs,
  };

  factory Peer.fromJson(Map<String, dynamic> j) => Peer(
    id: j['id'] as String,
    name: j['name'] as String,
    publicKey: j['public'] as String,
    host: j['host'] as String?,
    port: j['port'] as int?,
    lastSyncMs: j['last_sync'] as int? ?? 0,
  );
}

/// Speichert Identität, Partner, gemeinsamen Stand und Ignorier-Listen
/// unter `<dataDir>/sync/`.
class SyncStore {
  SyncStore(String dataDir) : dir = Directory('$dataDir/sync');

  final Directory dir;
  late DeviceIdentity identity;
  final Map<String, Peer> peers = {};

  File _f(String name) => File('${dir.path}/$name');

  Future<void> _write(String name, Object json) async {
    await dir.create(recursive: true);
    final tmp = _f('$name.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(_f(name).path);
  }

  Future<Object?> _read(String name) async {
    try {
      final f = _f(name);
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> load({required String defaultName}) async {
    final id = await _read('identity.json') as Map<String, dynamic>?;
    if (id == null) {
      final (s, p) = x25519Keypair();
      identity = DeviceIdentity(
        id: hex(randomBytes(12)),
        name: defaultName,
        secret: s,
        public: p,
      );
      await saveIdentity();
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', _f('identity.json').path]);
      }
    } else {
      identity = DeviceIdentity(
        id: id['id'] as String,
        // früher fester Platzhalter: durch den echten Gerätenamen ersetzen
        name: id['name'] == 'Android-Handy'
            ? defaultName
            : id['name'] as String,
        secret: unhex(id['secret'] as String),
        public: unhex(id['public'] as String),
      );
      if (id['name'] != identity.name) await saveIdentity();
    }
    peers.clear();
    for (final p in (await _read('peers.json') as List? ?? const [])) {
      final peer = Peer.fromJson(p as Map<String, dynamic>);
      peers[peer.id] = peer;
    }
  }

  Future<void> saveIdentity() => _write('identity.json', {
    'id': identity.id,
    'name': identity.name,
    'secret': hex(identity.secret),
    'public': hex(identity.public),
  });

  Future<void> savePeers() =>
      _write('peers.json', [for (final p in peers.values) p.toJson()]);

  Future<List<SyncEntry>> loadBase(String peerId) async => [
    for (final e in (await _read('base-$peerId.json') as List? ?? const []))
      SyncEntry.fromJson(e as Map<String, dynamic>),
  ];

  Future<void> saveBase(String peerId, List<SyncEntry> base) =>
      _write('base-$peerId.json', [for (final e in base) e.toJson()]);

  Future<Set<String>> loadIgnored(String peerId) async =>
      ((await _read('ignore-$peerId.json') as List?) ?? const [])
          .cast<String>()
          .toSet();

  Future<void> saveIgnored(String peerId, Set<String> keys) =>
      _write('ignore-$peerId.json', keys.toList());

  Future<void> removePeer(String id) async {
    peers.remove(id);
    await savePeers();
    for (final n in ['base-$id.json', 'ignore-$id.json']) {
      final f = _f(n);
      if (await f.exists()) await f.delete();
    }
  }
}
