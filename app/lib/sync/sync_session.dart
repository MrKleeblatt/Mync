import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/mync_core.dart';
import '../log.dart';
import 'channel.dart';
import 'sync_store.dart';
import '../core/music_fs.dart';

/// Was der Sync von der App braucht (in Tests ersetzbar).
abstract class SyncHost {
  /// Musikordner (Wurzel) und Manifest-Datenbank.
  String get root;
  String get db;

  /// Bibliothek neu einlesen (inkrementell).
  Future<void> rescan();

  /// Nach dem Anwenden: geänderte Pfade (z. B. Android-MediaScanner).
  Future<void> afterApply(List<String> changedPaths);
}

enum ChangeKind { add, delete, rename, tags, replace }

/// Eine Änderung auf der Gegenseite gegenüber dem gemeinsamen Stand.
class RemoteChange {
  RemoteChange(
    this.kind,
    this.oldEntry,
    this.newEntry, {
    this.tagsChanged = false,
  });
  final ChangeKind kind;
  final SyncEntry? oldEntry;
  final SyncEntry? newEntry;
  final bool tagsChanged;

  static RemoteChange fromJson(Map<String, dynamic> j) {
    final kind = ChangeKind.values.byName(j.keys.single);
    final d = j.values.single as Map<String, dynamic>;
    SyncEntry? e(String k) =>
        d[k] == null ? null : SyncEntry.fromJson(d[k] as Map<String, dynamic>);
    return RemoteChange(
      kind,
      e('old'),
      e('new'),
      tagsChanged: d['tags_changed'] == true,
    );
  }

  /// Pfad, unter dem die Datei auf dem Gerät mit dieser Änderung jetzt liegt.
  String? get resultPath => newEntry?.path;
  String? get basePath => oldEntry?.path;
}

enum Decision { open, accept, reject, ignore }

/// Ein Eintrag der Inbox: eine Änderung vom anderen Gerät.
class InboxItem {
  InboxItem(this.remote, {this.local});
  final RemoteChange remote;

  /// Bei Konflikten: was auf diesem Gerät geändert wurde.
  final RemoteChange? local;
  bool get isConflict => local != null;

  Decision decision = Decision.open;
  bool done = false;
  String? error;

  /// Für das Logbuch: Art und Datei.
  String get title =>
      '${remote.kind.name} ${remote.resultPath ?? remote.basePath ?? ''}';

  String get ignoreKey =>
      '${remote.kind.name}|${remote.oldEntry?.key ?? ''}|${remote.newEntry?.key ?? ''}';
}

/// Eine laufende Sync-Sitzung mit einem Partner.
class SyncSession extends ChangeNotifier {
  SyncSession(
    this.channel,
    this.peer,
    this.host,
    this.store, {
    required this.initiator,
  });

  final SecureChannel channel;
  final Peer peer;
  final SyncHost host;
  final SyncStore store;
  final bool initiator;

  String status = 'Verbinde …';
  List<InboxItem> items = [];
  bool ready = false;
  bool applying = false;
  double progress = 0;
  bool finished = false;
  bool peerFinished = false;
  bool closed = false;
  String? error;

  int _nextId = 1;
  final _pending = <int, Completer<Object?>>{};
  final _binary = <int, StreamController<Uint8List>>{};
  final _scanned = Completer<void>();
  List<SyncEntry> _local = const [];
  List<SyncEntry> _remote = const [];
  Set<String> _ignored = {};

  // ─── Start ────────────────────────────────────────────────────────────

  /// Liest beide Bibliotheken ein und berechnet die Inbox.
  Future<void> start() async {
    unawaited(_receiveLoop());
    try {
      _setStatus('Lese Bibliothek ein …');
      await host.rescan();
      _local = await _localEntries();
      _scanned.complete();
      _setStatus('Hole Dateiliste von ${peer.name} …');
      final remote = await request('manifest') as List;
      _remote = [
        for (final e in remote) SyncEntry.fromJson(e as Map<String, dynamic>),
      ];
      await _computeInbox();
    } catch (e, st) {
      _fail('Sync fehlgeschlagen', e, st);
    }
  }

  Future<List<SyncEntry>> _localEntries() async => [
    for (final e in await manifestEntries(root: host.root, db: host.db))
      SyncEntry.fromJson(e),
  ];

  Future<void> _computeInbox() async {
    var base = await store.loadBase(peer.id);
    if (base.isEmpty) base = _firstSyncBase();
    _ignored = await store.loadIgnored(peer.id);
    final plan = syncPlan({
      'base': [for (final e in base) e.toJson()],
      'local': [for (final e in _local) e.toJson()],
      'remote': [for (final e in _remote) e.toJson()],
    });
    final list = <InboxItem>[];
    for (final p in plan) {
      final InboxItem item;
      if (p.containsKey('apply')) {
        item = InboxItem(
          RemoteChange.fromJson(
            (p['apply'] as Map)['change'] as Map<String, dynamic>,
          ),
        );
      } else {
        final c = p['conflict'] as Map<String, dynamic>;
        item = InboxItem(
          RemoteChange.fromJson(c['remote'] as Map<String, dynamic>),
          local: RemoteChange.fromJson(c['local'] as Map<String, dynamic>),
        );
      }
      if (!_ignored.contains(item.ignoreKey)) list.add(item);
    }
    items = list;
    ready = true;
    _setStatus(
      list.isEmpty
          ? 'Alles auf dem gleichen Stand.'
          : '${list.length} Änderung(en) von ${peer.name}',
    );
  }

  /// Erster Abgleich (noch kein gemeinsamer Stand): Identisches gilt als
  /// gemeinsam; gleiche Aufnahmen unter anderem Namen werden über den
  /// Audio-Hash gepaart – so erscheinen sie als Umbenennung statt doppelt.
  List<SyncEntry> _firstSyncBase() {
    final remoteKeys = {for (final e in _remote) e.key};
    final localPaths = {for (final e in _local) e.path};
    final remotePaths = {for (final e in _remote) e.path};
    final base = [
      for (final e in _local)
        if (remoteKeys.contains(e.key)) e,
    ];
    final usedLocal = {for (final e in base) e.path};
    final byAudio = <String, List<SyncEntry>>{};
    for (final e in _local) {
      if (!usedLocal.contains(e.path) && !remotePaths.contains(e.path)) {
        byAudio.putIfAbsent(e.audioHash, () => []).add(e);
      }
    }
    for (final r in _remote) {
      if (localPaths.contains(r.path)) continue;
      final cands = byAudio[r.audioHash];
      if (cands == null || cands.isEmpty) continue;
      // lokale Fassung als Basis → die Gegenseite hat „umbenannt“
      base.add(cands.removeAt(0));
    }
    return base;
  }

  // ─── Nachrichten ──────────────────────────────────────────────────────

  Future<void> _receiveLoop() async {
    try {
      while (true) {
        final m = await channel.receive();
        if (m == null) break;
        if (m is (int, Uint8List)) {
          final c = _binary[m.$1];
          if (c == null) continue;
          if (m.$2.isEmpty) {
            _binary.remove(m.$1);
            await c.close();
          } else {
            c.add(m.$2);
          }
          continue;
        }
        final msg = m as Map<String, dynamic>;
        switch (msg['t']) {
          case 'req':
            unawaited(_handle(msg));
          case 'res':
            final c = _pending.remove(msg['id'] as int);
            if (c == null) break;
            if (msg['ok'] == true) {
              c.complete(msg['data']);
            } else {
              c.completeError(
                SyncProtocolException(msg['err'] as String? ?? 'Fehler'),
              );
            }
          case 'note' when msg['what'] == 'finished':
            peerFinished = true;
            notifyListeners();
            if (finished) await close();
        }
      }
    } catch (e) {
      if (!closed) _fail('Verbindung unterbrochen', e);
    }
    for (final c in _pending.values) {
      c.completeError(SyncProtocolException('Verbindung beendet'));
    }
    _pending.clear();
    for (final c in _binary.values) {
      c.addError(SyncProtocolException('Verbindung beendet'));
      await c.close();
    }
    _binary.clear();
    closed = true;
    notifyListeners();
  }

  /// Stellt eine Anfrage an die Gegenseite.
  Future<Object?> request(String op, [Map<String, Object?> args = const {}]) {
    final id = _nextId++;
    final c = Completer<Object?>();
    _pending[id] = c;
    channel.sendJson({'t': 'req', 'id': id, 'op': op, 'args': args});
    return c.future;
  }

  /// Datei von der Gegenseite holen: (Größe, SHA-256, Datenstrom).
  Future<(int, String, Stream<Uint8List>)> _requestFile(String path) async {
    final id = _nextId++;
    final c = Completer<Object?>();
    final data = StreamController<Uint8List>();
    _pending[id] = c;
    _binary[id] = data;
    await channel.sendJson({
      't': 'req',
      'id': id,
      'op': 'file',
      'args': {'path': path},
    });
    final head = await c.future as Map<String, dynamic>;
    return (head['size'] as int, head['sha256'] as String, data.stream);
  }

  String _abs(String rel) {
    if (rel.startsWith('/') || rel.split('/').contains('..')) {
      throw SyncProtocolException('Ungültiger Pfad: $rel');
    }
    return '${host.root}/$rel';
  }

  Future<void> _handle(Map<String, dynamic> m) async {
    final id = m['id'] as int;
    final args = (m['args'] as Map?)?.cast<String, dynamic>() ?? const {};
    try {
      switch (m['op']) {
        case 'manifest':
          await _scanned.future;
          final now = await _localEntries();
          await channel.sendJson({
            't': 'res',
            'id': id,
            'ok': true,
            'data': [for (final e in now) e.toJson()],
          });
        case 'tags':
          final t = await readTags(_abs(args['path'] as String));
          await channel.sendJson({
            't': 'res',
            'id': id,
            'ok': true,
            'data': {'fields': t.fields, 'picture_hashes': t.pictureHashes},
          });
        case 'file':
          final loc = _abs(args['path'] as String);
          // Ordnerfreigabe (Android): erst eine lokale Kopie
          final copy = MusicFs.isTree(loc) ? await _tempFile(loc) : null;
          final f = File(copy ?? loc);
          try {
            final size = await f.length();
            final sha = await sha256File(f.path);
            await channel.sendJson({
              't': 'res',
              'id': id,
              'ok': true,
              'data': {'size': size, 'sha256': sha},
            });
            await for (final chunk in f.openRead()) {
              for (var o = 0; o < chunk.length; o += 64 * 1024) {
                await channel.sendBinary(
                  id,
                  chunk.sublist(o, (o + 64 * 1024).clamp(0, chunk.length)),
                );
              }
            }
            await channel.sendBinary(id, const []);
          } finally {
            if (copy != null) await _deleteQuietly(copy);
          }
        default:
          throw SyncProtocolException('Unbekannte Anfrage ${m['op']}');
      }
    } catch (e) {
      await channel.sendJson({'t': 'res', 'id': id, 'ok': false, 'err': '$e'});
    }
  }

  // ─── Entscheidungen anwenden ──────────────────────────────────────────

  void decide(InboxItem item, Decision d) {
    item.decision = d;
    notifyListeners();
  }

  /// Alle offenen Einträge annehmen – Löschungen nur mit [includeDeletes].
  void acceptAll({bool includeDeletes = false}) {
    for (final i in items) {
      if (i.done || i.decision != Decision.open) continue;
      if (!includeDeletes && i.remote.kind == ChangeKind.delete) continue;
      i.decision = Decision.accept;
    }
    notifyListeners();
  }

  /// Wendet alle angenommenen Änderungen an; „immer ignorieren“ wird gespeichert.
  Future<void> applyDecisions() async {
    if (applying) return;
    applying = true;
    progress = 0;
    final changed = <String>[];
    final todo = items
        .where((i) => !i.done && i.decision == Decision.accept)
        .toList();
    var n = 0;
    for (final item in todo) {
      _setStatus('Übernehme ${n + 1} von ${todo.length} …');
      try {
        final localPath = item.isConflict
            ? item.local!.resultPath
            : item.remote.basePath;
        changed.addAll(await _makeLocalMatch(localPath, item.remote.newEntry));
        item.done = true;
        item.error = null;
        logNetwork('Sync ${peer.name}: übernommen ${item.title}');
      } catch (e, st) {
        logError(
          'Sync ${peer.name}: Übernehmen fehlgeschlagen – ${item.title}',
          e,
          st,
        );
        item.error = 'fehlgeschlagen';
      }
      n++;
      progress = n / todo.length;
      notifyListeners();
    }
    final ignore = items
        .where((i) => i.decision == Decision.ignore)
        .map((i) => i.ignoreKey);
    if (ignore.isNotEmpty) {
      _ignored.addAll(ignore);
      await store.saveIgnored(peer.id, _ignored);
      for (final i in items) {
        if (i.decision == Decision.ignore) i.done = true;
      }
    }
    if (changed.isNotEmpty) {
      await host.rescan();
      await host.afterApply(changed);
    }
    applying = false;
    final failed = todo.where((i) => i.error != null).length;
    _setStatus(
      failed == 0
          ? '${todo.length - failed} Änderung(en) übernommen.'
          : '$failed Änderung(en) fehlgeschlagen.',
    );
  }

  /// Bringt die lokale Datei [localPath] auf den Stand [target] der Gegenseite
  /// (null = löschen). Gibt die geänderten Pfade zurück.
  Future<List<String>> _makeLocalMatch(
    String? localPath,
    SyncEntry? target,
  ) async {
    final local = {for (final e in await _localEntries()) e.path: e};
    final cur = localPath == null ? null : local[localPath];
    if (target == null) {
      if (localPath != null && cur != null) await _trash(localPath);
      return [?localPath];
    }
    final changed = <String>[];
    if (cur != null && cur.audioHash == target.audioHash) {
      if (localPath != target.path) {
        if (await MusicFs.exists(_abs(target.path))) await _trash(target.path);
        await _move(localPath!, target.path);
        changed.addAll([localPath, target.path]);
      }
      if (cur.tagHash != target.tagHash) {
        await _applyTags(target.path);
        changed.add(target.path);
      }
      return changed;
    }
    await _fetchInto(target.path);
    changed.add(target.path);
    if (localPath != null && localPath != target.path && cur != null) {
      await _trash(localPath);
      changed.add(localPath);
    }
    return changed;
  }

  /// Übernimmt die Tags der Gegenseite (oder die ganze Datei, falls nötig).
  Future<void> _applyTags(String path) async {
    final remote =
        await request('tags', {'path': path}) as Map<String, dynamic>;
    final fields = {
      for (final e in (remote['fields'] as Map).entries)
        e.key as String: (e.value as List).cast<String>(),
    };
    final pics = (remote['picture_hashes'] as List).cast<String>();
    final abs = _abs(path);
    final mine = await readTags(abs);
    var ok = mine.writable && listEquals(mine.pictureHashes, pics);
    if (ok) {
      try {
        final after = await writeTags(abs, fields);
        ok = mapEquals(_norm(after.fields), _norm(fields));
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) {
      await _fetchInto(
        path,
      ); // Format nicht schreibbar oder Cover anders: ganze Datei
    }
  }

  static Map<String, String> _norm(Map<String, List<String>> f) => {
    for (final e in f.entries) e.key: e.value.join('\u0000'),
  };

  /// Lädt die Datei [path] von der Gegenseite und ersetzt die lokale (alte → Papierkorb).
  Future<void> _fetchInto(String path) async {
    final loc = _abs(path);
    final tree = MusicFs.isTree(loc);
    final File tmp;
    if (tree) {
      tmp = File(await _tempPath(path));
    } else {
      final dst = File(loc);
      await dst.parent.create(recursive: true);
      tmp = File('${dst.parent.path}/.${dst.uri.pathSegments.last}.mync-part');
    }
    final (size, sha, data) = await _requestFile(path);
    final sink = tmp.openWrite();
    try {
      await data.forEach(sink.add);
    } finally {
      await sink.close();
    }
    if (await tmp.length() != size || await sha256File(tmp.path) != sha) {
      await tmp.delete();
      throw SyncProtocolException('Übertragung von $path fehlerhaft');
    }
    if (await MusicFs.exists(loc)) await _trash(path);
    if (tree) {
      try {
        await MusicFs.copyIn(tmp.path, loc);
      } finally {
        await _deleteQuietly(tmp.path);
      }
    } else {
      await tmp.rename(loc);
    }
  }

  static Future<String> _tempPath(String rel) async {
    final dir = await Directory('${MusicFs.tempDir}/mync-sync')
        .create(recursive: true);
    return '${dir.path}/${DateTime.now().microsecondsSinceEpoch}-${rel.split('/').last}';
  }

  static Future<String> _tempFile(String loc) async {
    final p = await _tempPath(MusicFs.split(loc).$2);
    await MusicFs.copyOut(loc, p);
    return p;
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  Future<void> _move(String from, String to) async {
    await MusicFs.rename(_abs(from), _abs(to));
    await _pruneDirs(from);
  }

  /// Verschiebt in `.mync-trash/<Datum>/…` (30 Tage wiederherstellbar).
  Future<void> _trash(String rel) async {
    final d = DateTime.now();
    final day =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    var dst = '${host.root}/.mync-trash/$day/$rel';
    var n = 1;
    while (await MusicFs.exists(dst)) {
      dst = '${host.root}/.mync-trash/$day/$rel.${n++}';
    }
    await MusicFs.rename(_abs(rel), dst);
    await _pruneDirs(rel);
  }

  /// Leere Ordner nach Verschieben/Löschen entfernen.
  Future<void> _pruneDirs(String rel) async {
    var parts = rel.split('/')..removeLast();
    while (parts.isNotEmpty) {
      final d = '${host.root}/${parts.join('/')}';
      try {
        if ((await MusicFs.list(d)).isEmpty) {
          await MusicFs.delete(d);
        } else {
          break;
        }
      } catch (_) {
        break;
      }
      parts = parts..removeLast();
    }
  }

  // ─── Abschluss ────────────────────────────────────────────────────────

  /// Speichert den gemeinsamen Stand (was auf beiden Geräten gleich ist).
  Future<void> finish() async {
    if (finished) return;
    try {
      _setStatus('Schließe ab …');
      await host.rescan();
      final local = await _localEntries();
      final remote = [
        for (final e in await request('manifest') as List)
          SyncEntry.fromJson(e as Map<String, dynamic>),
      ];
      final remoteKeys = {for (final e in remote) e.key};
      await store.saveBase(peer.id, [
        for (final e in local)
          if (remoteKeys.contains(e.key)) e,
      ]);
      peer.lastSyncMs = DateTime.now().millisecondsSinceEpoch;
      await store.savePeers();
      finished = true;
      await channel.sendJson({'t': 'note', 'what': 'finished'});
      _setStatus(
        peerFinished
            ? 'Abgeschlossen.'
            : 'Abgeschlossen – ${peer.name} entscheidet noch …',
      );
      if (peerFinished) await close();
    } catch (e, st) {
      _fail('Abschluss fehlgeschlagen', e, st);
    }
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    await channel.close();
    notifyListeners();
  }

  void _setStatus(String s) {
    status = s;
    logNetwork('Sync ${peer.name}: $s');
    notifyListeners();
  }

  /// Kurze Meldung für die Anzeige, Einzelheiten ins Logbuch.
  void _fail(String msg, [Object? e, StackTrace? st]) {
    logError('Sync ${peer.name}: $msg', e, st);
    error = msg;
    status = msg;
    if (!_scanned.isCompleted) _scanned.complete();
    notifyListeners();
  }
}
