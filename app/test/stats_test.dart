import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/core/mync_core.dart';
import 'package:mync/library/track.dart';
import 'package:mync/stats/history.dart';
import 'package:mync/stats/stats.dart';
import 'package:mync/stats/suggestions.dart';

Track track(
  String path, {
  String? id,
  String? artist,
  int durMs = 200000,
  int addedMs = 0,
}) => Track(
  TrackInfo.fromJson({
    'file_id': id ?? path,
    'path': path,
    'duration_ms': durMs,
    'added_ms': addedMs,
    'has_lyrics': false,
    'fields': {
      if (artist != null) 'artist': [artist],
    },
  }),
);

PlayEvent ev(
  String path,
  DateTime t, {
  int ms = 200000,
  int len = 200000,
  bool user = false,
}) => PlayEvent(
  startMs: t.millisecondsSinceEpoch,
  path: path,
  fileId: path,
  listenedMs: ms,
  durationMs: len,
  byUser: user,
  completed: ms >= len,
);

void main() {
  group('PlayEvent', () {
    test('zählt ab 30 s bzw. der Hälfte, sonst übersprungen', () {
      final t = DateTime(2026, 11, 3);
      expect(ev('a', t, ms: 31000, len: 300000, user: true).counted, isTrue);
      expect(ev('a', t, ms: 10000, len: 300000, user: true).skipped, isTrue);
      expect(
        ev('a', t, ms: 10000, len: 18000).counted,
        isTrue,
      ); // kurzer Titel: Hälfte
      expect(
        ev('a', t, ms: 5000, len: 300000).skipped,
        isFalse,
      ); // nicht vom Nutzer
    });

    test(
      'Protokoll-Datei: anhängen und wieder laden, kaputte Zeile überspringen',
      () async {
        final dir = await Directory.systemTemp.createTemp('mync_hist');
        addTearDown(() => dir.delete(recursive: true));
        final f = File('${dir.path}/history.jsonl');
        final h = ListeningHistory(f);
        await h.append(ev('a/b.mp3', DateTime(2026, 1, 1)));
        await f.writeAsString('{kaputt\n', mode: FileMode.append);
        await h.append(ev('c.mp3', DateTime(2026, 1, 2), user: true, ms: 1000));
        final h2 = ListeningHistory(f);
        await h2.load();
        expect(h2.events.length, 2);
        expect(h2.events[1].skipped, isTrue);
      },
    );
  });

  group('ListeningSession', () {
    test('Spulen zählt nicht als gehört', () {
      final s = ListeningSession(path: 'a', fileId: 'a', durationMs: 300000);
      for (var ms = 0; ms <= 10000; ms += 250) {
        s.onPosition(Duration(milliseconds: ms), playing: true);
      }
      s.onPosition(const Duration(seconds: 120), playing: true); // Sprung
      s.onPosition(const Duration(milliseconds: 120500), playing: true);
      expect(s.listenedMs, 10500);
      s.onPosition(const Duration(seconds: 130), playing: false); // pausiert
      expect(s.listenedMs, 10500);
    });
  });

  group('Statistik', () {
    test('Monat: Top-Liste, Tageszeit, Wochentag, Ordner', () {
      final now = DateTime(2026, 11, 18, 20);
      final events = [
        ev('Rock/a.mp3', DateTime(2026, 11, 2, 20)), // Montag, 20 Uhr
        ev('Rock/a.mp3', DateTime(2026, 11, 3, 20)),
        ev('Rock/b.mp3', DateTime(2026, 11, 3, 21)),
        ev(
          'Jazz/c.mp3',
          DateTime(2026, 11, 4, 8),
          ms: 5000,
          user: true,
        ), // übersprungen
        ev('Jazz/c.mp3', DateTime(2026, 10, 30, 8)), // Vormonat
      ];
      final s = summarize(events, StatsRange.thisMonth, now: now);
      expect(s.plays, 3);
      expect(s.skips, 1);
      expect(s.top.map((t) => t.path), ['Rock/a.mp3', 'Rock/b.mp3']);
      expect(s.top.first.plays, 2);
      expect(s.byHour[20], 400000);
      expect(s.byWeekday[0], 200000); // Montag
      expect(s.topFolders.first.folder, 'Rock');
      expect(s.activeDays, 3);
      final last = summarize(events, StatsRange.lastMonth, now: now);
      expect(last.top.single.path, 'Jazz/c.mp3');
    });
  });

  group('Vorschläge', () {
    final now = DateTime(2026, 11, 18, 20);
    const day = Duration(days: 1);

    test('lange nicht Gehörtes, Unbekanntes aus Lieblingsordnern, keine Übersprungenen', () {
      final tracks = [
        track('Alt/hit.mp3'),
        track('Rock/a.mp3', artist: 'Band'),
        track('Rock/neu.mp3'),
        track('Rock/frisch.mp3'),
        track('Jazz/nervt.mp3'),
        track('Klassik/x.mp3'),
      ];
      final events = [
        for (var i = 0; i < 5; i++)
          ev('Alt/hit.mp3', now.subtract(day * (100 + i))),
        for (var i = 0; i < 6; i++)
          ev('Rock/a.mp3', now.subtract(day * (10 + i))),
        ev('Rock/frisch.mp3', now.subtract(const Duration(hours: 5))),
        for (var i = 0; i < 3; i++)
          ev(
            'Jazz/nervt.mp3',
            now.subtract(day * (20 + i)),
            ms: 3000,
            user: true,
          ),
      ];
      final s = suggest(
        events: events,
        tracks: tracks,
        now: now,
        random: Random(1),
      );
      final byPath = {for (final x in s) x.track.path: x};
      expect(byPath['Alt/hit.mp3']?.reason, startsWith('Lange nicht gehört'));
      expect(byPath['Rock/neu.mp3']?.reason, startsWith('Neu'));
      expect(
        byPath['Rock/frisch.mp3']?.reason,
        'Lange nicht gehört',
        reason: 'gerade erst gehört: nur als Auffüller',
      );
      expect(
        s.indexWhere((x) => x.track.path == 'Rock/frisch.mp3'),
        greaterThan(2),
      );
      expect(
        byPath.containsKey('Jazz/nervt.mp3'),
        isFalse,
        reason: 'meist übersprungen',
      );
    });

    test('ohne Verlauf: neu Hinzugefügtes und Zufall', () {
      final tracks = [
        track('a.mp3', addedMs: now.subtract(day * 2).millisecondsSinceEpoch),
        track('b.mp3'),
      ];
      final s = suggest(
        events: const [],
        tracks: tracks,
        now: now,
        random: Random(2),
      );
      expect(s.first.track.path, 'a.mp3');
      expect(s.length, 2);
    });

    test('höchstens 3 Titel pro Ordner, Rest wird aufgefüllt', () {
      final tracks = [for (var i = 0; i < 10; i++) track('Ordner/$i.mp3')];
      final s = suggest(events: const [], tracks: tracks, now: now, count: 8);
      expect(s.length, 8);
      expect(s.where((x) => x.reason == 'Zufällig').length, 3);
      expect(s.skip(3).every((x) => x.reason == 'Neu'), isTrue);
    });

    test('alles kürzlich gehört: trotzdem Vorschläge, älteste zuerst', () {
      final tracks = [track('a.mp3'), track('b.mp3')];
      final events = [
        ev('a.mp3', now.subtract(const Duration(hours: 2))),
        ev('b.mp3', now.subtract(const Duration(hours: 30))),
      ];
      final s = suggest(events: events, tracks: tracks, now: now);
      expect(s.map((x) => x.track.path), ['b.mp3', 'a.mp3']);
    });
  });
}
