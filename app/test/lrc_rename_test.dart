import 'package:flutter_test/flutter_test.dart';
import 'package:mync/core/mync_core.dart';
import 'package:mync/library/lrc.dart';
import 'package:mync/library/rename.dart';
import 'package:mync/library/track.dart';

Track track(String path, Map<String, List<String>> f) => Track(
  TrackInfo.fromJson({
    'file_id': 'x',
    'path': path,
    'duration_ms': 1000,
    'added_ms': 0,
    'has_lyrics': false,
    'fields': f,
  }),
);

void main() {
  test('LRC: Entwurf aus Text, Format mit Zeitstempeln', () {
    final d = lrcDraftFrom('Erste Zeile\n\nZweite Zeile\n');
    expect(d.map((l) => l.text), ['Erste Zeile', 'Zweite Zeile']);
    d[0].time = const Duration(seconds: 3, milliseconds: 456);
    d[1].time = const Duration(minutes: 1, seconds: 2, milliseconds: 5);
    final lrc = formatLrc(d, title: 'T', artist: 'A');
    expect(
      lrc,
      '[ar:A]\n[ti:T]\n[00:03.46]Erste Zeile\n[01:02.01]Zweite Zeile\n',
    );
    final back = lrcDraftFrom(lrc);
    expect(back.length, 2);
    expect(
      back[1].time,
      const Duration(minutes: 1, seconds: 2, milliseconds: 10),
    );
    // Zeilen ohne Zeit fallen weg
    expect(formatLrc([LrcDraftLine('x')]), '');
  });

  test('Umbenennen nach Muster', () {
    final t = track('Unsortiert/track03.mp3', {
      'artist': ['Björk'],
      'album': ['Post'],
      'title': ['Hyper/ballad?'],
      'track': ['2'],
      'date': ['1995-06-13'],
    });
    expect(
      renameTarget(t, '{track} - {title}'),
      'Unsortiert/02 - Hyper_ballad_.mp3',
    );
    expect(
      renameTarget(t, '/{artist}/{year} {album}/{track} {title}'),
      'Björk/1995 Post/02 Hyper_ballad_.mp3',
    );
    expect(
      renameTarget(t, '/{albumartist}/{album}/{title}', rootPrefix: 'Platte'),
      'Platte/Björk/Post/Hyper_ballad_.mp3',
    );
    // fehlende Nummer: Trenner verschwindet
    final u = track('a/b.flac', {
      'title': ['Ohne Nummer'],
    });
    expect(renameTarget(u, '{track} - {title}'), 'a/Ohne Nummer.flac');
    expect(renameTarget(u, '{disc}'), isNull);
    expect(renameTarget(u, '{name} ({year})'), 'a/b.flac');
  });
}
