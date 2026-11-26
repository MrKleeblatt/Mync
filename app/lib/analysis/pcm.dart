import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';

import '../core/music_fs.dart';

/// Dekodiert Audio unabhängig von der Wiedergabe: eine eigene, stumme
/// mpv-Instanz schreibt die Samples mit `ao=pcm` so schnell wie möglich
/// (`untimed`) in eine Datei. Ausgabe: Mono, 16 Bit, [rate] Hz.
class PcmDecoder {
  PcmDecoder(this.tmpDir);
  final String tmpDir;
  int _n = 0;

  /// [filter]: zusätzlicher lavfi-Filter vor der Ausgabe (z. B. Hüllkurve).
  Future<Int16List> decode(
    String path, {
    required int rate,
    Duration? start,
    Duration? end,
    String? filter,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    await Directory(tmpDir).create(recursive: true);
    final out = File('$tmpDir/pcm-$pid-${_n++}.raw');
    final p = Player(
      configuration: const PlayerConfiguration(
        title: 'mync-analyse',
        logLevel: MPVLogLevel.error,
      ),
    );
    try {
      final native = p.platform as NativePlayer;
      for (final (k, v) in [
        ('vid', 'no'),
        ('volume', '0'), // bis feststeht, dass in die Datei geschrieben wird
        ('audio-display', 'no'),
        ('replaygain', 'no'),
        ('ao', 'pcm'),
        ('ao-pcm-file', out.path),
        ('ao-pcm-waveheader', 'no'),
        ('untimed', 'yes'),
        ('audio-format', 's16'),
        ('audio-channels', 'mono'),
        ('audio-samplerate', '$rate'),
        ('af', filter == null ? '' : 'lavfi=[$filter]'),
      ]) {
        await native.setProperty(k, v);
      }
      await p.open(
        Media(MusicFs.mediaUri(path), start: start, end: end),
        play: false,
      );
      // Ohne Dateiausgabe (libmpv unter Android) würde mpv den Titel hörbar
      // abspielen – zusätzlich zur eigentlichen Wiedergabe. Daher erst
      // prüfen, welche Ausgabe mpv tatsächlich gewählt hat.
      var ao = '';
      for (var i = 0; i < 40 && ao.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        ao = await native.getProperty('current-ao');
      }
      if (ao != 'pcm') {
        throw UnsupportedError(
          'mpv ohne Dateiausgabe (ao=${ao.isEmpty ? '?' : ao})',
        );
      }
      // erst jetzt auf Ende/Fehler warten: Endet der Strom vorher (Player
      // geschlossen), gäbe es sonst einen nicht abgefangenen Fehler
      final done = p.stream.completed.firstWhere((c) => c);
      final failed = p.stream.error.first;
      done.ignore();
      failed.ignore();
      await native.setProperty('volume', '100');
      await p.play();
      await Future.any([done, failed.then((e) => throw StateError(e))])
          .timeout(timeout);
    } finally {
      await p.dispose();
    }
    try {
      final bytes = await out.readAsBytes();
      return bytes.buffer.asInt16List(0, bytes.length ~/ 2);
    } finally {
      try {
        await out.delete();
      } catch (_) {}
    }
  }
}
