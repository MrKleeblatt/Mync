// Anmeldung bei GitHub für Updates aus einem privaten Repository.
//
// Device Flow (wie `gh auth login`): mync zeigt einen kurzen Code, man gibt
// ihn auf github.com/login/device ein und bestätigt – ein Passwort sieht
// mync nie, und in der App steckt kein Geheimnis (nur die öffentliche
// Client-ID).
//
// Die Client-ID gehört zu einer GitHub-App mit dem einzigen Recht
// „Contents: Read-only“, installiert nur auf dem mync-Repository. Das
// Token kann also nur Releases lesen – nicht das übrige Konto. Ablauf der
// Tokens in der GitHub-App abschalten („Expire user authorization tokens“),
// sonst bräuchte das Erneuern das Client-Secret.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../log.dart';

/// Client-ID der GitHub-App (öffentlich, beim Bauen gesetzt).
const githubClientId = String.fromEnvironment('MYNC_GITHUB_CLIENT_ID');

/// Laufende Anmeldung: Code, den man auf [verificationUri] eingibt.
class DeviceLogin {
  DeviceLogin(this.userCode, this.verificationUri, this.expires);
  final String userCode;
  final String verificationUri;
  final DateTime expires;
}

class GithubAuth extends ChangeNotifier {
  GithubAuth(this.dataDir, {this.clientId = githubClientId});

  final String dataDir;
  final String clientId;

  /// Server (in Tests ersetzt).
  static String loginBase = 'https://github.com';
  static String apiBase = 'https://api.github.com';

  String? _token;
  String? login;

  /// Laufende Anmeldung (Code anzeigen), sonst null.
  DeviceLogin? pending;
  String? error;
  bool _cancel = false;

  String? get token => _token;
  bool get signedIn => _token != null;
  bool get available => clientId.isNotEmpty;

  File get _file => File('$dataDir/github.json');

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      _token = j['token'] as String?;
      login = j['login'] as String?;
      notifyListeners();
    } catch (e) {
      logWarning('GitHub-Anmeldung nicht lesbar: $e');
    }
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode({'token': _token, 'login': login}));
    if (Platform.isLinux || Platform.isMacOS) {
      await Process.run('chmod', ['600', _file.path]); // nur für mich lesbar
    }
  }

  Future<void> signOut() async {
    _token = null;
    login = null;
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {}
    logInfo('GitHub: abgemeldet');
    notifyListeners();
  }

  /// Token ungültig (401): vergessen, damit man sich neu anmeldet.
  Future<void> invalidate() async {
    logWarning('GitHub: Anmeldung ungültig – bitte neu anmelden');
    await signOut();
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, String> form,
  ) async {
    final c = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
    try {
      final req = await c.postUrl(Uri.parse('$loginBase$path'));
      req.headers
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..contentType = ContentType('application', 'x-www-form-urlencoded');
      req.write(Uri(queryParameters: form).query);
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw HttpException('GitHub antwortet ${res.statusCode}');
      }
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      c.close();
    }
  }

  /// Startet die Anmeldung; [pending] zeigt den Code. Wartet, bis man auf
  /// github.com bestätigt hat (true), abgebrochen oder abgelaufen ist.
  Future<bool> signIn() async {
    if (!available) {
      error = 'Keine GitHub-App eingerichtet';
      notifyListeners();
      return false;
    }
    _cancel = false;
    error = null;
    try {
      final d = await _post('/login/device/code', {'client_id': clientId});
      var interval = (d['interval'] as num?)?.toInt() ?? 5;
      pending = DeviceLogin(
        d['user_code'] as String,
        d['verification_uri'] as String,
        DateTime.now().add(Duration(seconds: (d['expires_in'] as num).toInt())),
      );
      notifyListeners();
      logInfo('GitHub: Anmeldung gestartet');
      while (!_cancel && DateTime.now().isBefore(pending!.expires)) {
        await Future<void>.delayed(Duration(seconds: interval));
        if (_cancel) break;
        final r = await _post('/login/oauth/access_token', {
          'client_id': clientId,
          'device_code': d['device_code'] as String,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        });
        final token = r['access_token'] as String?;
        if (token != null) {
          _token = token;
          login = await _whoAmI(token);
          await _save();
          logInfo('GitHub: angemeldet als ${login ?? '?'}');
          return true;
        }
        switch (r['error']) {
          case 'authorization_pending':
            continue;
          case 'slow_down':
            interval += 5;
          case 'access_denied':
            error = 'Abgelehnt';
            return false;
          case 'expired_token':
            error = 'Code abgelaufen';
            return false;
          default:
            throw HttpException('${r['error']}: ${r['error_description']}');
        }
      }
      if (!_cancel) error = 'Code abgelaufen';
      return false;
    } catch (e, st) {
      logError('GitHub-Anmeldung fehlgeschlagen', e, st);
      error = 'Anmeldung fehlgeschlagen';
      return false;
    } finally {
      pending = null;
      notifyListeners();
    }
  }

  void cancel() => _cancel = true;

  Future<String?> _whoAmI(String token) async {
    final c = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
    try {
      final req = await c.getUrl(Uri.parse('$apiBase/user'));
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'mync-updater');
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      return (jsonDecode(body) as Map<String, dynamic>)['login'] as String?;
    } catch (_) {
      return null;
    } finally {
      c.close();
    }
  }
}
