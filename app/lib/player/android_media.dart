import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'player_controller.dart';

/// Android-Mediensitzung: Ohne sie erscheint mync weder in der
/// Medienausgabe noch in der Benachrichtigung, auf dem Sperrbildschirm oder
/// bei Kopfhörer-/Bluetooth-Tasten (media_kit spielt nur ab). Unter Linux
/// übernimmt das MPRIS (mpris.dart).
class AndroidMedia extends BaseAudioHandler with SeekHandler {
  AndroidMedia._(this.player);

  final PlayerController player;
  String? _itemFor;
  bool _lastPlaying = false;
  Duration _lastPos = Duration.zero;
  DateTime _lastAt = DateTime(0);
  StreamSubscription<Duration>? _posSub;

  static Future<AndroidMedia?> start(PlayerController player) async {
    try {
      final h = await AudioService.init(
        builder: () => AndroidMedia._(player),
        config: const AudioServiceConfig(
          androidNotificationChannelId:
              'com.github.mrkleeblatt.mync.wiedergabe',
          androidNotificationChannelName: 'Wiedergabe',
          androidNotificationIcon: 'drawable/ic_stat_mync',
          // im Vordergrund bleiben, damit Fortsetzen aus der Benachrichtigung
          // auch nach langer Pause klappt (Android 12+)
          androidStopForegroundOnPause: false,
          fastForwardInterval: Duration(seconds: 10),
          rewindInterval: Duration(seconds: 10),
        ),
      );
      h._attach();
      return h;
    } catch (e) {
      debugPrint('mync: Mediensitzung nicht verfügbar: $e');
      return null;
    }
  }

  void _attach() {
    player.addListener(_sync);
    // Sprünge (Spulen, Kapitel) erkennen und weitergeben; den normalen
    // Fortschritt rechnet Android selbst aus Position + Zeit hoch.
    _posSub = player.player.stream.position.listen((p) {
      final expected =
          _lastPos +
          (player.playing
              ? DateTime.now().difference(_lastAt) * player.speed
              : Duration.zero);
      if ((p - expected).abs() > const Duration(seconds: 2)) _publishState();
    });
    _sync();
  }

  Future<void> _sync() async {
    final t = player.currentTrack;
    if (t?.path != _itemFor) {
      _itemFor = t?.path;
      if (t == null) {
        mediaItem.add(null);
      } else {
        final cover = await player.library.coverFor(t);
        if (_itemFor != t.path) return; // inzwischen gewechselt
        mediaItem.add(
          MediaItem(
            id: t.path,
            title: t.title,
            artist: t.artist,
            album: t.album,
            duration: t.duration > Duration.zero ? t.duration : null,
            artUri: cover == null ? null : Uri.file(cover),
          ),
        );
      }
      _publishState();
    } else if (player.playing != _lastPlaying) {
      _publishState();
    }
  }

  void _publishState() {
    _lastPlaying = player.playing;
    _lastPos = player.position;
    _lastAt = DateTime.now();
    final empty = player.queue.isEmpty;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.rewind,
          player.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.fastForward,
          MediaControl.skipToNext,
        ],
        // kompakte Ansicht: zurück, Abspielen/Pause, weiter
        androidCompactActionIndices: const [0, 2, 4],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        processingState: empty
            ? AudioProcessingState.idle
            : AudioProcessingState.ready,
        playing: player.playing,
        updatePosition: player.position,
        speed: player.speed,
      ),
    );
  }

  // ─── Befehle von Android ──────────────────────────────────────────────

  @override
  Future<void> play() async {
    if (!player.playing) await player.playPause();
  }

  @override
  Future<void> pause() async {
    if (player.playing) await player.playPause();
  }

  @override
  Future<void> stop() => pause();

  @override
  Future<void> skipToNext() => player.next();

  @override
  Future<void> skipToPrevious() => player.previous();

  @override
  Future<void> seek(Duration position) async {
    await player.seek(position);
    _lastPos = position;
    _lastAt = DateTime.now();
    _publishState();
  }

  @override
  Future<void> fastForward() => player.skipBy(1);

  @override
  Future<void> rewind() => player.skipBy(-1);

  @override
  Future<void> onTaskRemoved() async {
    // App aus der Übersicht gewischt: angehalten lassen, Sitzung beenden
    if (!player.playing) await super.stop();
  }

  void dispose() {
    player.removeListener(_sync);
    unawaited(_posSub?.cancel());
  }
}
