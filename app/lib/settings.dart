import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Einstellungen der App: Musikordner und Ort des Manifests.
class AppSettings {
  AppSettings._(this._prefs, this.dataDir);

  final SharedPreferences _prefs;

  /// Verzeichnis für App-Daten (Manifest-Datenbank).
  final String dataDir;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationSupportDirectory();
    return AppSettings._(prefs, dir.path);
  }

  static String get defaultMusicDir {
    if (Platform.isAndroid) return '/storage/emulated/0/Music';
    final home = Platform.environment['HOME'] ?? '';
    for (final name in ['Musik', 'Music']) {
      if (Directory('$home/$name').existsSync()) return '$home/$name';
    }
    return '$home/Music';
  }

  String get musicDir => _prefs.getString('musicDir') ?? defaultMusicDir;

  Future<void> setMusicDir(String path) => _prefs.setString('musicDir', path);

  String get manifestDb => '$dataDir${Platform.pathSeparator}manifest.db';
}
