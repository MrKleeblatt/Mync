import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;

import '../library/library.dart';
import '../library/playlists.dart';
import '../library/track.dart';
import '../settings.dart';
import 'queue.dart';
import 'state_store.dart';

/// Wiedergabestatistik eines Titels.
class PlayStat {
  PlayStat({this.plays = 0, this.lastPlayedMs = 0});
  int plays;
  int lastPlayedMs;

  Map<String, int> toJson() => {'plays': plays, 'last': lastPlayedMs};
  factory PlayStat.fromJson(Map<String, dynamic> j) => PlayStat(
    plays: j['plays'] as int? ?? 0,
    lastPlayedMs: j['last'] as int? ?? 0,
  );
}

/// Steuert die Wiedergabe (media_kit/libmpv) und verwaltet mehrere
/// Warteschlangen. Die mpv-Playlist entspricht immer der aktuellen
/// Warteschlange – so ist die Wiedergabe lückenlos und Änderungen an der
/// Warteschlange unterbrechen den laufenden Titel nicht.
class PlayerController extends ChangeNotifier {
  PlayerController(this.settings, this.library)
    : _store = StateStore(settings.stateFile);

  final AppSettings settings;
  final Library library;
  final StateStore _store;
  late final Player player;

  final List<PlayQueue> queues = [];
  int _current = 0;
  PlayQueue get queue => queues[_current];
  int get currentQueueIndex => _current;

  bool playing = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  String? error;

  /// Ist die aktuelle Warteschlange in mpv geladen?
  bool _loaded = false;
  bool _opening = false;
  final _subs = <StreamSubscription<Object?>>[];

  final Map<String, PlayStat> stats = {};

  Track? get currentTrack {
    final p = queue.current;
    return p == null ? null : library.byPath(p);
  }

  String? get currentPath => queue.current;

  // ─── Start ─────────────────────────────────────────────────────────────

  Future<void> init() async {
    player = Player(
      configuration: const PlayerConfiguration(
        title: 'mync',
        logLevel: MPVLogLevel.warn,
      ),
    );
    final native = player.platform;
    if (native is NativePlayer) {
      await native.setProperty(
        'vid',
        'no',
      ); // eingebettete Cover nicht als Video öffnen
      await native.setProperty('audio-display', 'no');
      await native.setProperty('gapless-audio', 'yes');
      await native.setProperty('prefetch-playlist', 'yes');
      await native.setProperty('audio-client-name', 'mync');
      await native.setProperty('replaygain', settings.replayGain);
      final ao = Platform.environment['MYNC_MPV_AO'];
      if (ao != null && ao.isNotEmpty) await native.setProperty('ao', ao);
    }
    await player.setVolume(settings.volume);
    await player.setRate(settings.speed);
    await applyEqualizer();

    final state = await _store.load();
    for (final q in (state['queues'] as List? ?? const [])) {
      queues.add(PlayQueue.fromJson(q as Map<String, dynamic>));
    }
    if (queues.isEmpty) {
      queues.add(PlayQueue(id: _newId(), name: 'Warteschlange 1'));
    }
    _current = (state['current'] as int? ?? 0).clamp(0, queues.length - 1);
    for (final e in ((state['stats'] as Map?) ?? const {}).entries) {
      stats[e.key as String] = PlayStat.fromJson(
        e.value as Map<String, dynamic>,
      );
    }

    _subs.addAll([
      player.stream.playing.listen((v) {
        playing = v;
        notifyListeners();
      }),
      player.stream.position.listen((p) {
        position = p;
        if (_loaded && !_opening) {
          queue.positionMs = p.inMilliseconds;
          _save(delay: const Duration(seconds: 5));
        }
      }),
      player.stream.duration.listen((d) {
        duration = d;
        notifyListeners();
      }),
      player.stream.playlist.listen(_onPlaylist),
      player.stream.completed.listen(_onCompleted),
      player.stream.error.listen((e) {
        debugPrint('mpv: $e');
        error = e;
        notifyListeners();
      }),
    ]);

    library.onRenamed = renamePaths;
    await _openQueue(play: false);
    notifyListeners();
  }

  static String _newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
      Random().nextInt(1 << 20).toRadixString(36);

  Media _media(String rel) => Media(Uri.file(library.abs(rel)).toString());

  // ─── mpv-Synchronisation ───────────────────────────────────────────────

  Future<void> _openQueue({required bool play}) async {
    final q = queue;
    if (q.isEmpty) {
      _loaded = false;
      await player.stop();
      position = Duration.zero;
      duration = Duration.zero;
      notifyListeners();
      return;
    }
    _opening = true;
    try {
      await player.open(
        Playlist(q.items.map(_media).toList(), index: q.index),
        play: false,
      );
      await _applyRepeat();
      if (q.positionMs > 0) {
        try {
          await player.stream.duration
              .firstWhere((d) => d > Duration.zero)
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
        await player.seek(Duration(milliseconds: q.positionMs));
        position = Duration(milliseconds: q.positionMs);
      }
      _loaded = true;
      if (play) {
        if (q.positionMs == 0) _countPlay(q.current);
        await player.play();
      }
    } finally {
      _opening = false;
    }
    notifyListeners();
  }

  void _onPlaylist(Playlist pl) {
    if (!_loaded || _opening) return;
    final q = queue;
    if (pl.index == q.index || pl.index < 0 || pl.index >= q.items.length) {
      return;
    }
    q.index = pl.index;
    q.positionMs = 0;
    _countPlay(q.current);
    if (sleepAfterTrack) {
      sleepAfterTrack = false;
      unawaited(player.pause());
      unawaited(player.seek(Duration.zero));
    }
    _save();
    notifyListeners();
  }

  void _onCompleted(bool done) {
    if (!done || !_loaded) return;
    final q = queue;
    if (q.repeat == QueueRepeat.off && q.index >= q.items.length - 1) {
      // Ende der Warteschlange: zurück an den Anfang, angehalten
      q.index = 0;
      q.positionMs = 0;
      _loaded = false;
      playing = false;
      _save();
      notifyListeners();
    }
  }

  Future<void> _applyRepeat() => player.setPlaylistMode(switch (queue.repeat) {
    QueueRepeat.off => PlaylistMode.none,
    QueueRepeat.all => PlaylistMode.loop,
    QueueRepeat.one => PlaylistMode.single,
  });

  void _countPlay(String? rel) {
    if (rel == null) return;
    final s = stats.putIfAbsent(rel, PlayStat.new);
    s.plays++;
    s.lastPlayedMs = DateTime.now().millisecondsSinceEpoch;
  }

  void _save({Duration delay = const Duration(seconds: 1)}) =>
      _store.scheduleSave(_snapshot, delay: delay);

  Map<String, Object?> _snapshot() => {
    'version': 1,
    'current': _current,
    'queues': [for (final q in queues) q.toJson()],
    'stats': {for (final e in stats.entries) e.key: e.value.toJson()},
  };

  Future<void> saveNow() {
    _store.scheduleSave(_snapshot);
    return _store.saveNow();
  }

  // ─── Wiedergabe ────────────────────────────────────────────────────────

  /// Spielt [paths] in der aktuellen Warteschlange ab [start] (ersetzt ihren Inhalt).
  Future<void> playTracks(List<String> paths, {int start = 0}) async {
    if (paths.isEmpty) return;
    queue.replace(paths, start: start);
    await _openQueue(play: true);
    _save();
  }

  Future<void> playPause() async {
    if (queue.isEmpty) return;
    if (!_loaded) {
      await _openQueue(play: true);
    } else {
      await player.playOrPause();
    }
  }

  Future<void> next() async {
    if (!_loaded) return;
    final n = queue.nextIndex(manual: true);
    if (n == null) return;
    if (n == 0 && queue.index == queue.items.length - 1) {
      await player.jump(0);
    } else {
      await player.next();
    }
  }

  /// Wie bei Musicolet: nach 3 s zurück an den Anfang, sonst vorheriger Titel.
  Future<void> previous() async {
    if (!_loaded) return;
    if (position > const Duration(seconds: 3) || queue.items.length == 1) {
      await player.seek(Duration.zero);
      return;
    }
    final p = queue.previousIndex();
    if (p == queue.index) {
      await player.seek(Duration.zero);
    } else {
      await player.jump(p);
    }
  }

  Future<void> seek(Duration d) async {
    if (!_loaded) {
      queue.positionMs = d.inMilliseconds;
      position = d;
      notifyListeners();
      return;
    }
    await player.seek(d);
  }

  Future<void> seekRelative(Duration delta) async {
    final target = position + delta;
    await seek(target < Duration.zero ? Duration.zero : target);
  }

  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= queue.items.length) return;
    if (!_loaded) {
      queue.index = index;
      queue.positionMs = 0;
      await _openQueue(play: true);
      return;
    }
    await player.jump(index);
    await player.play();
  }

  Future<void> setRepeat(QueueRepeat m) async {
    queue.repeat = m;
    await _applyRepeat();
    _save();
    notifyListeners();
  }

  Future<void> cycleRepeat() => setRepeat(
    QueueRepeat.values[(queue.repeat.index + 1) % QueueRepeat.values.length],
  );

  // ─── Warteschlange bearbeiten ──────────────────────────────────────────

  /// Fügt Titel direkt nach dem aktuellen ein (ohne Unterbrechung).
  Future<void> playNext(List<String> paths) async {
    if (paths.isEmpty) return;
    if (queue.isEmpty) {
      queue.replace(paths);
      await _openQueue(play: false);
      _save();
      return;
    }
    final at = queue.index + 1;
    final oldLen = queue.items.length;
    queue.playNext(paths);
    if (_loaded) {
      for (final p in paths) {
        await player.add(_media(p));
      }
      for (var j = 0; j < paths.length; j++) {
        if (oldLen + j != at + j) await player.move(oldLen + j, at + j);
      }
    }
    _save();
    notifyListeners();
  }

  Future<void> append(List<String> paths) async {
    if (paths.isEmpty) return;
    final wasEmpty = queue.isEmpty;
    queue.append(paths);
    if (wasEmpty) {
      await _openQueue(play: false);
    } else if (_loaded) {
      for (final p in paths) {
        await player.add(_media(p));
      }
    }
    _save();
    notifyListeners();
  }

  Future<void> removeAt(int i) async {
    if (i < 0 || i >= queue.items.length) return;
    final wasCurrent = i == queue.index;
    final wasPlaying = playing;
    queue.removeAt(i);
    if (wasCurrent) {
      await _openQueue(play: wasPlaying);
    } else if (_loaded) {
      await player.remove(i);
    }
    _save();
    notifyListeners();
  }

  /// Verschiebt einen Eintrag; [to] ist der Zielindex nach dem Verschieben.
  Future<void> moveItem(int from, int to) async {
    if (from == to) return;
    queue.move(from, to);
    if (_loaded) await player.move(from, to > from ? to + 1 : to);
    _save();
    notifyListeners();
  }

  /// Mischt die Warteschlange (aktueller Titel bleibt und läuft weiter).
  Future<void> shuffleQueue() async {
    if (queue.items.length < 2) return;
    final wasPlaying = playing;
    queue.positionMs = position.inMilliseconds;
    queue.shuffle();
    if (_loaded) await _openQueue(play: wasPlaying);
    _save();
    notifyListeners();
  }

  Future<void> clearQueue() async {
    queue.replace([]);
    await _openQueue(play: false);
    _save();
    notifyListeners();
  }

  // ─── Mehrere Warteschlangen ────────────────────────────────────────────

  Future<void> switchQueue(int i) async {
    if (i == _current || i < 0 || i >= queues.length) return;
    final wasPlaying = playing;
    if (_loaded) queue.positionMs = position.inMilliseconds;
    _current = i;
    _loaded = false;
    await _openQueue(play: wasPlaying);
    _save();
    notifyListeners();
  }

  String _nextQueueName() {
    var n = queues.length + 1;
    while (queues.any((q) => q.name == 'Warteschlange $n')) {
      n++;
    }
    return 'Warteschlange $n';
  }

  /// Legt eine neue Warteschlange an und wechselt zu ihr.
  Future<void> newQueue({
    List<String> paths = const [],
    String? name,
    bool play = true,
  }) async {
    final q = PlayQueue(
      id: _newId(),
      name: name ?? _nextQueueName(),
      items: [...paths],
    );
    queues.add(q);
    if (paths.isEmpty) {
      _save();
      notifyListeners();
      return;
    }
    if (_loaded) queue.positionMs = position.inMilliseconds;
    _current = queues.length - 1;
    _loaded = false;
    await _openQueue(play: play);
    _save();
    notifyListeners();
  }

  void renameQueue(int i, String name) {
    queues[i].name = name;
    _save();
    notifyListeners();
  }

  Future<void> deleteQueue(int i) async {
    if (queues.length == 1) {
      await clearQueue();
      return;
    }
    final deletingCurrent = i == _current;
    queues.removeAt(i);
    if (i < _current || _current >= queues.length) {
      _current = max(0, _current - 1);
    }
    if (deletingCurrent) {
      _loaded = false;
      await _openQueue(play: false);
    }
    _save();
    notifyListeners();
  }

  Future<void> saveQueueAsPlaylist(String name) async {
    await library.playlists.write(name, queue.items);
    library.playlistsChanged();
  }

  /// Nach einem Scan: umbenannte Dateien in allen Warteschlangen nachziehen.
  void renamePaths(Map<String, String> renames) {
    var currentChanged = false;
    for (final q in queues) {
      final cur = q.current;
      for (final e in renames.entries) {
        q.renamePath(e.key, e.value);
      }
      if (q == queue && cur != null && renames.containsKey(cur)) {
        currentChanged = true;
      }
    }
    for (final e in renames.entries) {
      final s = stats.remove(e.key);
      if (s != null) stats[e.value] = s;
    }
    // mpv kennt noch die alten Pfade: Playlist neu laden, Position bleibt erhalten
    if (_loaded && (currentChanged || queue.items.any(renames.containsValue))) {
      queue.positionMs = position.inMilliseconds;
      unawaited(_openQueue(play: playing));
    }
    _save();
    notifyListeners();
  }

  // ─── Klang ─────────────────────────────────────────────────────────────

  double get volume => settings.volume;
  Future<void> setVolume(double v) async {
    await player.setVolume(v);
    await settings.setVolume(v);
    notifyListeners();
  }

  double get speed => settings.speed;
  Future<void> setSpeed(double v) async {
    await player.setRate(v);
    await settings.setSpeed(v);
    notifyListeners();
  }

  Future<void> setReplayGain(String mode) async {
    await settings.setReplayGain(mode);
    final native = player.platform;
    if (native is NativePlayer) await native.setProperty('replaygain', mode);
    notifyListeners();
  }

  /// Setzt den mpv-Audiofilter für den Equalizer.
  Future<void> applyEqualizer() async {
    final native = player.platform;
    if (native is! NativePlayer) return;
    final gains = settings.eqGains;
    final active = settings.eqEnabled && gains.any((g) => g != 0);
    if (!active) {
      await native.setProperty('af', '');
      return;
    }
    final parts = <String>[];
    for (var i = 0; i < eqBands.length; i++) {
      if (gains[i] == 0) continue;
      parts.add(
        'equalizer=f=${eqBands[i]}:t=o:w=1:g=${gains[i].toStringAsFixed(1)}',
      );
    }
    // Vorverstärkung absenken, damit Anhebungen nicht übersteuern
    final maxGain = gains.reduce(max);
    if (maxGain > 0) parts.add('volume=${(-maxGain).toStringAsFixed(1)}dB');
    await native.setProperty('af', 'lavfi=[${parts.join(',')}]');
    if (Platform.environment['MYNC_DEBUG'] != null) {
      debugPrint('mync: af=${await native.getProperty('af')}');
    }
  }

  Future<void> setEqualizer({bool? enabled, List<double>? gains}) async {
    if (enabled != null) await settings.setEqEnabled(enabled);
    if (gains != null) await settings.setEqGains(gains);
    await applyEqualizer();
    notifyListeners();
  }

  // ─── Sleeptimer ────────────────────────────────────────────────────────

  Timer? _sleepTimer;
  DateTime? sleepAt;
  bool sleepAfterTrack = false;

  void setSleepTimer(Duration? d) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepAt = null;
    if (d != null) {
      sleepAt = DateTime.now().add(d);
      _sleepTimer = Timer(d, _fadeOutAndPause);
    }
    notifyListeners();
  }

  void setSleepAfterTrack(bool v) {
    sleepAfterTrack = v;
    notifyListeners();
  }

  Future<void> _fadeOutAndPause() async {
    sleepAt = null;
    _sleepTimer = null;
    final start = settings.volume;
    const steps = 40;
    for (var i = 1; i <= steps; i++) {
      await player.setVolume(start * (1 - i / steps));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await player.pause();
    await player.setVolume(start);
    notifyListeners();
  }

  // ─── Statistik ─────────────────────────────────────────────────────────

  List<String> mostPlayed({int limit = 100}) {
    final list =
        stats.entries
            .where((e) => e.value.plays > 0 && library.byPath(e.key) != null)
            .toList()
          ..sort((a, b) => b.value.plays.compareTo(a.value.plays));
    return list.take(limit).map((e) => e.key).toList();
  }

  List<String> recentlyPlayed({int limit = 100}) {
    final list =
        stats.entries
            .where(
              (e) => e.value.lastPlayedMs > 0 && library.byPath(e.key) != null,
            )
            .toList()
          ..sort(
            (a, b) => b.value.lastPlayedMs.compareTo(a.value.lastPlayedMs),
          );
    return list.take(limit).map((e) => e.key).toList();
  }

  @override
  Future<void> dispose() async {
    _sleepTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await saveNow();
    await player.dispose();
    super.dispose();
  }
}

/// Playlist-Namen für das Kontextmenü (ohne Favoriten).
Future<List<String>> userPlaylists(Library lib) async =>
    (await lib.playlists.names())
        .where((n) => n != PlaylistStore.favoritesName)
        .toList();
