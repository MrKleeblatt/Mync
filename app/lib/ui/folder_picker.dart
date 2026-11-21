import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../core/music_fs.dart';

/// Ordner wählen: unter Android über die Ordnerfreigabe (mync bekommt nur
/// Zugriff auf diesen Ordner), sonst über den Dateidialog.
Future<String?> pickMusicFolder({
  String? initial,
  String confirm = 'Wählen',
}) async {
  if (Platform.isAndroid) return MusicFs.pickTree(initial: initial);
  final p = await getDirectoryPath(
    initialDirectory: initial == null || initial.isEmpty ? null : initial,
    confirmButtonText: confirm,
  );
  return p == null || p.isEmpty ? null : p;
}

/// Lesbarer Name eines Musikordners.
String folderLabel(String dir) => dir.isEmpty ? '–' : MusicFs.describe(dir);
