import 'dart:convert';
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

  /// Für Tests: Einstellungen mit eigenen Verzeichnissen.
  @visibleForTesting
  static Future<AppSettings> forTest(String dataDir, String cacheDir) async =>
      AppSettings._(await SharedPreferences.getInstance(), dataDir, cacheDir);

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();
    return AppSettings._(prefs, dir.path, cache.path);
  }

  static String get defaultMusicDir {
    // Android: erst nach der Ordnerauswahl (Freigabe, siehe MusicFs)
    if (Platform.isAndroid) return '';
    final home = Platform.environment['HOME'] ?? '';
    for (final name in ['Musik', 'Music']) {
      if (Directory('$home/$name').existsSync()) return '$home/$name';
    }
    return '$home/Music';
  }

  /// Alle Einstellungen mit Typ (für das Backup).
  Map<String, Object> exportPrefs() => {
    for (final k in _prefs.getKeys())
      if (_prefs.get(k) case final Object v)
        k: {
          't': switch (v) {
            bool() => 'b',
            int() => 'i',
            double() => 'd',
            List() => 'l',
            _ => 's',
          },
          'v': v,
        },
  };

  /// Ersetzt alle Einstellungen (aus einem Backup).
  Future<void> importPrefs(Map<String, dynamic> prefs) async {
    await _prefs.clear();
    for (final e in prefs.entries) {
      final m = e.value as Map<String, dynamic>;
      final v = m['v'];
      switch (m['t']) {
        case 'b':
          await _prefs.setBool(e.key, v as bool);
        case 'i':
          await _prefs.setInt(e.key, (v as num).toInt());
        case 'd':
          await _prefs.setDouble(e.key, (v as num).toDouble());
        case 'l':
          await _prefs.setStringList(e.key, (v as List).cast<String>());
        default:
          await _prefs.setString(e.key, '$v');
      }
    }
  }

  /// Hauptordner; unter Android die Ordnerfreigabe (content://…), leer
  /// solange keine gewählt ist. Alte Pfade (vor der Freigabe) gelten nicht.
  String get musicDir {
    final v = _prefs.getString('musicDir') ?? defaultMusicDir;
    if (Platform.isAndroid && !v.startsWith('content://')) return '';
    return v;
  }

  Future<void> setMusicDir(String path) async {
    await _prefs.setString('musicDir', path);
    notifyListeners();
  }

  /// Weitere Musikordner (erscheinen als eigene Ordner in der Bibliothek).
  List<String> get extraMusicDirs => [
    for (final d in _prefs.getStringList('extraMusicDirs') ?? const <String>[])
      if (!Platform.isAndroid || d.startsWith('content://')) d,
  ];
  Future<void> setExtraMusicDirs(List<String> dirs) async {
    await _prefs.setStringList('extraMusicDirs', dirs);
    notifyListeners();
  }

  /// Ausschlussmuster beim Einlesen (z. B. `*.wav`, `Hörproben`, `Podcasts/Alt`).
  List<String> get excludes => _prefs.getStringList('excludes') ?? const [];
  Future<void> setExcludes(List<String> patterns) async {
    await _prefs.setStringList(
      'excludes',
      patterns.map((p) => p.trim()).where((p) => p.isNotEmpty).toList(),
    );
    notifyListeners();
  }

  String get manifestDb => '$dataDir${Platform.pathSeparator}manifest.db';

  /// Manifest eines weiteren Musikordners (Name aus einem Hash des Pfads).
  String manifestDbFor(String dir) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(dir)) {
      h = (h ^ b) * 0x100000001b3;
    }
    final id = h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
    return '$dataDir${Platform.pathSeparator}manifest-$id.db';
  }

  String get stateFile => '$dataDir${Platform.pathSeparator}state.json';

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

  /// Sync im Heimnetz erlauben (Gerät ist für gekoppelte Geräte erreichbar).
  bool get syncEnabled => _prefs.getBool('syncEnabled') ?? true;
  Future<void> setSyncEnabled(bool v) async {
    await _prefs.setBool('syncEnabled', v);
    notifyListeners();
  }

  /// Regelmäßig nach Updates suchen (beim Start und alle 6 Stunden).
  bool get updateCheck => _prefs.getBool('updateCheck') ?? true;
  Future<void> setUpdateCheck(bool v) async {
    await _prefs.setBool('updateCheck', v);
    notifyListeners();
  }

  /// Updates automatisch herunterladen und installieren.
  bool get autoUpdate => _prefs.getBool('autoUpdate') ?? false;
  Future<void> setAutoUpdate(bool v) async {
    await _prefs.setBool('autoUpdate', v);
    notifyListeners();
  }

  /// Schrittweite beim Spulen in Sekunden.
  int get seekStep => _prefs.getInt('seekStep') ?? 10;
  Future<void> setSeekStep(int s) async {
    await _prefs.setInt('seekStep', s);
    notifyListeners();
  }

  double get speed => _prefs.getDouble('speed') ?? 1.0;
  Future<void> setSpeed(double v) => _prefs.setDouble('speed', v);

  /// Applaus am Anfang/Ende automatisch überspringen.
  bool get autoSkipApplause => _prefs.getBool('autoSkipApplause') ?? false;
  Future<void> setAutoSkipApplause(bool v) async {
    await _prefs.setBool('autoSkipApplause', v);
    notifyListeners();
  }

  /// Visualisierung hinter der Zeitleiste.
  bool get visualizer => _prefs.getBool('visualizer') ?? true;
  Future<void> setVisualizer(bool v) async {
    await _prefs.setBool('visualizer', v);
    notifyListeners();
  }

  /// Zuletzt benutztes Muster für „Nach Tags umbenennen“.
  String get renamePattern =>
      _prefs.getString('renamePattern') ?? '{track} - {title}';
  Future<void> setRenamePattern(String v) =>
      _prefs.setString('renamePattern', v);

  /// Tonhöhe in Halbtönen (unabhängig von der Geschwindigkeit).
  double get pitch => _prefs.getDouble('pitch') ?? 0;
  Future<void> setPitch(double v) => _prefs.setDouble('pitch', v);

  /// Balance: -1 = nur links, 0 = Mitte, 1 = nur rechts.
  double get balance => _prefs.getDouble('balance') ?? 0;
  Future<void> setBalance(double v) => _prefs.setDouble('balance', v);

  /// Überblenden zwischen Titeln in Sekunden (0 = aus).
  int get crossfadeSec => _prefs.getInt('crossfade') ?? 0;
  Future<void> setCrossfadeSec(int v) async {
    await _prefs.setInt('crossfade', v);
    notifyListeners();
  }

  /// Nicht überblenden, wenn beide Titel aus demselben Album stammen.
  bool get crossfadeSkipAlbum => _prefs.getBool('crossfadeSkipAlbum') ?? true;
  Future<void> setCrossfadeSkipAlbum(bool v) async {
    await _prefs.setBool('crossfadeSkipAlbum', v);
    notifyListeners();
  }

  /// Position je Datei merken ab dieser Länge in Minuten (0 = aus).
  int get resumeMinutes => _prefs.getInt('resumeMinutes') ?? 20;
  Future<void> setResumeMinutes(int v) async {
    await _prefs.setInt('resumeMinutes', v);
    notifyListeners();
  }

  /// Aktuelle Bibliotheksansicht (Tab-Index).
  int get libraryTab => _prefs.getInt('libraryTab') ?? 0;
  Future<void> setLibraryTab(int i) => _prefs.setInt('libraryTab', i);

  String get trackSort => _prefs.getString('trackSort') ?? 'title';
  Future<void> setTrackSort(String v) => _prefs.setString('trackSort', v);
}
