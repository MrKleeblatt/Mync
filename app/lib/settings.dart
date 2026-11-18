import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Einstellungen der App (SharedPreferences) und Speicherorte.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs, this.dataDir, this.cacheDir);

  final SharedPreferences _prefs;

  /// Verzeichnis für App-Daten (Manifest, Zustand der Warteschlangen).
  final String dataDir;

  /// Verzeichnis für Cover-Cache.
  final String cacheDir;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();
    return AppSettings._(prefs, dir.path, cache.path);
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
  Future<void> setMusicDir(String path) async {
    await _prefs.setString('musicDir', path);
    notifyListeners();
  }

  String get manifestDb => '$dataDir${Platform.pathSeparator}manifest.db';
  String get stateFile => '$dataDir${Platform.pathSeparator}state.json';

  ThemeMode get themeMode =>
      ThemeMode.values.asNameMap()[_prefs.getString('theme')] ??
      ThemeMode.system;
  Future<void> setThemeMode(ThemeMode m) async {
    await _prefs.setString('theme', m.name);
    notifyListeners();
  }

  /// Bibliothek beim Start automatisch scannen.
  bool get scanOnStart => _prefs.getBool('scanOnStart') ?? true;
  Future<void> setScanOnStart(bool v) async {
    await _prefs.setBool('scanOnStart', v);
    notifyListeners();
  }

  /// Titel unter dieser Länge (Sekunden) ausblenden; 0 = alle zeigen.
  int get hideShorterThan => _prefs.getInt('hideShorterThan') ?? 0;
  Future<void> setHideShorterThan(int s) async {
    await _prefs.setInt('hideShorterThan', s);
    notifyListeners();
  }

  /// ReplayGain: no, track, album
  String get replayGain => _prefs.getString('replayGain') ?? 'no';
  Future<void> setReplayGain(String v) async {
    await _prefs.setString('replayGain', v);
    notifyListeners();
  }

  double get volume => _prefs.getDouble('volume') ?? 100;
  Future<void> setVolume(double v) => _prefs.setDouble('volume', v);

  /// Schrittweite beim Spulen in Sekunden.
  int get seekStep => _prefs.getInt('seekStep') ?? 10;
  Future<void> setSeekStep(int s) async {
    await _prefs.setInt('seekStep', s);
    notifyListeners();
  }

  double get speed => _prefs.getDouble('speed') ?? 1.0;
  Future<void> setSpeed(double v) => _prefs.setDouble('speed', v);

  /// Equalizer-Verstärkung je Band in dB (10 Bänder).
  List<double> get eqGains {
    final s = _prefs.getStringList('eqGains');
    if (s == null || s.length != eqBands.length) {
      return List.filled(eqBands.length, 0);
    }
    return s.map((e) => double.tryParse(e) ?? 0).toList();
  }

  Future<void> setEqGains(List<double> g) => _prefs.setStringList(
    'eqGains',
    g.map((e) => e.toStringAsFixed(1)).toList(),
  );

  bool get eqEnabled => _prefs.getBool('eqEnabled') ?? false;
  Future<void> setEqEnabled(bool v) => _prefs.setBool('eqEnabled', v);

  /// Aktuelle Bibliotheksansicht (Tab-Index).
  int get libraryTab => _prefs.getInt('libraryTab') ?? 0;
  Future<void> setLibraryTab(int i) => _prefs.setInt('libraryTab', i);

  String get trackSort => _prefs.getString('trackSort') ?? 'title';
  Future<void> setTrackSort(String v) => _prefs.setString('trackSort', v);
}

/// Mittenfrequenzen der Equalizer-Bänder (Hz).
const eqBands = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

const eqPresets = <String, List<double>>{
  'Neutral': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'Bass': [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
  'Höhen': [0, 0, 0, 0, 0, 1, 2, 4, 5, 6],
  'Rock': [4, 3, 2, 0, -1, -1, 1, 2, 3, 4],
  'Pop': [-1, 0, 2, 3, 4, 3, 1, 0, -1, -1],
  'Klassik': [3, 2, 1, 0, 0, 0, 0, 1, 2, 3],
  'Stimme': [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1],
  'Elektronik': [4, 4, 1, 0, -2, 1, 1, 2, 4, 5],
};
