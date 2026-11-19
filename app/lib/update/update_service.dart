import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/mync_core.dart';
import '../settings.dart';
import 'update_key.dart';

/// Eine Datei des Programms laut Update-Manifest.
class UpdateFile {
  UpdateFile.fromJson(Map<String, dynamic> j)
    : path = j['path'] as String,
      sha256 = j['sha256'] as String,
      size = j['size'] as int,
      mode = j['mode'] as int? ?? 420,
      url = j['url'] as String,
      gzSize = j['gz_size'] as int;

  final String path;
  final String sha256;
  final int size;
  final int mode;
  final String url;
  final int gzSize;
}

/// Ein verfügbares Update.
class UpdateInfo {
  UpdateInfo({
    required this.version,
    required this.notes,
    required this.files,
    required this.missing,
    required this.signed,
  });

  final String version;
  final String notes;
  final List<UpdateFile> files;

  /// Dateien, die lokal fehlen oder sich geändert haben.
  final List<UpdateFile> missing;
  final bool signed;

  int get downloadBytes => missing.fold(0, (a, f) => a + f.gzSize);
  int get fullBytes => files.fold(0, (a, f) => a + f.gzSize);
}

enum UpdateState {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  installed,
  error,
}

/// Vergleicht Versionen „1.2.3“ (ohne Vorabversionen-Feinheiten).
int compareVersions(String a, String b) {
  List<int> parts(String v) =>
      v
          .split(RegExp(r'[.+-]'))
          .take(3)
          .map((p) => int.tryParse(p) ?? 0)
          .toList()
        ..addAll(List.filled(3, 0));
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i].compareTo(y[i]);
  }
  return 0;
}

/// Teil-Updates über GitHub-Releases.
///
/// Ablauf: Manifest des neuesten Releases laden und (falls ein Schlüssel
/// eingebaut ist) die Ed25519-Signatur prüfen → Dateien mit den installierten
/// vergleichen (SHA-256) → nur fehlende/geänderte Dateien laden → alles prüfen
/// → als `~/.local/share/mync/versions/<version>` ablegen und den Symlink
/// `~/.local/share/mync/current` atomar umstellen. Das Startskript `mync`
/// startet die neueste vorhandene Version; die alte bleibt als Rückfall.
class UpdateService extends ChangeNotifier {
  UpdateService(this.settings, {this.beforeRestart});

  /// Die eine Instanz der App (in main gesetzt).
  static UpdateService? instance;

  final AppSettings settings;

  /// Wird vor dem Neustart aufgerufen (z. B. Wiedergabestand sichern).
  final Future<void> Function()? beforeRestart;

  static const repo = 'mrkleeblatt/mync';

  UpdateState state = UpdateState.idle;
  String? message;
  UpdateInfo? available;
  double progress = 0;
  String? installedVersion;
  Timer? _timer;

  /// Nur Linux-Desktop (auf Android aktualisiert man über die APK).
  bool get supported => Platform.isLinux;

  String get platform => switch (Abi.current()) {
    Abi.linuxArm64 => 'linux-aarch64',
    _ => 'linux-x86_64',
  };

  /// Verzeichnis des laufenden Programms.
  String get bundleDir => File(Platform.resolvedExecutable).parent.path;

  String get currentVersion {
    try {
      return File('$bundleDir/VERSION').readAsStringSync().trim();
    } catch (_) {
      return '0.0.0';
    }
  }

  Directory get userRoot {
    final xdg = Platform.environment['XDG_DATA_HOME'];
    final base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : '${Platform.environment['HOME']}/.local/share';
    return Directory('$base/mync');
  }

  bool get signatureRequired => updatePublicKey.isNotEmpty;

  /// Version unter ~/.local/share/mync/current (bereits installiert, evtl. noch nicht gestartet).
  String? get userCurrentVersion {
    try {
      return File('${userRoot.path}/current/VERSION').readAsStringSync().trim();
    } catch (_) {
      return null;
    }
  }

  /// Eine neuere Version ist installiert, läuft aber noch nicht.
  bool get restartPending {
    final u = userCurrentVersion;
    return u != null &&
        compareVersions(u, currentVersion) > 0 &&
        File('${userRoot.path}/current/mync').existsSync();
  }

  void start() {
    if (!supported) return;
    if (restartPending) {
      installedVersion = userCurrentVersion;
      _set(
        UpdateState.installed,
        'Version $installedVersion ist installiert – aktiv nach dem Neustart.',
      );
    }
    _timer?.cancel();
    if (!settings.updateCheck) return;
    Timer(const Duration(seconds: 15), () => check());
    _timer = Timer.periodic(const Duration(hours: 6), (_) => check());
  }

  void _set(UpdateState s, [String? msg]) {
    state = s;
    message = msg;
    notifyListeners();
  }

  HttpClient _client() => HttpClient()
    ..findProxy = HttpClient.findProxyFromEnvironment
    ..userAgent = 'mync-updater'
    ..connectionTimeout = const Duration(seconds: 20);

  Future<List<int>> _get(String url) async {
    final c = _client();
    try {
      final req = await c.getUrl(Uri.parse(url));
      req.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json, application/json, */*',
      );
      final res = await req.close();
      if (res.statusCode == 404) {
        throw const HttpException('nicht gefunden (404)');
      }
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      return await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    } finally {
      c.close();
    }
  }

  /// Adressen von Manifest und Signatur (+ Release-Notizen).
  Future<(String manifest, String? sig, String notes)?> _locate() async {
    final override = Platform.environment['MYNC_UPDATE_URL'];
    if (override != null && override.isNotEmpty) {
      return (override, '$override.sig', '');
    }
    final List<int> body;
    try {
      body = await _get('https://api.github.com/repos/$repo/releases/latest');
    } on HttpException catch (e) {
      if (e.message.contains('404')) return null; // noch kein Release
      rethrow;
    }
    final rel = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    String? find(String name) {
      for (final a in (rel['assets'] as List? ?? const [])) {
        final m = a as Map<String, dynamic>;
        if (m['name'] == name) return m['browser_download_url'] as String?;
      }
      return null;
    }

    final m = find('update-$platform.json');
    if (m == null) return null;
    return (m, find('update-$platform.json.sig'), rel['body'] as String? ?? '');
  }

  /// Sucht nach einem Update; bei aktivierter Option wird es gleich installiert.
  Future<void> check({bool manual = false}) async {
    if (!supported ||
        state == UpdateState.checking ||
        state == UpdateState.downloading) {
      return;
    }
    if (state == UpdateState.installed) return;
    _set(UpdateState.checking, 'Suche nach Updates …');
    try {
      final loc = await _locate();
      if (loc == null) {
        _set(
          UpdateState.upToDate,
          'Noch kein Release mit Update-Dateien veröffentlicht.',
        );
        return;
      }
      final (murl, surl, relNotes) = loc;
      final raw = await _get(murl);
      final text = utf8.decode(raw);
      var signed = false;
      if (surl != null) {
        try {
          final sig = utf8.decode(await _get(surl)).trim();
          if (signatureRequired) {
            signed = await verifyEd25519(updatePublicKey, text, sig);
            if (!signed) {
              throw const FormatException(
                'Signatur des Updates ist ungültig – Update abgelehnt.',
              );
            }
          }
        } on HttpException {
          if (signatureRequired) {
            throw const FormatException(
              'Update ist nicht signiert – abgelehnt.',
            );
          }
        }
      } else if (signatureRequired) {
        throw const FormatException('Update ist nicht signiert – abgelehnt.');
      }
      final j = jsonDecode(text) as Map<String, dynamic>;
      if (j['format'] != 1 || j['platform'] != platform) {
        throw const FormatException(
          'Manifest passt nicht zu dieser Plattform.',
        );
      }
      final version = j['version'] as String;
      final have = [
        currentVersion,
        ?userCurrentVersion,
      ].reduce((a, b) => compareVersions(a, b) >= 0 ? a : b);
      if (compareVersions(version, have) <= 0) {
        available = null;
        _set(UpdateState.upToDate, 'mync $currentVersion ist aktuell.');
        return;
      }
      final files = [
        for (final f in j['files'] as List)
          UpdateFile.fromJson(f as Map<String, dynamic>),
      ];
      for (final f in files) {
        if (f.path.startsWith('/') || f.path.split('/').contains('..')) {
          throw const FormatException('Ungültiger Pfad im Manifest.');
        }
      }
      final missing = <UpdateFile>[];
      for (final f in files) {
        final local = File('$bundleDir/${f.path}');
        if (!await local.exists() ||
            await local.length() != f.size ||
            await sha256File(local.path) != f.sha256) {
          missing.add(f);
        }
      }
      final notes = (j['notes'] as String? ?? '').isNotEmpty
          ? j['notes'] as String
          : relNotes;
      available = UpdateInfo(
        version: version,
        notes: notes,
        files: files,
        missing: missing,
        signed: signed,
      );
      _set(UpdateState.available, 'Version $version verfügbar.');
      if (settings.autoUpdate && !manual) await install();
    } catch (e) {
      _set(
        UpdateState.error,
        'Update-Prüfung fehlgeschlagen: ${e is FormatException ? e.message : e}',
      );
    }
  }

  /// Lädt die fehlenden Dateien, prüft alles und schaltet auf die neue Version um.
  Future<void> install() async {
    final info = available;
    if (info == null || state == UpdateState.downloading) return;
    _set(UpdateState.downloading, 'Lade ${info.missing.length} Datei(en) …');
    progress = 0;
    final versions = Directory('${userRoot.path}/versions');
    final staging = Directory('${versions.path}/${info.version}.partial');
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      final missing = {for (final f in info.missing) f.path};
      var done = 0;
      final total = info.downloadBytes == 0 ? 1 : info.downloadBytes;
      for (final f in info.files) {
        final dst = File('${staging.path}/${f.path}');
        await dst.parent.create(recursive: true);
        if (missing.contains(f.path)) {
          await _download(f, dst);
          done += f.gzSize;
          progress = done / total;
          notifyListeners();
        } else {
          await File('$bundleDir/${f.path}').copy(dst.path);
        }
        if (await sha256File(dst.path) != f.sha256) {
          throw FormatException('Prüfsumme falsch: ${f.path}');
        }
        if (f.mode & 0x49 != 0) await Process.run('chmod', ['755', dst.path]);
      }
      // Verzeichnis fertigstellen und Symlink atomar umstellen
      final target = Directory('${versions.path}/${info.version}');
      if (await target.exists()) await target.delete(recursive: true);
      await staging.rename(target.path);
      final tmp = Link('${userRoot.path}/current.tmp');
      if (await tmp.exists()) await tmp.delete();
      await tmp.create(target.path);
      await tmp.rename('${userRoot.path}/current');
      await _cleanup(versions, keep: {info.version, _versionOf(bundleDir)});
      installedVersion = info.version;
      available = null;
      _set(
        UpdateState.installed,
        'Version ${info.version} installiert – aktiv nach dem Neustart.',
      );
    } catch (e) {
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {}
      _set(
        UpdateState.error,
        'Update fehlgeschlagen: ${e is FormatException ? e.message : e}',
      );
    }
  }

  Future<void> _download(UpdateFile f, File dst) async {
    final c = _client();
    try {
      final req = await c.getUrl(Uri.parse(f.url));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode} für ${f.path}');
      }
      final sink = dst.openWrite();
      await res.transform(gzip.decoder).pipe(sink);
    } finally {
      c.close();
    }
  }

  static String? _versionOf(String dir) {
    final name = dir.split('/').last;
    return RegExp(r'^\d+\.\d+\.\d+').hasMatch(name) ? name : null;
  }

  /// Behält die neue und die laufende Version, löscht ältere.
  Future<void> _cleanup(
    Directory versions, {
    required Set<String?> keep,
  }) async {
    await for (final e in versions.list()) {
      final name = e.path.split('/').last;
      if (e is Directory &&
          !keep.contains(name) &&
          !name.endsWith('.partial')) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Startet die neu installierte Version und beendet diese.
  Future<void> restart() async {
    final exe = '${userRoot.path}/current/mync';
    if (!await File(exe).exists()) return;
    await beforeRestart?.call();
    await Process.start(exe, const [], mode: ProcessStartMode.detached);
    exit(0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

String formatBytes(int b) {
  if (b >= 1e6) {
    return '${(b / 1e6).toStringAsFixed(1).replaceAll('.', ',')} MB';
  }
  if (b >= 1e3) return '${(b / 1e3).toStringAsFixed(0)} kB';
  return '$b B';
}
