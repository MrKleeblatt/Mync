import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;

import '../analysis/analysis_service.dart';
import '../log.dart';
import '../library/chapters.dart';
import '../library/library.dart';
import '../library/track.dart';
import '../settings.dart';
import '../stats/history.dart';
import '../stats/stats.dart';
import 'queue.dart';
import 'state_store.dart';

/// Zähler aus Versionen vor dem Hörprotokoll (werden nur noch gelesen).
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
    : _store = StateStore(settings.stateFile),
      history = ListeningHistory(File('${settings.dataDir}/history.jsonl')),
      analysis = AnalysisService(settings.cacheDir);

  /// Wellenform und Applaus-Erkennung (im Hintergrund).
  final AnalysisService analysis;

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

  /// Alte Zähler (vor dem Hörprotokoll).
  final Map<String, PlayStat> stats = {};

  /// Gemerkte Positionen langer Dateien (Hörbücher): Pfad → ms.
  final Map<String, int> resume = {};

  /// Startposition, mit der ein Titel an mpv übergeben wurde.
  final Map<String, int> _startUsed = {};

  /// Tonhöhe ließ sich nicht einstellen (mpv/ffmpeg ohne rubberband).
  bool pitchUnavailable = false;

  /// Hörprotokoll: Grundlage für Statistik und Vorschläge.
  final ListeningHistory history;

  /// Wird bei jedem neuen Eintrag im Hörprotokoll erhöht.
  int historyVersion = 0;

  ListeningSession? _session;

  /// Der nächste Titelwechsel wurde vom Nutzer ausgelöst (→ ggf. „übersprungen“).
  bool _userSkip = false;

  /// Kapitel des aktuellen Titels (aus Tags oder Beschreibungstext).
  ChapterList chapters = ChapterList.empty;
  String? _chaptersFor;

  /// Index des aktuellen Kapitels (-1 = keins).
  int get chapterIndex => chapters.indexAt(position);
  Chapter? get currentChapter {
    final i = chapterIndex;
    return i < 0 ? null : chapters.chapters[i];
  }

  /// Lädt die Kapitel, wenn sich der aktuelle Titel geändert hat.
  void _syncChapters({bool force = false}) {
    _requestAnalysis();
    final path = queue.current;
    if (!force && path == _chaptersFor) return;
    _chaptersFor = path;
    chapters = ChapterList.empty;
    final t = path == null ? null : library.byPath(path);
    if (t == null) return;
    loadChapters(t, library.abs(t.path)).then((c) {
      if (_chaptersFor != path) return; // inzwischen anderer Titel
      chapters = c;
      notifyListeners();
    });
  }

  /// Springt zum Kapitel [i].
  Future<void> jumpToChapter(int i) async {
    if (i < 0 || i >= chapters.length) return;
    await seek(chapters.chapters[i].start);
    if (!playing) await playPause();
  }

  /// Nächstes Kapitel; am Ende: nächster Titel.
  Future<void> nextChapter() async {
    final i = chapterIndex;
    if (i + 1 < chapters.length) return jumpToChapter(i + 1);
    await next();
  }

  /// Zum Anfang des Kapitels – oder, in den ersten 3 s, zum vorherigen
  /// (vor dem ersten Kapitel: vorheriger Titel).
  Future<void> previousChapter() async {
    final i = chapterIndex;
    if (i < 0) return previous();
    final into = position - chapters.chapters[i].start;
    if (into > const Duration(seconds: 3)) return jumpToChapter(i);
    if (i > 0) return jumpToChapter(i - 1);
    return previous();
  }

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
    await applyAudioFilters();

    final state = await _store.load();
    for (final e in ((state['resume'] as Map?) ?? const {}).entries) {
      resume[e.key as String] = (e.value as num).toInt();
    }
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

    await history.load();

    _subs.addAll([
      player.stream.playing.listen((v) {
        playing = v;
        _session?.resetAnchor();
        _trackSession();
        notifyListeners();
      }),
      player.stream.position.listen((p) {
        position = p;
        _trackSession();
        if (_loaded && !_opening) {
          queue.positionMs = p.inMilliseconds;
          final cur = queue.current;
          if (cur != null &&
              !_switching &&
              DateTime.now().difference(_switchedAt) >
                  const Duration(milliseconds: 1500) &&
              isLong(cur)) {
            resume[cur] = p.inMilliseconds;
          }
          _save(delay: const Duration(seconds: 5));
          _checkCrossfade();
          _checkApplause();
        }
      }),
      player.stream.duration.listen((d) {
        duration = d;
        final s = _session;
        if (s != null && d > Duration.zero && s.path == queue.current) {
          s.durationMs = d.inMilliseconds;
        }
        notifyListeners();
      }),
      player.stream.playlist.listen(_onPlaylist),
      player.stream.completed.listen(_onCompleted),
      player.stream.error.listen((e) {
        logError('Wiedergabe (mpv): $e');
        error = e;
        notifyListeners();
      }),
    ]);

    library.onRenamed = renamePaths;
    analysis.addListener(notifyListeners);
    // Nach Scans/Tag-Änderungen: Kapitel des aktuellen Titels neu laden
    library.addListener(() {
      if (!library.scanning) _syncChapters(force: true);
    });
    await _openQueue(play: false);
    notifyListeners();
  }

  static String _newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
      Random().nextInt(1 << 20).toRadixString(36);

  Media _media(String rel) {
    final start = isLong(rel) ? (resume[rel] ?? 0) : 0;
    _startUsed[rel] = start;
    if (start > 0) _debug('Start bei $start ms: $rel');
    return Media(
      Uri.file(library.abs(rel)).toString(),
      start: start > 0 ? Duration(milliseconds: start) : null,
    );
  }

  static void _debug(String m) {
    logInfo(m);
    if (Platform.environment['MYNC_DEBUG'] != null) debugPrint('mync: $m');
  }

  /// Lange Datei (Hörbuch, Podcast …): Position wird je Datei gemerkt.
  bool isLong(String rel) {
    final min = settings.resumeMinutes;
    if (min <= 0) return false;
    var ms = library.byPath(rel)?.info.durationMs ?? -1;
    if (ms <= 0 && rel == queue.current) ms = duration.inMilliseconds;
    return ms >= min * 60000;
  }

  /// Gemerkte Position einer langen Datei (null = keine).
  Duration? resumePosition(String rel) {
    final ms = resume[rel];
    return ms == null || ms < 5000 ? null : Duration(milliseconds: ms);
  }

  /// Gemerkte Position verwerfen, wenn die Datei (fast) zu Ende gehört ist.
  void _forgetIfFinished(String rel) {
    final ms = resume[rel];
    if (ms == null) return;
    final total = library.byPath(rel)?.info.durationMs ?? 0;
    if (total > 0 && ms >= total - 30000) resume.remove(rel);
  }

  /// Während eines Titelwechsels keine Positionen speichern.
  bool _switching = false;
  DateTime _switchedAt = DateTime(0);

  // ─── mpv-Synchronisation ───────────────────────────────────────────────

  Future<void> _openQueue({required bool play}) async {
    final q = queue;
    if (q.isEmpty) {
      _loaded = false;
      await player.stop();
      position = Duration.zero;
      duration = Duration.zero;
      _syncChapters();
      notifyListeners();
      return;
    }
    _cancelCrossfade();
    final cur = q.current;
    if (q.positionMs == 0 && cur != null && isLong(cur)) {
      q.positionMs = resume[cur] ?? 0;
    }
    _switchedAt = DateTime.now();
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
        await player.play();
      }
    } finally {
      _opening = false;
    }
    _syncChapters();
    notifyListeners();
  }

  void _onPlaylist(Playlist pl) {
    if (!_loaded || _opening) return;
    final q = queue;
    if (pl.index == q.index || pl.index < 0 || pl.index >= q.items.length) {
      return;
    }
    _switchedAt = DateTime.now();
    final old = q.current;
    if (old != null) _forgetIfFinished(old);
    q.index = pl.index;
    q.positionMs = 0;
    _syncChapters();
    final cur = q.current!;
    if (_fading) {
      unawaited(_finishCrossfade());
    } else {
      // Gemerkte Position hat sich seit dem Laden der Playlist geändert?
      final want = isLong(cur) ? (resume[cur] ?? 0) : 0;
      if ((want - (_startUsed[cur] ?? 0)).abs() > 2000) {
        unawaited(_seekWhenLoaded(Duration(milliseconds: want)));
      }
    }
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
      _endSession(byUser: false, completed: true);
      final cur = q.current;
      if (cur != null) resume.remove(cur);
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

  // ─── Hörprotokoll ──────────────────────────────────────────────────────

  /// Hält die laufende Messung mit dem aktuellen Titel synchron.
  void _trackSession() {
    if (_opening) return;
    final path = _loaded ? queue.current : null;
    final cur = _session;
    if (cur != null && cur.path != path) _endSession(byUser: _userSkip);
    if (path != null && _session == null && playing) {
      final t = library.byPath(path);
      _session = ListeningSession(
        path: path,
        fileId: t?.fileId ?? '',
        durationMs: duration > Duration.zero
            ? duration.inMilliseconds
            : (t?.info.durationMs ?? 0),
      );
      _userSkip = false;
    }
    _session?.onPosition(position, playing: playing, rate: speed);
  }

  void _endSession({required bool byUser, bool completed = false}) {
    final s = _session;
    if (s == null) return;
    _session = null;
    _userSkip = false;
    if (s.listenedMs < 3000) return; // nur kurz angespielt
    final done =
        completed || (s.durationMs > 0 && s.listenedMs >= s.durationMs * 0.9);
    unawaited(
      history.append(s.finish(byUser: byUser && !done, completed: done)),
    );
    historyVersion++;
    notifyListeners();
  }

  /// Beim Beenden der App: laufende Messung abschließen.
  Future<void> endListening() async {
    if (frozen) return;
    _endSession(byUser: false);
    await saveNow();
  }

  /// Wie oft gespielt und wann zuletzt (Hörprotokoll + alte Zähler).
  (int plays, DateTime? last) playsFor(Track t) {
    final (p, last) = playsOf(history.events, t.fileId, t.path);
    final legacy = stats[t.path];
    final lastMs = [last ?? 0, legacy?.lastPlayedMs ?? 0].reduce(max);
    return (
      p + (legacy?.plays ?? 0),
      lastMs == 0 ? null : DateTime.fromMillisecondsSinceEpoch(lastMs),
    );
  }

  /// Markiert den nächsten Titelwechsel als Nutzeraktion.
  void _markUserSkip() => _userSkip = true;

  /// Nach dem Wiederherstellen eines Backups: nichts mehr speichern, damit
  /// die wiederhergestellten Dateien beim Beenden nicht überschrieben werden.
  bool frozen = false;

  void _save({Duration delay = const Duration(seconds: 1)}) {
    if (!frozen) _store.scheduleSave(_snapshot, delay: delay);
  }

  Map<String, Object?> _snapshot() => {
    'version': 1,
    'current': _current,
    'queues': [for (final q in queues) q.toJson()],
    'stats': {for (final e in stats.entries) e.key: e.value.toJson()},
    'resume': resume,
  };

  Future<void> saveNow() {
    if (frozen) return Future.value();
    _store.scheduleSave(_snapshot);
    return _store.saveNow();
  }

  // ─── Wiedergabe ────────────────────────────────────────────────────────

  /// Spielt [paths] in der aktuellen Warteschlange ab [start] (ersetzt ihren Inhalt).
  Future<void> playTracks(List<String> paths, {int start = 0}) async {
    if (paths.isEmpty) return;
    _markUserSkip();
    queue.replace(paths, start: start);
    await _openQueue(play: true);
    _save();
  }

  Future<void> playPause() async {
    _cancelCrossfade();
    if (queue.isEmpty) return;
    if (!_loaded) {
      await _openQueue(play: true);
    } else {
      await player.playOrPause();
    }
  }

  Future<void> next() async {
    if (!_loaded) return;
    _cancelCrossfade();
    _markUserSkip();
    final n = queue.nextIndex(manual: true);
    if (n == null) return;
    if (n == queue.index) {
      // nur ein Titel: mpv ignoriert den Sprung auf denselben Eintrag
      await player.seek(Duration.zero);
      return;
    }
    if (n == 0 && queue.index == queue.items.length - 1) {
      await player.jump(0);
    } else {
      await player.next();
    }
  }

  /// Wie bei Musicolet: nach 3 s zurück an den Anfang, sonst vorheriger Titel.
  Future<void> previous() async {
    if (!_loaded) return;
    _cancelCrossfade();
    if (position > const Duration(seconds: 3) || queue.items.length == 1) {
      await player.seek(Duration.zero);
      return;
    }
    final p = queue.previousIndex();
    _markUserSkip();
    if (p == queue.index) {
      await player.seek(Duration.zero);
    } else {
      await player.jump(p);
    }
  }

  Future<void> seek(Duration d) async {
    _cancelCrossfade();
    if (!_loaded) {
      queue.positionMs = d.inMilliseconds;
      position = d;
      notifyListeners();
      return;
    }
    await player.seek(d);
  }

  /// Springt an [d], sobald die (gerade gewechselte) Datei geladen ist.
  Future<void> _seekWhenLoaded(Duration d) async {
    _switching = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      try {
        await player.stream.duration
            .firstWhere((x) => x > Duration.zero)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
      await player.seek(d);
    } finally {
      _switching = false;
    }
  }

  /// Spult um die eingestellte Schrittweite (× [times], negativ = zurück).
  Future<void> skipBy(int times) =>
      seekRelative(Duration(seconds: settings.seekStep * times));

  Future<void> seekRelative(Duration delta) async {
    final target = position + delta;
    await seek(target < Duration.zero ? Duration.zero : target);
  }

  Future<void> jumpTo(int index) async {
    _cancelCrossfade();
    if (index < 0 || index >= queue.items.length) return;
    _markUserSkip();
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
    if (wasCurrent) _markUserSkip();
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
    _markUserSkip();
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
    _markUserSkip();
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
    history.renamePaths(renames);
    for (final e in renames.entries) {
      final s = stats.remove(e.key);
      if (s != null) stats[e.value] = s;
      final r = resume.remove(e.key);
      if (r != null) resume[e.value] = r;
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

  /// mpv-Audiofilter: Tonhöhe, Balance.
  String _filterChain({bool withPitch = true}) {
    final parts = <String>[];
    if (withPitch && settings.pitch != 0) {
      final scale = pow(2, settings.pitch / 12).toStringAsFixed(5);
      parts.add('rubberband=pitch=$scale:pitchq=quality');
    }
    final b = settings.balance;
    if (b != 0) parts.add('stereotools=balance_out=${b.toStringAsFixed(2)}');
    return parts.isEmpty ? '' : 'lavfi=[${parts.join(',')}]';
  }

  Future<void> _applyFiltersTo(Player p) async {
    final native = p.platform;
    if (native is! NativePlayer) return;
    var chain = _filterChain();
    await native.setProperty('af', chain);
    final wantPitch = settings.pitch != 0;
    if (wantPitch && !(await native.getProperty('af')).contains('rubberband')) {
      // mpv hat die Kette abgelehnt: ohne Tonhöhe erneut versuchen
      chain = _filterChain(withPitch: false);
      await native.setProperty('af', chain);
      pitchUnavailable = true;
    } else if (wantPitch) {
      pitchUnavailable = false;
    }
    if (Platform.environment['MYNC_DEBUG'] != null) {
      debugPrint('mync: af=${await native.getProperty('af')}');
    }
  }

  Future<void> applyAudioFilters() async {
    await _applyFiltersTo(player);
    final aux = _aux;
    if (aux != null) await _applyFiltersTo(aux);
  }

  double get pitch => settings.pitch;
  Future<void> setPitch(double semitones) async {
    await settings.setPitch(semitones);
    await applyAudioFilters();
    notifyListeners();
  }

  double get balance => settings.balance;
  Future<void> setBalance(double v) async {
    await settings.setBalance(v);
    await applyAudioFilters();
    notifyListeners();
  }

  // ─── Analyse: Wellenform und Applaus ──────────────────────────────────

  /// Analyse des laufenden und des nächsten Titels anstoßen.
  void _requestAnalysis() {
    if (queue.isEmpty) return;
    final q = queue;
    for (final (i, prio) in [(q.index, true), (q.nextIndex(), false)]) {
      if (i == null || i < 0 || i >= q.items.length) continue;
      final t = library.byPath(q.items[i]);
      if (t == null) continue;
      unawaited(
        analysis.request(
          t.fileId,
          t.info.durationMs,
          library.abs(t.path),
          priority: prio,
        ),
      );
    }
  }

  /// Analyse des laufenden Titels (null = noch nicht fertig).
  TrackAnalysis? get currentAnalysis {
    final t = currentTrack;
    if (t == null) return null;
    return analysis.get(AnalysisService.keyOf(t.fileId, t.info.durationMs));
  }

  Duration get _length => duration > Duration.zero
      ? duration
      : (currentTrack?.duration ?? Duration.zero);

  /// Beginn des Applauses am Ende (null = keiner).
  Duration? get outroApplauseStart {
    final o = currentAnalysis?.outroApplause;
    if (o == null || _length <= Duration.zero) return null;
    return _length - o;
  }

  /// Läuft gerade erkannter Applaus, den man überspringen kann?
  bool get inApplause {
    final a = currentAnalysis;
    if (a == null || !_loaded) return false;
    final intro = a.introApplause;
    if (intro != null && position < intro - const Duration(milliseconds: 500)) {
      return true;
    }
    final out = outroApplauseStart;
    return out != null &&
        position >= out &&
        position < _length - const Duration(milliseconds: 500);
  }

  /// Applaus überspringen: am Anfang zum Musikbeginn, am Ende zum nächsten Titel.
  Future<void> skipApplause() async {
    final a = currentAnalysis;
    if (a == null) return;
    _debug(
      'Applaus überspringen bei $position (Wiederholen: ${queue.repeat.name})',
    );
    final intro = a.introApplause;
    if (intro != null && position < intro) {
      await seek(intro);
      return;
    }
    final out = outroApplauseStart;
    if (out != null && position >= out) {
      final last =
          queue.repeat == QueueRepeat.off &&
          queue.index >= queue.items.length - 1;
      if (last) {
        await seek(_length - const Duration(milliseconds: 200));
      } else {
        await next();
      }
    }
  }

  String?
  _autoSkipped; // „Pfad|intro“ bzw. „Pfad|outro“: schon einmal übersprungen
  bool _wasInApplause = false;

  void _checkApplause() {
    final now = inApplause;
    if (now != _wasInApplause) {
      _wasInApplause = now;
      notifyListeners(); // Knopf ein-/ausblenden
    }
    if (!now || !settings.autoSkipApplause || !playing) return;
    final cur = queue.current;
    final which = position < _length ~/ 2 ? 'intro' : 'outro';
    final tag = '$cur|$which';
    // nur einmal je Titel – wer zurückspult, will den Applaus hören
    if (_autoSkipped == tag) return;
    _autoSkipped = tag;
    unawaited(skipApplause());
  }

  // ─── Überblenden ───────────────────────────────────────────────────────
  //
  // Kurz vor dem Ende startet ein zweiter Player den nächsten Titel und die
  // Lautstärken werden gegenläufig geblendet. Wechselt die Haupt-Playlist
  // dann (lückenlos) zum nächsten Titel, springt sie an die Stelle des
  // zweiten Players und übernimmt.

  Player? _aux;
  bool _fading = false;
  Timer? _fadeTimer;
  int _fadeToken = 0;

  bool get crossfading => _fading;

  bool _sameAlbum(String a, String b) {
    final ta = library.byPath(a), tb = library.byPath(b);
    if (ta == null || tb == null || ta.folder != tb.folder) return false;
    return ta.album != null && ta.album == tb.album;
  }

  void _checkCrossfade() {
    final secs = settings.crossfadeSec;
    if (secs <= 0 || _fading || !playing || sleepAfterTrack) return;
    if (duration <= Duration.zero) return;
    final remaining = duration - position;
    if (remaining > Duration(seconds: secs) ||
        remaining < const Duration(milliseconds: 800)) {
      return;
    }
    final q = queue;
    if (q.repeat == QueueRepeat.one) return;
    final n = q.nextIndex();
    final cur = q.current;
    if (n == null || cur == null || n == q.index) return;
    final next = q.items[n];
    if (isLong(cur) || isLong(next)) return;
    if (settings.crossfadeSkipAlbum && _sameAlbum(cur, next)) return;
    unawaited(_startCrossfade(next, remaining));
  }

  Future<Player> _auxPlayer() async {
    final existing = _aux;
    if (existing != null) return existing;
    final p = Player(
      configuration: const PlayerConfiguration(
        title: 'mync-blende',
        logLevel: MPVLogLevel.warn,
      ),
    );
    final native = p.platform;
    if (native is NativePlayer) {
      await native.setProperty('vid', 'no');
      await native.setProperty('audio-display', 'no');
      await native.setProperty('audio-client-name', 'mync');
      await native.setProperty('replaygain', settings.replayGain);
      final ao = Platform.environment['MYNC_MPV_AO'];
      if (ao != null && ao.isNotEmpty) await native.setProperty('ao', ao);
    }
    _aux = p;
    await _applyFiltersTo(p);
    return p;
  }

  Future<void> _startCrossfade(String next, Duration remaining) async {
    _fading = true;
    final token = ++_fadeToken;
    final aux = await _auxPlayer();
    await aux.setRate(speed);
    await aux.setVolume(0);
    await aux.open(Media(Uri.file(library.abs(next)).toString()), play: true);
    if (token != _fadeToken) return;
    final started = DateTime.now();
    final total = remaining.inMilliseconds / speed;
    _debug('Überblenden: $next über ${total.round()} ms');
    _fadeTimer?.cancel();
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 50), (t) {
      final x = (DateTime.now().difference(started).inMilliseconds / total)
          .clamp(0.0, 1.0);
      final v = settings.volume;
      // gleiche Leistung: cos/sin-Kurve
      unawaited(player.setVolume(v * cos(x * pi / 2)));
      unawaited(aux.setVolume(v * sin(x * pi / 2)));
      if (x >= 1) t.cancel();
    });
    notifyListeners();
  }

  /// Die Haupt-Playlist ist beim nächsten Titel: Position übernehmen.
  Future<void> _finishCrossfade() async {
    final aux = _aux;
    final token = _fadeToken;
    _fadeTimer?.cancel();
    if (aux == null) return;
    _switching = true;
    try {
      await player.setVolume(0);
      // warten, bis die neue Datei läuft
      try {
        await player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
      if (token != _fadeToken) return;
      const lead = Duration(milliseconds: 120);
      final target = aux.state.position + lead;
      await player.seek(target);
      try {
        await player.stream.position
            .firstWhere((p) => p >= target - const Duration(milliseconds: 250))
            .timeout(const Duration(seconds: 1));
      } catch (_) {}
      if (token != _fadeToken) return;
      await player.setVolume(settings.volume);
      await aux.setVolume(0);
      await aux.stop();
      _debug('Überblenden fertig: Ziel $target, jetzt $position');
    } finally {
      _switching = false;
      if (token == _fadeToken) _fading = false;
      notifyListeners();
    }
  }

  /// Nutzeraktion während des Überblendens: abbrechen.
  void _cancelCrossfade() {
    if (!_fading) return;
    _fadeToken++;
    _fading = false;
    _switching = false;
    _fadeTimer?.cancel();
    final aux = _aux;
    if (aux != null) unawaited(aux.stop());
    unawaited(player.setVolume(settings.volume));
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

  @override
  Future<void> dispose() async {
    _sleepTimer?.cancel();
    _cancelCrossfade();
    await _aux?.dispose();
    for (final s in _subs) {
      await s.cancel();
    }
    await saveNow();
    await player.dispose();
    super.dispose();
  }
}
