// Release-Dateien aus einem privaten Repository laden: Die öffentlichen
// Adressen (github.com/<repo>/releases/download/<tag>/<name>) gehen dort
// nicht. Mit Anmeldung (GithubAuth) wird über die API die Datei gesucht und
// deren Umleitung auf eine signierte Download-Adresse aufgelöst – die
// signierte Adresse braucht keine Anmeldung mehr (und darf auch keine
// bekommen), versteht HTTP-Ranges und gilt etwa eine Stunde.
import 'dart:convert';
import 'dart:io';

import 'github_auth.dart';

class GithubAssets {
  GithubAssets(this.auth, this.client);
  final GithubAuth auth;
  final HttpClient Function() client;

  /// Tag → Dateiname → API-Adresse der Datei.
  final _assets = <String, Map<String, String>>{};

  static final _download = RegExp(
    r'^https?://[^/]+/([^/]+/[^/]+)/releases/download/([^/]+)/(.+)$',
  );

  /// Kopfzeilen für API-Aufrufe (mit Anmeldung, falls vorhanden).
  Map<String, String> get apiHeaders => {
    HttpHeaders.acceptHeader: 'application/vnd.github+json',
    if (auth.token case final t?) HttpHeaders.authorizationHeader: 'Bearer $t',
  };

  /// Merkt sich die Dateien eines schon geladenen Releases (API-Antwort).
  void remember(Map<String, dynamic> release) {
    final tag = release['tag_name'] as String?;
    if (tag == null) return;
    _assets[tag] = {
      for (final a in (release['assets'] as List? ?? const []))
        (a as Map<String, dynamic>)['name'] as String: a['url'] as String,
    };
  }

  Future<Map<String, String>> _load(String repo, String tag) async {
    final c = client();
    try {
      final req = await c.getUrl(
        Uri.parse('${GithubAuth.apiBase}/repos/$repo/releases/tags/$tag'),
      );
      apiHeaders.forEach(req.headers.set);
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      await _check(res.statusCode);
      remember(jsonDecode(body) as Map<String, dynamic>);
      return _assets[tag] ?? const {};
    } finally {
      c.close();
    }
  }

  Future<void> _check(int status) async {
    if (status == 401) {
      await auth.invalidate();
      throw const FormatException('Anmeldung abgelaufen');
    }
    if (status == 404) {
      throw const FormatException('Kein Zugriff auf das Release');
    }
    if (status >= 300 && status < 400) return;
    if (status != 200) throw HttpException('GitHub antwortet $status');
  }

  /// Adresse, unter der [url] ohne weitere Anmeldung geladen werden kann:
  /// ohne Anmeldung (öffentliches Repository) [url] selbst, sonst die
  /// signierte Download-Adresse.
  Future<String> direct(String url) async {
    if (!auth.signedIn) return url;
    final m = _download.firstMatch(url);
    if (m == null) return url;
    final tag = m[2]!;
    final name = Uri.decodeComponent(m[3]!);
    final assets = _assets[tag] ?? await _load(m[1]!, tag);
    final api = assets[name];
    if (api == null) throw FormatException('Datei fehlt im Release: $name');
    final c = client();
    try {
      final req = await c.getUrl(Uri.parse(api))
        ..followRedirects = false;
      req.headers
        ..set(HttpHeaders.acceptHeader, 'application/octet-stream')
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${auth.token}');
      final res = await req.close();
      await res.drain<void>();
      await _check(res.statusCode);
      final loc = res.headers.value(HttpHeaders.locationHeader);
      if (!res.isRedirect || loc == null) {
        throw const HttpException('Keine Download-Adresse von GitHub');
      }
      return Uri.parse(api).resolve(loc).toString();
    } finally {
      c.close();
    }
  }
}
