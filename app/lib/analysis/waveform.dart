import 'dart:math';
import 'dart:typed_data';

/// Hüllkurve eines Titels für die Visualisierung hinter der Zeitleiste.
class Waveform {
  Waveform(this.bars, this.level);

  /// Balken über die ganze Länge (0–255), für die Silhouette.
  final Uint8List bars;

  /// Pegel mit [levelRate] Werten pro Sekunde (0–255), für die Bewegung.
  final Uint8List level;
  static const levelRate = 20;
  static const barCount = 480;

  /// Pegel an Position [t] (0–1), linear interpoliert.
  double levelAt(Duration t) {
    if (level.isEmpty) return 0;
    final x = t.inMilliseconds * levelRate / 1000;
    final i = x.floor().clamp(0, level.length - 1);
    final j = min(i + 1, level.length - 1);
    final f = (x - i).clamp(0.0, 1.0);
    return (level[i] * (1 - f) + level[j] * f) / 255;
  }

  Uint8List toBytes() {
    final b = BytesBuilder();
    final h = ByteData(8)
      ..setUint32(0, bars.length)
      ..setUint32(4, level.length);
    b
      ..add(h.buffer.asUint8List())
      ..add(bars)
      ..add(level);
    return b.takeBytes();
  }

  static Waveform? fromBytes(Uint8List d) {
    if (d.length < 8) return null;
    final h = ByteData.sublistView(d, 0, 8);
    final nb = h.getUint32(0), nl = h.getUint32(4);
    if (d.length != 8 + nb + nl) return null;
    return Waveform(
      Uint8List.fromList(d.sublist(8, 8 + nb)),
      Uint8List.fromList(d.sublist(8 + nb)),
    );
  }
}

/// Aus der Hüllkurve (Betrag, auf [rate] Hz geglättet) die Balken und den
/// Pegelverlauf bilden. Leise Stellen bleiben sichtbar (Wurzel-Kurve).
Waveform buildWaveform(Int16List env, {int rate = 200}) {
  if (env.isEmpty) return Waveform(Uint8List(0), Uint8List(0));
  // Bezugspegel: 98-%-Quantil statt Maximum, damit einzelne Spitzen nicht
  // alles andere flach drücken
  final sorted = Int16List.fromList(env)..sort();
  final ref = max(
    1,
    sorted[(sorted.length * 0.98).floor().clamp(0, sorted.length - 1)],
  );
  int scale(double v) => (sqrt((v / ref).clamp(0.0, 1.0)) * 255).round();

  final bars = Uint8List(Waveform.barCount);
  for (var i = 0; i < bars.length; i++) {
    final a = i * env.length ~/ bars.length;
    final b = max(a + 1, (i + 1) * env.length ~/ bars.length);
    var sum = 0.0;
    for (var k = a; k < b && k < env.length; k++) {
      sum += env[k].abs();
    }
    bars[i] = scale(sum / (b - a));
  }
  final step = max(1, rate ~/ Waveform.levelRate);
  final level = Uint8List((env.length + step - 1) ~/ step);
  for (var i = 0; i < level.length; i++) {
    var sum = 0.0;
    var n = 0;
    for (var k = i * step; k < (i + 1) * step && k < env.length; k++) {
      sum += env[k].abs();
      n++;
    }
    level[i] = scale(sum / max(1, n));
  }
  return Waveform(bars, level);
}
