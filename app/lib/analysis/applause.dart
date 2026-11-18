import 'dart:math';
import 'dart:typed_data';

/// Erkennt Applaus am Anfang oder Ende eines Titels (Live-Aufnahmen).
///
/// Applaus ist ein Gemisch aus vielen einzelnen Klatschern: Das Spektrum
/// hat zwar eine Färbung, aber seine **Feinstruktur ist in jedem Block
/// zufällig**. Musik (auch verzerrte Gitarren) hat Töne und Obertöne, die
/// über viele Blöcke an derselben Stelle bleiben. Gemessen wird deshalb die
/// Korrelation der Feinstruktur (Betragsspektrum minus geglätteter Verlauf)
/// zwischen aufeinanderfolgenden Blöcken von 64 ms. Ein Bereich gilt als
/// Applaus, wenn in jedem 1-s-Fenster die meisten Blöcke so klingen. Am
/// Anfang bzw. Ende wird Stille übersprungen.
class ApplauseDetector {
  const ApplauseDetector({
    this.rate = 16000,
    this.maxCorrelation = 0.35,
    this.minLength = const Duration(seconds: 2),
  });

  final int rate;

  /// Bis zu dieser Block-zu-Block-Korrelation klingt ein Block wie Applaus.
  final double maxCorrelation;

  /// Kürzerer „Applaus“ wird ignoriert.
  final Duration minLength;

  static const _n = 1024; // Blockgröße (64 ms bei 16 kHz)
  static const _hop = 512;
  static const _smooth = 8; // ± Bins für den geglätteten Verlauf

  /// Korrelation der Feinstruktur je Block (NaN bei Stille/unbestimmt).
  Float64List correlations(Int16List pcm) {
    final frames = pcm.length < _n ? 0 : (pcm.length - _n) ~/ _hop + 1;
    final out = Float64List(frames);
    final re = Float64List(_n), im = Float64List(_n);
    final win = Float64List(_n);
    for (var i = 0; i < _n; i++) {
      win[i] = 0.5 - 0.5 * cos(2 * pi * i / (_n - 1));
    }
    final lo = (300 * _n / rate).round(), hi = (6000 * _n / rate).round();
    final m = hi - lo;
    final logp = Float64List(m);
    var prev = Float64List(m), fine = Float64List(m);
    var havePrev = false;
    for (var f = 0; f < frames; f++) {
      final off = f * _hop;
      var energy = 0.0;
      for (var i = 0; i < _n; i++) {
        final x = pcm[off + i] / 32768.0;
        energy += x * x;
        re[i] = x * win[i];
        im[i] = 0;
      }
      if (sqrt(energy / _n) < 0.003) {
        out[f] = double.nan; // ≈ −50 dBFS: Stille
        havePrev = false;
        continue;
      }
      fft(re, im);
      for (var k = 0; k < m; k++) {
        final b = lo + k;
        logp[k] = sqrt(re[b] * re[b] + im[b] * im[b]);
      }
      // Feinstruktur = Betragsspektrum minus gleitender Mittelwert
      var mean = 0.0;
      for (var k = 0; k < m; k++) {
        var s = 0.0;
        var c = 0;
        for (var j = max(0, k - _smooth); j <= min(m - 1, k + _smooth); j++) {
          s += logp[j];
          c++;
        }
        fine[k] = logp[k] - s / c;
        mean += fine[k];
      }
      mean /= m;
      for (var k = 0; k < m; k++) {
        fine[k] -= mean;
      }
      if (havePrev) {
        var xy = 0.0, xx = 0.0, yy = 0.0;
        for (var k = 0; k < m; k++) {
          xy += fine[k] * prev[k];
          xx += fine[k] * fine[k];
          yy += prev[k] * prev[k];
        }
        out[f] = xy / sqrt(xx * yy + 1e-12);
      } else {
        // erster Block nach Stille: kein Vergleich möglich → unbestimmt
        // (zählt wie Stille, sonst würden Pausen zwischen Klatschern stören)
        out[f] = double.nan;
      }
      final t = prev;
      prev = fine;
      fine = t;
      havePrev = true;
    }
    return out;
  }

  /// Je Block: 0 = Stille, 1 = wie Applaus, 2 = anderes (Musik, Sprache).
  Uint8List classify(Int16List pcm) {
    final c = correlations(pcm);
    return Uint8List.fromList([
      for (final v in c) v.isNaN ? 0 : (v <= maxCorrelation ? 1 : 2),
    ]);
  }

  Duration _frameTime(int f) =>
      Duration(microseconds: f * _hop * 1000000 ~/ rate);

  /// Länge des Applauses ab dem Anfang von [pcm] (null = keiner).
  /// Mit [fromEnd] rückwärts: Länge des Applauses vor dem Ende.
  Duration? detect(Int16List pcm, {bool fromEnd = false}) {
    var c = classify(pcm);
    if (fromEnd) c = Uint8List.fromList(c.reversed.toList());
    var start = 0;
    while (start < c.length && c[start] == 0) {
      start++;
    }
    final perSec = rate ~/ _hop; // Blöcke pro Sekunde
    var end = start;
    // Fenster für Fenster vorrücken, solange überwiegend Applaus
    while (end + perSec <= c.length) {
      var clap = 0, other = 0;
      for (var i = end; i < end + perSec; i++) {
        if (c[i] == 1) clap++;
        if (c[i] == 2) other++;
      }
      if (clap < (clap + other) * 0.6 || clap == 0) break;
      end += perSec ~/ 2;
    }
    if (end == start) return null;
    // genauer: bis zum letzten Applaus-Block vor dem Übergang
    var last = min(end + perSec, c.length) - 1;
    while (last > start && c[last] != 1) {
      last--;
    }
    final len = _frameTime(last + 1);
    if (len - _frameTime(start) < minLength) return null;
    // Alles Applaus/Rauschen bis zum Ende des Ausschnitts: kein Übergang zu
    // Musik gefunden (z. B. Regen- oder Rauschaufnahme) → nichts melden.
    final rest = c.sublist(min(last + 1, c.length));
    if (!rest.any((v) => v == 2)) return null;
    return len;
  }
}

/// Radix-2-FFT, in place (Länge = Zweierpotenz).
void fft(Float64List re, Float64List im) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      var t = re[i];
      re[i] = re[j];
      re[j] = t;
      t = im[i];
      im[i] = im[j];
      im[j] = t;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * pi / len;
    final wr = cos(ang), wi = sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var k = 0; k < len ~/ 2; k++) {
        final a = i + k, b = a + len ~/ 2;
        final xr = re[b] * cr - im[b] * ci;
        final xi = re[b] * ci + im[b] * cr;
        re[b] = re[a] - xr;
        im[b] = im[a] - xi;
        re[a] += xr;
        im[a] += xi;
        final t = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = t;
      }
    }
  }
}
