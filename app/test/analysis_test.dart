import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/analysis/analysis_service.dart';
import 'package:mync/analysis/applause.dart';
import 'package:mync/analysis/waveform.dart';

const rate = 16000;
final rnd = Random(7);

/// Applaus: viele kurze, abklingende Rauschimpulse (≈ 40 Klatscher/s).
List<double> applause(double secs, {double gain = 0.3}) {
  final n = (secs * rate).round();
  final out = List<double>.filled(n, 0);
  final claps = (secs * 40).round();
  for (var c = 0; c < claps; c++) {
    final at = rnd.nextInt(n);
    final amp = gain * (0.3 + rnd.nextDouble());
    // gefärbt wie echtes Klatschen: Resonanz (Zweipol-Filter) bei
    // 0,8–3 kHz mit zufälliger Güte
    final fc = 800 + rnd.nextDouble() * 2200;
    final r = 0.6 + rnd.nextDouble() * 0.3;
    final c1 = 2 * r * cos(2 * pi * fc / rate), c2 = -r * r;
    var y1 = 0.0, y2 = 0.0;
    for (var i = 0; i < 400 && at + i < n; i++) {
      final x = (rnd.nextDouble() * 2 - 1) * exp(-i / 60);
      final y = x + c1 * y1 + c2 * y2;
      y2 = y1;
      y1 = y;
      out[at + i] += amp * 0.4 * y;
    }
  }
  return out;
}

/// Musik: Töne mit Obertönen, alle 0,5 s ein neuer Ton, leichtes Vibrato
/// (Phase wird aufsummiert, damit die Frequenz wirklich nur leicht schwankt).
List<double> music(double secs, {bool rock = false}) {
  final n = (secs * rate).round();
  final notes = [220.0, 247.0, 262.0, 294.0, 330.0, 349.0, 392.0];
  var phase = 0.0;
  return List<double>.generate(n, (i) {
    final t = i / rate;
    final f =
        notes[(t * 2).floor() % notes.length] *
        (1 + 0.003 * sin(2 * pi * 5 * t));
    phase += f / rate;
    var v = 0.0;
    if (rock) {
      // Sägezahn-Akkord (Grundton, Quinte, Oktave), übersteuert, leise Hi-Hat
      for (final m in [1.0, 1.5, 2.0]) {
        v += ((phase * m) % 1) * 2 - 1;
      }
      v = 0.5 * (2 / pi) * atan(3 * v);
      if ((t * 8) % 1 < 0.02) v += 0.05 * (rnd.nextDouble() * 2 - 1);
    } else {
      for (var h = 1; h <= 6; h++) {
        v += sin(2 * pi * phase * h) / h;
      }
      v *= 0.25;
    }
    return v;
  });
}

Int16List pcm(List<double> s) => Int16List.fromList([
  for (final x in s) (x.clamp(-1.0, 1.0) * 32767).round(),
]);

void main() {
  const d = ApplauseDetector();

  test('Applaus vor der Musik', () {
    final r = d.detect(pcm([...applause(6), ...music(30)]));
    expect(r, isNotNull);
    expect(r!.inMilliseconds, inInclusiveRange(5000, 7000));
    expect(
      d.detect(pcm([...applause(6), ...music(30)]), fromEnd: true),
      isNull,
    );
  });

  test('Applaus nach der Musik, auch nach Stille', () {
    final s = [...music(30), ...applause(8), ...List.filled(rate, 0.0)];
    final r = d.detect(pcm(s), fromEnd: true);
    expect(r, isNotNull);
    expect(
      r!.inMilliseconds,
      inInclusiveRange(8000, 10000),
    ); // inkl. 1 s Stille
    final lead = d.detect(
      pcm([...List.filled(rate, 0.0), ...applause(4), ...music(20)]),
    );
    expect(lead!.inMilliseconds, inInclusiveRange(4500, 5800));
  });

  test('Vereinzeltes Klatschen mit stillen Pausen dazwischen', () {
    final sparse = <double>[];
    for (var i = 0; i < 12; i++) {
      sparse
        ..addAll(applause(0.25, gain: 0.4))
        ..addAll(List.filled(rate ~/ 4, 0.0));
    }
    final r = d.detect(pcm([...sparse, ...music(20)]));
    expect(r, isNotNull);
    expect(r!.inMilliseconds, inInclusiveRange(5000, 6500));
  });

  test('Keine Fehlalarme: Musik, verzerrte Gitarren, Rauschen, Stille, kurzes Klatschen', () {
    expect(d.detect(pcm(music(30))), isNull);
    expect(d.detect(pcm(music(30)), fromEnd: true), isNull);
    expect(d.detect(pcm(music(30, rock: true))), isNull);
    expect(d.detect(pcm(music(30, rock: true)), fromEnd: true), isNull);
    // nur Rauschen (Regen, Hörbuch-Rauschen): kein Übergang zu Musik
    final noise = [
      for (var i = 0; i < rate * 20; i++) 0.1 * (rnd.nextDouble() * 2 - 1),
    ];
    expect(d.detect(pcm(noise)), isNull);
    expect(d.detect(pcm(List.filled(rate * 10, 0.0))), isNull);
    expect(d.detect(pcm([...applause(1), ...music(20)])), isNull); // < 2 s
  });

  test('Wellenform: Balken und Pegelverlauf', () {
    // 10 s Hüllkurve bei 200 Hz: leise, dann laut
    final env = Int16List.fromList([
      for (var i = 0; i < 2000; i++) i < 1000 ? 1000 : 10000,
    ]);
    final w = buildWaveform(env);
    expect(w.bars.length, Waveform.barCount);
    expect(w.bars.first, lessThan(w.bars.last));
    expect(w.bars.last, 255);
    expect(w.level.length, 200); // 20 pro Sekunde
    expect(w.levelAt(const Duration(seconds: 2)), lessThan(0.4));
    expect(w.levelAt(const Duration(seconds: 8)), closeTo(1, 0.01));
    final back = Waveform.fromBytes(w.toBytes())!;
    expect(back.bars, w.bars);
    expect(back.level, w.level);
  });

  test('Hüllkurve ohne Audiofilter (Android): Betrag gemittelt', () {
    final pcm = Int16List.fromList([
      for (var i = 0; i < 40; i++) i.isEven ? 1000 : -1000,
      for (var i = 0; i < 20; i++) 0,
    ]);
    expect(absEnvelope(pcm, 20), [1000, 1000, 0]);
  });
}
