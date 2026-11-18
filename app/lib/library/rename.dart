import 'track.dart';

/// Platzhalter für Umbenennungsmuster.
const renamePlaceholders = <String, String>{
  '{artist}': 'Künstler',
  '{albumartist}': 'Album-Künstler (sonst Künstler)',
  '{album}': 'Album',
  '{title}': 'Titel (sonst bisheriger Name)',
  '{track}': 'Titelnummer, zweistellig',
  '{disc}': 'CD-Nummer',
  '{year}': 'Jahr',
  '{genre}': 'Genre',
  '{composer}': 'Komponist',
  '{name}': 'bisheriger Dateiname',
};

/// Zeichen, die in Datei- und Ordnernamen nicht vorkommen sollen
/// (auch nicht auf dem Handy bzw. FAT-Speicherkarten).
final _bad = RegExp(r'[\\/:*?"<>|\x00-\x1f]');

String _clean(String s) =>
    s.replaceAll(_bad, '_').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Wendet [pattern] auf [t] an und liefert den neuen Pfad (ohne Endung
/// wird die bisherige angehängt). Beginnt das Muster mit „/“, ist das
/// Ergebnis relativ zur Wurzel des Musikordners, sonst zum bisherigen
/// Ordner der Datei. Liefert null, wenn nichts Sinnvolles herauskommt.
///
/// [rootPrefix]: Präfix des Musikordners der Datei in der Bibliothek
/// ('' beim Hauptordner, siehe `Library.extraRoots`).
String? renameTarget(Track t, String pattern, {String rootPrefix = ''}) {
  var p = pattern.trim();
  if (p.isEmpty) return null;
  final fromRoot = p.startsWith('/');
  if (fromRoot) p = p.substring(1);

  String value(String key) {
    switch (key) {
      case '{artist}':
        return t.artists.isEmpty
            ? 'Unbekannter Künstler'
            : t.artists.join(', ');
      case '{albumartist}':
        return t.albumArtist;
      case '{album}':
        return t.album ?? 'Unbekanntes Album';
      case '{title}':
        return t.hasTitle ? t.title : t.baseName;
      case '{track}':
        final n = t.trackNo;
        return n == null ? '' : n.toString().padLeft(2, '0');
      case '{disc}':
        return t.discNo?.toString() ?? '';
      case '{year}':
        return t.year?.toString() ?? '';
      case '{genre}':
        return t.genres.join(', ');
      case '{composer}':
        return t.composers.join(', ');
      case '{name}':
        return t.baseName;
    }
    return key;
  }

  final parts = <String>[];
  for (final segment in p.split('/')) {
    final s = segment.replaceAllMapped(
      RegExp(r'\{[a-z]+\}'),
      (m) => _clean(value(m.group(0)!)),
    );
    // Trenner um leere Platzhalter aufräumen („ - - “, „()“, führende „- “)
    var c = s
        .replaceAll(RegExp(r'\(\s*\)|\[\s*\]'), '')
        .replaceAll(RegExp(r'(\s*[-–·.]\s*){2,}'), ' - ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    c = c.replaceAll(RegExp(r'^[-–·.\s]+|[-–·\s]+$'), '').trim();
    if (c.isEmpty || c == '..') return null;
    parts.add(c);
  }
  var name = parts.removeLast();
  final ext = t.extension;
  if (!name.toLowerCase().endsWith('.$ext')) name = '$name.$ext';
  parts.add(name);
  final rel = parts.join('/');
  if (fromRoot) return rootPrefix.isEmpty ? rel : '$rootPrefix/$rel';
  return t.folder.isEmpty ? rel : '${t.folder}/$rel';
}

/// Begleitdateien, die beim Umbenennen mitwandern (gleicher Basisname).
const sidecarExtensions = ['lrc', 'txt', 'description', 'chapters.txt', 'cue'];
