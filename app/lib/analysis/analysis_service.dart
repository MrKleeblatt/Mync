import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../log.dart';
import 'applause.dart';
import 'pcm.dart';
import 'waveform.dart';

/// Ergebnis der Hintergrundanalyse eines Titels.
class TrackAnalysis {
  TrackAnalysis({this.waveform, this.introApplause, this.outroApplause});

  /// Hüllkurve für die Visualisierung (null = noch nicht / nicht möglich).
  Waveform? waveform;

  /// Länge des Applauses am Anfang bzw. am Ende (null = keiner erkannt).
  Duration? introApplause;
  Duration? outroApplause;

  bool applauseDone = false;
}

/// Berechnet Wellenform und Applaus-Bereiche im Hintergrund (eigene, stumme
/// mpv-Instanz, ein Titel nach dem anderen) und speichert sie unter
/// `<cache>/analysis/`. Schlüssel: Datei-ID + Länge (bleibt beim Umbenennen
/// und Taggen gleich).
class AnalysisService extends ChangeNotifier {
  AnalysisService(String cacheDir)
    : _dir = Directory('$cacheDir/analysis'),
      _decoder = PcmDecoder('$cacheDir/analysis/tmp');

  final Directory _dir;
  final PcmDecoder _decoder;
  final _results = <String, TrackAnalysis>{};
  final _queue = <(String key, String path, int durationMs, bool priority)>[];
  bool _busy = false;

  /// Version der Ergebnisse (für Widgets, die neu zeichnen sollen).
  int version = 0;

  static const _envRate = 200;
  static const _applauseRate = 16000;
  static const _window = Duration(seconds: 60);
  static const _maxWaveform = Duration(hours: 4);

  static String keyOf(String fileId, int durationMs) =>
      '${fileId.isEmpty ? 'x' : fileId}-$durationMs';

  TrackAnalysis? get(String key) => _results[key];

  /// Analyse anfordern (sofort aus dem Cache, sonst in die Warteschlange;
  /// [priority] = vorne einreihen, z. B. für den laufenden Titel).
  Future<void> request(
    String fileId,
    int durationMs,
    String path, {
    bool priority = false,
  }) async {
    final key = keyOf(fileId, durationMs);
    if (_results.containsKey(key) || _queue.any((q) => q.$1 == key)) return;
    final cached = await _load(key);
    if (cached != null) {
      _results[key] = cached;
      version++;
      notifyListeners();
      return;
    }
    if (priority) {
      _queue.insert(0, (key, path, durationMs, true));
    } else {
      _queue.add((key, path, durationMs, false));
    }
    unawaited(_run());
  }

  Future<void> _run() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_queue.isNotEmpty) {
        final (key, path, durationMs, _) = _queue.removeAt(0);
        final r = TrackAnalysis();
        _results[key] = r;
        try {
          await _analyse(r, path, Duration(milliseconds: durationMs));
          await _save(key, r);
        } catch (e) {
          logWarning('Analyse fehlgeschlagen ($path): $e');
        }
        version++;
        notifyListeners();
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _analyse(TrackAnalysis r, String path, Duration dur) async {
    if (dur > Duration.zero && dur <= _maxWaveform) {
      // Betrag bilden und auf 200 Hz glätten = Hüllkurve
      final env = await _envelope(path);
      r.waveform = await Isolate.run(() => buildWaveform(env, rate: _envRate));
      version++;
      notifyListeners();
    }
    if (dur >= const Duration(seconds: 20)) {
      final head = await _decoder.decode(
        path,
        rate: _applauseRate,
        end: dur < _window ? null : _window,
      );
      final tailStart = dur - _window;
      final tail = tailStart <= Duration.zero
          ? head
          : await _decoder.decode(path, rate: _applauseRate, start: tailStart);
      final (intro, outro) = await Isolate.run(() {
        const d = ApplauseDetector();
        return (d.detect(head), d.detect(tail, fromEnd: true));
      });
      // Applaus länger als die Hälfte des Titels ist unplausibel
      r.introApplause = intro != null && intro * 2 < dur ? intro : null;
      r.outroApplause = outro != null && outro * 2 < dur ? outro : null;
    }
    r.applauseDone = true;
  }

  /// mpv mit lavfi-Filter `aeval` (Betrag) – fehlt der Filter (libmpv
  /// unter Android), mit [_envRate] × 20 dekodieren und hier mitteln.
  bool _noFilter = false;
  Future<Int16List> _envelope(String path) async {
    if (!_noFilter) {
      try {
        return await _decoder.decode(
          path,
          rate: _envRate,
          filter: 'aeval=exprs=abs(val(0))',
        );
      } on StateError catch (e) {
        if (!'$e'.contains('filter')) rethrow;
        _noFilter = true;
        logInfo('Analyse: ohne Audiofilter (Hüllkurve selbst berechnet)');
      }
    }
    const factor = 20;
    final pcm = await _decoder.decode(path, rate: _envRate * factor);
    return Isolate.run(() => absEnvelope(pcm, factor));
  }

  File _file(String key, String ext) => File('${_dir.path}/$key.$ext');

  Future<TrackAnalysis?> _load(String key) async {
    try {
      final meta = _file(key, 'json');
      if (!await meta.exists()) return null;
      final j = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      if (j['v'] != 2) return null;
      final wave = _file(key, 'wave');
      Duration? ms(Object? v) =>
          v == null ? null : Duration(milliseconds: v as int);
      return TrackAnalysis(
        waveform: await wave.exists()
            ? Waveform.fromBytes(await wave.readAsBytes())
            : null,
        introApplause: ms(j['intro_ms']),
        outroApplause: ms(j['outro_ms']),
      )..applauseDone = true;
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(String key, TrackAnalysis r) async {
    await _dir.create(recursive: true);
    final w = r.waveform;
    if (w != null) await _file(key, 'wave').writeAsBytes(w.toBytes());
    await _file(key, 'json').writeAsString(
      jsonEncode({
        'v': 2,
        'intro_ms': r.introApplause?.inMilliseconds,
        'outro_ms': r.outroApplause?.inMilliseconds,
      }),
    );
  }

  /// Nur für Tests: Ergebnis direkt setzen.
  @visibleForTesting
  void put(String key, TrackAnalysis r) {
    _results[key] = r;
    version++;
    notifyListeners();
  }
}

/// Mittelt den Betrag von je [factor] Werten (Hüllkurve wie `aeval=abs` mit
/// anschließendem Herunterrechnen).
Int16List absEnvelope(Int16List pcm, int factor) {
  final out = Int16List(pcm.length ~/ factor);
  for (var i = 0; i < out.length; i++) {
    var sum = 0;
    for (var k = i * factor; k < (i + 1) * factor; k++) {
      final v = pcm[k];
      sum += v < 0 ? -v : v;
    }
    out[i] = (sum ~/ factor).clamp(0, 32767);
  }
  return out;
}
