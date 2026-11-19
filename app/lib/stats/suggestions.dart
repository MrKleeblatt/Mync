import 'dart:math';

import '../library/track.dart';
import 'history.dart';

/// Ein Vorschlag mit Begründung.
class Suggestion {
  Suggestion(this.track, this.reason, this.score);
  final Track track;
  final String reason;
  final double score;
}

/// Was über einen Titel aus dem Hörprotokoll bekannt ist.
class _Known {
  int plays = 0;
  int skips = 0;
  int lastMs = 0;
  final hours = List<int>.filled(24, 0);
}

/// Schlägt Musik aus der eigenen Bibliothek vor – auf Basis des Hörprotokolls.
///
/// Kategorien (die beste je Titel zählt):
/// - **Lange nicht gehört**: früher oft gespielt, seit über 45 Tagen nicht mehr
/// - **Passt zur Tageszeit**: Titel der letzten 60 Tage, die meist um diese Uhrzeit liefen
/// - **Neu aus Lieblingsordnern**: noch nie gehört, liegt in viel gehörten Ordnern
/// - **Mehr von Künstler**: noch selten gehört, Künstler wird viel gehört
/// - **Neu hinzugefügt**: in den letzten 30 Tagen hinzugekommen, noch nie gehört
///
/// Ausgeschlossen: in den letzten 3 Tagen gehört, oder meist übersprungen.
/// Höchstens 3 Titel pro Ordner, damit der Mix abwechslungsreich bleibt;
/// reicht das nicht, wird mit den am längsten nicht gehörten Titeln aufgefüllt.
List<Suggestion> suggest({
  required List<PlayEvent> events,
  required List<Track> tracks,
  DateTime? now,
  int count = 30,
  Random? random,
}) {
  final rnd = random ?? Random();
  final t0 = now ?? DateTime.now();
  final nowMs = t0.millisecondsSinceEpoch;
  const day = 86400000;
  final since90 = nowMs - 90 * day;

  final known = <String, _Known>{};
  final folderMs = <String, int>{};
  final artistMs = <String, int>{};
  final byPath = {for (final t in tracks) t.path: t};
  final byId = {for (final t in tracks) t.fileId: t};

  for (final e in events) {
    final t = (e.fileId.isNotEmpty ? byId[e.fileId] : null) ?? byPath[e.path];
    if (t == null) continue;
    final k = known.putIfAbsent(t.fileId, _Known.new);
    if (e.counted) {
      k.plays++;
      k.hours[e.start.hour]++;
    } else if (e.skipped) {
      k.skips++;
    }
    if (e.startMs > k.lastMs) k.lastMs = e.startMs;
    if (e.startMs >= since90) {
      folderMs[t.folder] = (folderMs[t.folder] ?? 0) + e.listenedMs;
      for (final a in t.artists) {
        artistMs[a.toLowerCase()] =
            (artistMs[a.toLowerCase()] ?? 0) + e.listenedMs;
      }
    }
  }
  final maxFolder = folderMs.values.fold(0, max);
  final maxArtist = artistMs.values.fold(0, max);
  final hour = t0.hour;

  /// Anteil der Ordner-Hörzeit (inkl. übergeordneter Ordner, abgeschwächt).
  double folderAffinity(String folder) {
    if (maxFolder == 0) return 0;
    var best = 0.0;
    var f = folder;
    var weight = 1.0;
    while (true) {
      best = max(best, weight * (folderMs[f] ?? 0) / maxFolder);
      final i = f.lastIndexOf('/');
      if (f.isEmpty) break;
      f = i < 0 ? '' : f.substring(0, i);
      weight *= 0.6;
    }
    return best;
  }

  final out = <Suggestion>[];
  for (final t in tracks) {
    final k = known[t.fileId];
    final plays = k?.plays ?? 0;
    final skips = k?.skips ?? 0;
    if (k != null && nowMs - k.lastMs < 3 * day) continue;
    if (skips >= 2 && skips > plays) continue;
    final jitter = rnd.nextDouble() * 0.15;
    var score = 0.0;
    var reason = '';
    void consider(double s, String r) {
      if (s > score) {
        score = s;
        reason = r;
      }
    }

    // Lange nicht gehört
    if (plays >= 3 && nowMs - k!.lastMs > 45 * day) {
      consider(
        0.6 + min(plays, 20) / 40,
        'Lange nicht gehört ($plays× gespielt)',
      );
    }
    // Passt zur Tageszeit (nur für zuletzt regelmäßig Gehörtes)
    if (plays >= 2 && nowMs - k!.lastMs <= 60 * day) {
      var near = 0;
      for (var d = -1; d <= 1; d++) {
        near += k.hours[(hour + d + 24) % 24];
      }
      final share = near / plays;
      if (share >= 0.5) {
        consider(0.5 + share * 0.4, 'Oft um diese Uhrzeit gehört');
      }
    }
    // Neu aus Lieblingsordnern
    if (plays == 0) {
      final fa = folderAffinity(t.folder);
      if (fa > 0.15) {
        final name = t.folder.isEmpty
            ? 'der Musik'
            : '„${t.folder.split('/').last}“';
        consider(0.4 + fa * 0.5, 'Noch nie gehört, aus $name');
      }
    }
    // Mehr von Künstler
    if (plays <= 1 && maxArtist > 0) {
      for (final a in t.artists) {
        final aa = (artistMs[a.toLowerCase()] ?? 0) / maxArtist;
        if (aa > 0.2) consider(0.35 + aa * 0.5, 'Mehr von $a');
      }
    }
    // Neu hinzugefügt
    if (plays == 0 && t.info.addedMs > 0 && nowMs - t.info.addedMs < 30 * day) {
      consider(0.55, 'Neu in der Bibliothek');
    }
    // Ohne Verlauf: Zufall aus der Bibliothek
    if (events.isEmpty) consider(0.1, 'Zufällig aus der Bibliothek');
    if (score > 0) out.add(Suggestion(t, reason, score + jitter));
  }

  out.sort((a, b) => b.score.compareTo(a.score));
  final perFolder = <String, int>{};
  final picked = <Suggestion>[];
  for (final s in out) {
    final n = perFolder[s.track.folder] ?? 0;
    if (n >= 3) continue;
    perFolder[s.track.folder] = n + 1;
    picked.add(s);
    if (picked.length >= count) break;
  }
  // Auffüllen (kleine Bibliothek oder alles kürzlich gehört): am längsten
  // nicht gehörte Titel zuerst, oft übersprungene weiterhin ausgenommen.
  if (picked.length < count) {
    final have = picked.map((p) => p.track.fileId).toSet();
    final rest =
        tracks.where((t) {
            if (have.contains(t.fileId)) return false;
            final k = known[t.fileId];
            return k == null || !(k.skips >= 2 && k.skips > k.plays);
          }).toList()
          ..shuffle(rnd)
          ..sort(
            (a, b) => (known[a.fileId]?.lastMs ?? 0).compareTo(
              known[b.fileId]?.lastMs ?? 0,
            ),
          );
    for (final t in rest.take(count - picked.length)) {
      final k = known[t.fileId];
      picked.add(
        Suggestion(t, k == null ? 'Noch nie gehört' : 'Länger nicht gehört', 0),
      );
    }
  }
  return picked;
}
