import 'package:flutter_test/flutter_test.dart';
import 'package:mync/library/chapters.dart';

List<(int, String)> simple(List<Chapter> c) => [
  for (final x in c) (x.start.inSeconds, x.title),
];

void main() {
  test('YouTube-Beschreibung mit Fließtext', () {
    const text = '''
Live-Mitschnitt vom Sommerfest. Beginn war um 19:30 Uhr am Park.

Kapitel:
0:00 Begrüßung
0:12 Erstes Lied – Morgenrot
1:05:30 Zugabe

Danke fürs Zuhören!''';
    expect(simple(parseTextChapters(text)), [
      (0, 'Begrüßung'),
      (12, 'Erstes Lied – Morgenrot'),
      (3930, 'Zugabe'),
    ]);
  });

  test('Klammern, Trennzeichen, Aufzählungen, Bereiche', () {
    const text = '''
[00:00] Intro
(02:15) - Strophe 1
• 4:01 | Refrain
3. 05:59.5 – Bridge
07:00 - 09:12 Outro''';
    final c = parseTextChapters(text);
    expect(simple(c), [
      (0, 'Intro'),
      (135, 'Strophe 1'),
      (241, 'Refrain'),
      (359, 'Bridge'),
      (420, 'Outro'),
    ]);
    expect(
      c[3].start,
      const Duration(minutes: 5, seconds: 59, milliseconds: 500),
    );
    expect(c[4].end, const Duration(minutes: 9, seconds: 12));
  });

  test('Zeitstempel am Zeilenende', () {
    const text = 'Intro 0:00\nTeil zwei - 1:30\nFinale (3:45)';
    expect(simple(parseTextChapters(text)), [
      (0, 'Intro'),
      (90, 'Teil zwei'),
      (225, 'Finale'),
    ]);
  });

  test('ohne Titel, nicht aufsteigend, zu wenige, länger als der Titel', () {
    expect(simple(parseTextChapters('0:00\n1:00 B')), [
      (0, 'Kapitel 1'),
      (60, 'B'),
    ]);
    expect(simple(parseTextChapters('0:00 A\n2:00 B\n1:00 C\n3:00 D')), [
      (0, 'A'),
      (120, 'B'),
      (180, 'D'),
    ]);
    expect(parseTextChapters('Nur 0:00 Anfang'), isEmpty);
    expect(
      parseTextChapters(
        'Treffen um 12:30 im Park, dann 14:00 Kaffee und Kuchen bis zum Abend',
      ),
      isEmpty,
    );
    expect(
      simple(
        parseTextChapters(
          '0:00 A\n1:00 B\n9:00 C',
          duration: const Duration(minutes: 5),
        ),
      ),
      [(0, 'A'), (60, 'B')],
    );
    expect(parseTextChapters('0:00 A\n0:61 B'), isEmpty); // ungültige Sekunden
  });

  test('aktuelles Kapitel', () {
    final l = ChapterList(
      parseTextChapters('0:10 A\n1:00 B\n2:00 C'),
      ChapterSource.text,
    );
    expect(l.indexAt(Duration.zero), -1);
    expect(l.indexAt(const Duration(seconds: 10)), 0);
    expect(l.indexAt(const Duration(seconds: 90)), 1);
    expect(l.indexAt(const Duration(hours: 1)), 2);
  });
}
