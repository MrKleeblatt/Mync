// Updates der Android-App, wie Kassenbon (app/lib/platform/installer_io.dart):
// installierte APK in Bausteine zerlegen, nur die fehlenden von GitHub laden,
// neue APK zusammensetzen, prüfen und dem Paketinstaller übergeben. Klappt das
// Teil-Update nicht, wird die ganze APK geladen.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../core/mync_core.dart';
import '../log.dart';
import 'delta.dart';

/// Kanal „mync/app“ (AppUpdate.kt).
abstract final class AndroidApp {
  static const _ch = MethodChannel('mync/app');

  /// Installierte Version (versionName, z. B. „0.7.0“).
  static Future<String> version() async =>
      await _ch.invokeMethod<String>('version') ?? '0.0.0';

  /// Pfad der installierten APK (ohne Berechtigung lesbar).
  static Future<String> apkPath() async =>
      (await _ch.invokeMethod<String>('apkPath'))!;

  /// Ablage für geladene APKs (für den FileProvider freigegeben).
  static Future<String> updateDir() async =>
      (await _ch.invokeMethod<String>('updateDir'))!;

  /// Darf mync Apps installieren („Apps aus dieser Quelle zulassen“)?
  static Future<bool> canInstall() async =>
      await _ch.invokeMethod<bool>('canInstall') ?? true;

  static Future<void> openInstallSettings() =>
      _ch.invokeMethod('openInstallSettings');

  /// Öffnet den Paketinstaller für die APK [path].
  static Future<void> install(String path) =>
      _ch.invokeMethod('install', {'path': path});

  /// Hauptarchitektur, z. B. „arm64-v8a“.
  static Future<String?> abi() => _ch.invokeMethod<String>('abi');
}

/// Lädt Teile einer Datei von GitHub: einzelne HTTP-Ranges (GitHub liefert
/// keine Mehrfachbereiche), höchstens [parallel] gleichzeitig. Die
/// Release-URL leitet auf eine signierte Adresse um (≈ 1 h gültig); sie
/// wird einmal aufgelöst und bei Ablauf neu geholt.
class RangeLoader {
  RangeLoader(this.client, this.url, {this.parallel = 4, this.resolve});
  final HttpClient Function() client;
  final String url;
  final int parallel;

  /// Liefert die direkte Download-Adresse (privates Repository: über die
  /// API mit Anmeldung, siehe GithubAssets); sonst wird die Umleitung von
  /// [url] aufgelöst.
  final Future<String> Function()? resolve;
  String? _resolved;

  Future<String> _resolve() async {
    if (resolve != null) return resolve!();
    final c = client();
    try {
      final req = await c.getUrl(Uri.parse(url))
        ..followRedirects = false
        ..headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final res = await req.close();
      await res.drain<void>();
      final loc = res.headers.value(HttpHeaders.locationHeader);
      return res.isRedirect && loc != null
          ? Uri.parse(url).resolve(loc).toString()
          : url;
    } finally {
      c.close();
    }
  }

  Future<Uint8List> _range(int start, int len, {bool retried = false}) async {
    final target = _resolved ??= await _resolve();
    final c = client();
    try {
      final req = await c.getUrl(Uri.parse(target))
        ..headers.set(
          HttpHeaders.rangeHeader,
          'bytes=$start-${start + len - 1}',
        );
      final res = await req.close();
      if ((res.statusCode == 401 || res.statusCode == 403) && !retried) {
        await res.drain<void>();
        _resolved = null; // signierte Adresse abgelaufen
        return await _range(start, len, retried: true);
      }
      if (res.statusCode != 206) {
        await res.drain<void>();
        throw HttpException('Bereichsanfrage: HTTP ${res.statusCode}');
      }
      final b = BytesBuilder(copy: false);
      await for (final part in res) {
        b.add(part);
      }
      final data = b.takeBytes();
      if (data.length != len) {
        throw HttpException('Bereich unvollständig: ${data.length} von $len');
      }
      return data;
    } finally {
      c.close();
    }
  }

  /// Lädt alle [ranges] (Anfang, Länge); [onBytes] meldet den Fortschritt.
  Future<Map<int, Uint8List>> load(
    List<(int, int)> ranges, {
    void Function(int bytes)? onBytes,
  }) async {
    final out = <int, Uint8List>{};
    var next = 0;
    Future<void> worker() async {
      while (next < ranges.length) {
        final (start, len) = ranges[next++];
        out[start] = await _range(start, len);
        onBytes?.call(len);
      }
    }

    await Future.wait([
      for (var i = 0; i < parallel && i < ranges.length; i++) worker(),
    ]);
    return out;
  }
}

/// Lädt [url] ganz nach [path] (Rückfall, wenn das Teil-Update nicht geht).
Future<void> downloadWhole(
  HttpClient Function() client,
  String url,
  String path, {
  void Function(int bytes)? onBytes,
}) async {
  final c = client();
  try {
    final res = await (await c.getUrl(Uri.parse(url))).close();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final sink = File(path).openWrite();
    try {
      await for (final part in res) {
        sink.add(part);
        onBytes?.call(part.length);
      }
    } finally {
      await sink.close();
    }
  } finally {
    c.close();
  }
}

/// Bereitet die neue APK vor: zuerst als Teil-Update aus der installierten
/// APK, sonst ganz. Liefert den Pfad der geprüften APK.
Future<String> prepareApk({
  required ChunkManifest manifest,
  required DeltaPlan? plan,
  required String installedApk,
  required String dir,
  required HttpClient Function() client,
  required void Function(double fraction, String text) report,
  Future<String> Function(String url)? direct,
}) async {
  final out = '$dir/${manifest.name}';
  // schon geladen (z. B. Installer vorhin abgebrochen)?
  if (await _valid(out, manifest)) return out;
  for (final f in Directory(dir).listSync().whereType<File>()) {
    try {
      f.deleteSync();
    } catch (_) {}
  }
  final part = '$out.part';
  if (plan != null) {
    try {
      final total = plan.download;
      var done = 0;
      final info = '${_mb(total)} / ${_mb(manifest.size)}';
      report(0, info);
      final fetched =
          await RangeLoader(
            client,
            manifest.url,
            resolve: direct == null ? null : () => direct(manifest.url),
          ).load(
            plan.ranges,
            onBytes: (n) => report(total == 0 ? 1 : (done += n) / total, info),
          );
      await assemble(plan, installedApk, fetched, part);
      if (!await _valid(part, manifest)) {
        throw const FormatException('Prüfsumme falsch');
      }
      await File(part).rename(out);
      logInfo('Teil-Update: ${_mb(total)} von ${_mb(manifest.size)} geladen');
      return out;
    } catch (e, st) {
      logError('Teil-Update nicht möglich – lade die ganze APK', e, st);
    }
  }
  var done = 0;
  final info = _mb(manifest.size);
  report(0, info);
  await downloadWhole(
    client,
    direct == null ? manifest.url : await direct(manifest.url),
    part,
    onBytes: (n) => report((done += n) / manifest.size, info),
  );
  if (!await _valid(part, manifest)) {
    throw const FormatException('Prüfsumme falsch');
  }
  await File(part).rename(out);
  return out;
}

Future<bool> _valid(String path, ChunkManifest m) async {
  final f = File(path);
  return await f.exists() &&
      await f.length() == m.size &&
      await sha256File(path) == m.sha256;
}

String _mb(int b) => '${(b / 1e6).toStringAsFixed(1).replaceAll('.', ',')} MB';
