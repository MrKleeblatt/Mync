import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';

import '../library/track.dart';
import '../log.dart';
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

  /// Kanal „mync/media“ (MediaHelper.kt): Audiofokus und Toasts.
  static const _media = MethodChannel('mync/media');

  /// Wegen eines Anrufs o. Ä. angehalten: danach von selbst weiter.
  bool _pausedByFocus = false;

  static Future<AndroidMedia?> start(PlayerController player) async {
    logInfo('Mediensitzung: starte …');
    // AudioService.init wartet auf die Verbindung zum Wiedergabedienst und
    // kann dabei hängen, ohne Fehler – dann wenigstens im Logbuch sichtbar
    final slow = Timer(
      const Duration(seconds: 10),
      () => logWarning('Mediensitzung: Dienst antwortet nach 10 s nicht'),
    );
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
      slow.cancel();
      h._attach();
      logInfo('Mediensitzung bereit');
      return h;
    } catch (e, st) {
      slow.cancel();
      logError('Mediensitzung nicht verfügbar', e, st);
      return null;
    }
  }

  void _attach() {
    _media.setMethodCallHandler(_onMedia);
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
        mediaItem.add(_item(t, cover));
      }
      _publishState();
    } else if (player.playing != _lastPlaying) {
      _publishState();
    }
  }

  MediaItem _item(Track t, String? cover) => MediaItem(
    id: t.path,
    title: t.title,
    artist: t.artist,
    album: t.album,
    duration: t.duration > Duration.zero ? t.duration : null,
    artUri: cover == null ? null : Uri.file(cover),
  );

  void _publishState() {
    if (player.playing != _lastPlaying) {
      logInfo('Mediensitzung: ${player.playing ? 'spielt' : 'pausiert'}');
      if (player.playing) {
        _pausedByFocus = false;
        unawaited(_requestFocus());
      }
    }
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

  // ─── Audiofokus (wie Musicolet) ───────────────────────────────────────

  /// Beim Abspielen den Audiofokus holen: Erst dann gilt mync für Android
  /// als die spielende Medien-App, und andere Apps verstummen.
  Future<void> _requestFocus() async {
    try {
      final ok = await _media.invokeMethod<bool>('requestFocus');
      if (ok != true) logWarning('Audiofokus nicht erhalten');
    } catch (e, st) {
      logError('Audiofokus anfordern fehlgeschlagen', e, st);
    }
  }

  Future<dynamic> _onMedia(MethodCall call) async {
    if (call.method != 'focus') return;
    final what = call.arguments as String;
    logInfo('Audiofokus: $what');
    switch (what) {
      case 'loss': // andere App spielt jetzt: anhalten
        if (player.playing) await player.playPause();
      case 'lossTransient': // z. B. Anruf: anhalten, danach weiter
        if (player.playing) {
          await player.playPause();
          _pausedByFocus = true;
        }
      case 'gain':
        if (_pausedByFocus && !player.playing) {
          _pausedByFocus = false;
          await player.playPause();
        }
      // 'duck': Android senkt die Lautstärke selbst ab
    }
  }

  // ─── Medienbrowser (Karte „Wiedergabe fortsetzen“) ────────────────────
  //
  // Android fragt nach dem Neustart des Geräts oder der App über den
  // Medienbrowser nach dem zuletzt gespielten Titel (Wurzel „recent“). Eine
  // leere Antwort zeigt die Karte als Fehler („In mync ist ein Fehler
  // aufgetreten“) – deshalb hier den aktuellen Titel der Warteschlange.

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    logInfo('Medienbrowser: Inhalt von „$parentMediaId“ angefragt');
    final t = player.currentTrack;
    if (t == null) return const [];
    // ohne Cover: andere Apps (Systemoberfläche) dürfen die Datei im
    // privaten Speicher von mync nicht lesen
    return [_item(t, null)];
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    final t = player.library.byPath(mediaId);
    return t == null ? null : _item(t, null);
  }

  // ─── Befehle von Android ──────────────────────────────────────────────

  Future<void> _run(String what, Future<void> Function() body) async {
    logInfo('Mediensteuerung: $what');
    try {
      await body();
    } catch (e, st) {
      logError('Mediensteuerung „$what“ fehlgeschlagen', e, st);
      rethrow;
    } finally {
      _publishState();
    }
  }

  @override
  Future<void> prepare() => _run('vorbereiten', () async {});

  @override
  Future<void> play() => _run('abspielen', () async {
    if (!player.playing) await player.playPause();
  });

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) => _run('abspielen: $mediaId', () async {
    final i = player.queue.items.indexOf(mediaId);
    if (i >= 0 && i != player.queue.index) {
      await player.jumpTo(i);
    } else if (i < 0 && player.library.byPath(mediaId) != null) {
      await player.playTracks([mediaId]);
      return;
    }
    if (!player.playing) await player.playPause();
  });

  @override
  Future<void> pause() => _run('pausieren', () async {
    if (player.playing) await player.playPause();
  });

  @override
  Future<void> stop() => pause();

  @override
  Future<void> skipToNext() => _run('nächster Titel', player.next);

  @override
  Future<void> skipToPrevious() => _run('voriger Titel', player.previous);

  @override
  Future<void> seek(Duration position) => _run('springen', () async {
    await player.seek(position);
    _lastPos = position;
    _lastAt = DateTime.now();
  });

  @override
  Future<void> fastForward() => _run('vorspulen', () => player.skipBy(1));

  @override
  Future<void> rewind() => _run('zurückspulen', () => player.skipBy(-1));

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

/// Medienlautstärke des Systems (Lautstärketasten des Handys, Kanal
/// „mync/volume“, SystemVolume.kt): bei 0 pausieren, beim Aufdrehen weiter.
void listenSystemVolume(PlayerController player) {
  const MethodChannel('mync/volume').setMethodCallHandler((call) async {
    if (call.method == 'musicVolume') {
      final wasPlaying = player.playing;
      await player.onSystemVolume((call.arguments as num).toInt());
      // wie Musicolet: kurz sagen, warum die Musik aufhört
      if (wasPlaying && !player.playing) {
        unawaited(_toast('Pause, weil der Ton stummgeschaltet ist'));
      }
    }
  });
}

/// Kurzer Hinweis als Toast (erscheint auch, wenn mync im Hintergrund ist).
Future<void> _toast(String text) async {
  try {
    await const MethodChannel('mync/media').invokeMethod('toast', text);
  } catch (e, st) {
    logError('Hinweis „$text“ nicht gezeigt', e, st);
  }
}
