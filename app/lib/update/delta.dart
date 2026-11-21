// Teil-Updates der Android-App, wie in Kassenbon (app/lib/delta.dart): Die
// installierte APK wird in Bausteine zerlegt (Zig-Kern, `chunker.zig` –
// dieselben Werte wie Kassenbon und wie `mync chunk` im Release-Skript).
// Geladen werden nur die Bausteine der neuen APK, die fehlen; die neue APK
// wird Byte für Byte zusammengesetzt und über SHA-256 geprüft.
//
// Anders als Kassenbon gibt es keinen eigenen Server: Bausteinliste und APK
// liegen im GitHub-Release, geladen wird mit einzelnen HTTP-Ranges (GitHub
// kennt keine Mehrfachbereiche). Nahe beieinanderliegende Bereiche werden
// deshalb zusammengefasst – ein paar Bytes mehr statt vieler Anfragen.
import 'dart:io';
import 'dart:typed_data';

/// Bausteinliste der neuen APK (`<apk>.chunks.json` im Release).
class ChunkManifest {
  ChunkManifest.fromJson(Map<String, dynamic> j)
    : version = j['version'] as String,
      name = j['name'] as String,
      url = j['url'] as String,
      sha256 = j['sha256'] as String,
      size = (j['size'] as num).toInt(),
      chunks = [
        for (final c in j['chunks'] as List)
          (c[0] as String, (c[1] as num).toInt()),
      ];

  final String version, name, url, sha256;
  final int size;
  final List<(String, int)> chunks;
}

/// Was geladen werden muss: Bereiche (Anfang, Länge) der neuen APK.
class DeltaPlan {
  DeltaPlan(this.manifest, this.have, this.ranges);
  final ChunkManifest manifest;

  /// Vorhandene Bausteine: Hash → (Offset, Länge) in der installierten APK.
  final Map<String, (int, int)> have;
  final List<(int, int)> ranges;

  int get download => ranges.fold(0, (a, r) => a + r.$2);
}

/// Wie Kassenbons `plan()`, plus: Bereiche mit höchstens [gap] Bytes
/// Abstand werden zu einer Anfrage verbunden.
DeltaPlan plan(
  ChunkManifest m,
  List<(String, int, int)> installed, {
  int gap = 64 * 1024,
}) {
  final have = {for (final (h, o, l) in installed) h: (o, l)};
  final ranges = <(int, int)>[];
  var off = 0;
  for (final (hash, len) in m.chunks) {
    if (!have.containsKey(hash)) {
      final last = ranges.isEmpty ? null : ranges.last;
      if (last != null && off - (last.$1 + last.$2) <= gap) {
        ranges[ranges.length - 1] = (last.$1, off + len - last.$1);
      } else {
        ranges.add((off, len));
      }
    }
    off += len;
  }
  return DeltaPlan(m, have, ranges);
}

/// Setzt die neue APK nach [out] zusammen: vorhandene Bausteine aus
/// [installed], der Rest aus [fetched] (Anfang des Bereichs → Bytes).
/// Größe und Prüfsumme prüft der Aufrufer.
Future<void> assemble(
  DeltaPlan p,
  String installed,
  Map<int, Uint8List> fetched,
  String out,
) async {
  final src = await File(installed).open();
  final dst = File(out).openWrite();
  final starts = fetched.keys.toList()..sort();
  try {
    var off = 0;
    for (final (hash, len) in p.manifest.chunks) {
      final c = p.have[hash];
      if (c != null) {
        await src.setPosition(c.$1);
        dst.add(await src.read(c.$2));
      } else {
        // Bereich finden, der diesen Baustein enthält
        var start = -1;
        for (final s in starts) {
          if (s > off) break;
          start = s;
        }
        final data = start < 0 ? null : fetched[start]!;
        if (data == null || off + len - start > data.length) {
          throw const FormatException('Baustein fehlt in den geladenen Daten');
        }
        dst.add(Uint8List.sublistView(data, off - start, off + len - start));
      }
      off += len;
    }
  } finally {
    await dst.close();
    await src.close();
  }
}
