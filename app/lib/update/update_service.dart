import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/mync_core.dart';
import '../log.dart';
import '../settings.dart';
import 'android_update.dart';
import 'delta.dart';
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
    this.apk,
    this.apkPlan,
  });

  /// Android: Bausteinliste der neuen APK und was davon zu laden ist
  /// (null, wenn die installierte APK nicht zerlegt werden konnte).
  final ChunkManifest? apk;
  final DeltaPlan? apkPlan;

  final String version;
  final String notes;
  final List<UpdateFile> files;

  /// Dateien, die lokal fehlen oder sich geändert haben.
  final List<UpdateFile> missing;
  final bool signed;

  int get downloadBytes => apk != null
      ? (apkPlan?.download ?? apk!.size)
      : missing.fold(0, (a, f) => a + f.gzSize);
  int get fullBytes => apk?.size ?? files.fold(0, (a, f) => a + f.gzSize);

  /// Kurz, was geladen wird (Linux: Dateien, Android: Teil der APK).
  String get summary =>
      '${formatBytes(downloadBytes)} / ${formatBytes(fullBytes)}';
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

  /// Nach Updates suchen: Linux (Teil-Update der Programmdateien) und
  /// Android (Teil-Update der APK, siehe android_update.dart).
  bool get supported => Platform.isLinux || Platform.isAndroid;

  /// Android: installierte Version (aus dem Paket, beim Start gelesen).
  String? _androidVersion;

  /// Von Nix verwaltet (der Wrapper der Flake setzt MYNC_NO_SELF_UPDATE):
  /// Dann nur benachrichtigen – geladene Dateien wären dort nicht lauffähig,
  /// und Nix soll den Stand bestimmen.
  bool get managedByNix =>
      Platform.environment['MYNC_NO_SELF_UPDATE'] != null ||
      Platform.environment['MYNC_PACKAGED'] == 'nix';

  /// Läuft als AppImage (AppRun setzt MYNC_PACKAGED, die AppImage-Laufzeit
  /// APPIMAGE). Das Abbild ist schreibgeschützt; aktualisiert wird die
  /// AppImage-Datei selbst (AppImageUpdate/zsync oder neu herunterladen).
  bool get isAppImage =>
      Platform.environment['MYNC_PACKAGED'] == 'appimage' ||
      Platform.environment['APPIMAGE'] != null;

  /// Selbst installieren (Teil-Update) möglich?
  bool get canInstall => supported && !managedByNix && !isAppImage;

  /// Befehl, mit dem man unter Nix aktualisiert.
  static const nixUpgradeCommand = 'nix profile upgrade --refresh mync';

  /// Seite des neuesten Releases (für AppImage-Nutzer).
  static const releasePage =
      'https://github.com/MrKleeblatt/mync/releases/latest';

  /// Hinweis, wie man aktualisiert, wenn die App es nicht selbst kann.
  String get externalUpdateHint =>
      isAppImage ? 'AppImageUpdate / Gear Lever' : nixUpgradeCommand;

  /// Release-Seite im Browser öffnen.
  Future<void> openReleasePage() async {
    try {
      await Process.start('xdg-open', [
        releasePage,
      ], mode: ProcessStartMode.detached);
    } catch (_) {}
  }

  String get platform => switch (Abi.current()) {
    Abi.linuxArm64 => 'linux-aarch64',
    _ => 'linux-x86_64',
  };

  /// Verzeichnis des laufenden Programms.
  String get bundleDir => File(Platform.resolvedExecutable).parent.path;

  String get currentVersion {
    if (Platform.isAndroid) return _androidVersion ?? '0.0.0';
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
    if (Platform.isAndroid && _androidVersion == null) {
      AndroidApp.version()
          .then((v) {
            _androidVersion = v;
            notifyListeners();
          })
          .catchError((Object e) => logWarning('Version unbekannt: $e'));
    }
    if (Platform.isLinux && canInstall && restartPending) {
      installedVersion = userCurrentVersion;
      _set(
        UpdateState.installed,
        '$installedVersion installiert – Neustart nötig',
      );
    }
    _timer?.cancel();
    if (!settings.updateCheck) return;
    Timer(const Duration(seconds: 15), () => check());
    _timer = Timer.periodic(const Duration(hours: 6), (_) => check());
  }

  void _set(UpdateState s, [String? msg]) {
    if (msg != null && s != UpdateState.error) logInfo('Updates: $msg');
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
    final watch = Stopwatch()..start();
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
      final body = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      logNetwork(
        'GET $url → ${res.statusCode}, ${formatBytes(body.length)} in '
        '${watch.elapsedMilliseconds} ms',
      );
      return body;
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

    final name = Platform.isAndroid
        ? _assetName(rel, (n) => n.endsWith('-android-arm64.apk.chunks.json'))
        : 'update-$platform.json';
    final m = name == null ? null : find(name);
    if (m == null) return null;
    return (m, find('$name.sig'), rel['body'] as String? ?? '');
  }

  static String? _assetName(
    Map<String, dynamic> rel,
    bool Function(String) test,
  ) {
    for (final a in (rel['assets'] as List? ?? const [])) {
      final n = (a as Map<String, dynamic>)['name'] as String;
      if (test(n)) return n;
    }
    return null;
  }

  /// Sucht nach einem Update; bei aktivierter Option wird es gleich installiert.
  Future<void> check({bool manual = false}) async {
    if (!supported ||
        state == UpdateState.checking ||
        state == UpdateState.downloading) {
      return;
    }
    if (state == UpdateState.installed) return;
    _set(UpdateState.checking, 'Suche …');
    try {
      final loc = await _locate();
      if (loc == null) {
        _set(UpdateState.upToDate, 'Kein Release');
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
              throw const FormatException('Signatur ungültig');
            }
          }
        } on HttpException {
          if (signatureRequired) {
            throw const FormatException('Nicht signiert');
          }
        }
      } else if (signatureRequired) {
        throw const FormatException('Nicht signiert');
      }
      final j = jsonDecode(text) as Map<String, dynamic>;
      if (Platform.isAndroid) {
        await _offerApk(j, relNotes, signed);
        return;
      }
      if (j['format'] != 1 || j['platform'] != platform) {
        throw const FormatException('Falsche Plattform');
      }
      final version = j['version'] as String;
      final have = [
        currentVersion,
        if (canInstall) ?userCurrentVersion,
      ].reduce((a, b) => compareVersions(a, b) >= 0 ? a : b);
      if (compareVersions(version, have) <= 0) {
        available = null;
        _set(UpdateState.upToDate, 'Aktuell');
        return;
      }
      final files = [
        for (final f in j['files'] as List)
          UpdateFile.fromJson(f as Map<String, dynamic>),
      ];
      for (final f in files) {
        if (f.path.startsWith('/') || f.path.split('/').contains('..')) {
          throw const FormatException('Ungültiger Pfad');
        }
      }
      final missing = <UpdateFile>[];
      for (final f in canInstall ? files : const <UpdateFile>[]) {
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
      if (!canInstall) {
        _set(UpdateState.available, '$version verfügbar');
        return;
      }
      _set(UpdateState.available, '$version verfügbar');
      if (settings.autoUpdate && !manual) await install();
    } catch (e, st) {
      logError('Update-Prüfung fehlgeschlagen', e, st);
      _set(
        UpdateState.error,
        // eigene Meldungen (Signatur, Plattform) sind kurz genug
        e is FormatException ? e.message : 'Fehlgeschlagen',
      );
    }
  }

  /// Android: neue APK anbieten, mit Größe des Teil-Updates.
  Future<void> _offerApk(
    Map<String, dynamic> j,
    String notes,
    bool signed,
  ) async {
    final m = ChunkManifest.fromJson(j);
    _androidVersion ??= await AndroidApp.version();
    if (compareVersions(m.version, currentVersion) <= 0) {
      available = null;
      _set(UpdateState.upToDate, 'Aktuell');
      return;
    }
    if (await AndroidApp.abi() != 'arm64-v8a') {
      _set(UpdateState.error, 'Nur arm64');
      return;
    }
    DeltaPlan? p;
    try {
      p = plan(m, await chunkFile(await AndroidApp.apkPath()));
    } catch (e, st) {
      logError('Installierte APK nicht zerlegbar – ganze APK nötig', e, st);
    }
    available = UpdateInfo(
      version: m.version,
      notes: notes,
      files: const [],
      missing: const [],
      signed: signed,
      apk: m,
      apkPlan: p,
    );
    logInfo(
      'APK ${m.version}: ${formatBytes(available!.downloadBytes)} von '
      '${formatBytes(m.size)} zu laden',
    );
    _set(UpdateState.available, '${m.version} verfügbar');
  }

  /// Android: neue APK laden (Teil-Update) und den Installer öffnen.
  Future<void> _installApk(UpdateInfo info) async {
    _set(UpdateState.downloading, 'Vorbereiten …');
    progress = 0;
    try {
      final path = await prepareApk(
        manifest: info.apk!,
        plan: info.apkPlan,
        installedApk: await AndroidApp.apkPath(),
        dir: await AndroidApp.updateDir(),
        client: _client,
        report: (f, text) {
          progress = f.clamp(0, 1);
          message = '$text · ${(progress * 100).round()} %';
          notifyListeners();
        },
      );
      if (!await AndroidApp.canInstall()) {
        await AndroidApp.openInstallSettings();
        _set(
          UpdateState.available,
          '„Apps aus dieser Quelle zulassen“, dann erneut installieren',
        );
        return;
      }
      await AndroidApp.install(path);
      _set(UpdateState.available, 'Installer geöffnet');
    } catch (e, st) {
      logError('Update fehlgeschlagen', e, st);
      _set(
        UpdateState.error,
        e is FormatException ? e.message : 'Fehlgeschlagen',
      );
    }
  }

  /// Lädt die fehlenden Dateien, prüft alles und schaltet auf die neue Version um.
  Future<void> install() async {
    final info = available;
    if (Platform.isAndroid) {
      if (info?.apk != null && state != UpdateState.downloading) {
        await _installApk(info!);
      }
      return;
    }
    if (info == null || state == UpdateState.downloading || !canInstall) {
      return;
    }
    _set(UpdateState.downloading, 'Lade …');
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
          throw FormatException('Prüfsumme falsch');
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
        '${info.version} installiert – Neustart nötig',
      );
    } catch (e, st) {
      logError('Update-Installation fehlgeschlagen', e, st);
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {}
      _set(
        UpdateState.error,
        e is FormatException ? e.message : 'Fehlgeschlagen',
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
