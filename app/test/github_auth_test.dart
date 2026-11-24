// Anmeldung bei GitHub (Device Flow) und Laden aus einem privaten Release,
// gegen einen lokalen Server, der sich wie GitHub verhält.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/update/android_update.dart';
import 'package:mync/update/github_assets.dart';
import 'package:mync/update/github_auth.dart';

void main() {
  late HttpServer server;
  late Directory tmp;
  late String base;
  final apk = Uint8List.fromList(List.generate(50000, (i) => i * 7 % 256));
  var polls = 0;
  var token = 'gho_gut';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mync_gh');
    polls = 0;
    token = 'gho_gut';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    GithubAuth.loginBase = base;
    GithubAuth.apiBase = '$base/api';
    server.listen((req) async {
      final res = req.response;
      final auth = req.headers.value(HttpHeaders.authorizationHeader);
      final ok = auth == 'Bearer $token';
      void json(Object o) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(o));
      }

      final release = {
        'tag_name': 'v9.9.9',
        'assets': [
          {
            'name': 'mync-v9.9.9-android-arm64.apk',
            'url': '$base/api/repos/me/mync/releases/assets/7',
            'browser_download_url':
                '$base/me/mync/releases/download/v9.9.9/mync-v9.9.9-android-arm64.apk',
          },
        ],
      };
      switch (req.uri.path) {
        case '/login/device/code':
          json({
            'device_code': 'dev',
            'user_code': 'ABCD-1234',
            'verification_uri': '$base/login/device',
            'expires_in': 60,
            'interval': 0,
          });
        case '/login/oauth/access_token':
          json(
            ++polls < 2
                ? {'error': 'authorization_pending'}
                : {'access_token': 'gho_gut'},
          );
        case '/api/user':
          json({'login': 'mrkleeblatt'});
        case '/api/repos/me/mync/releases/tags/v9.9.9':
          // privat: ohne Anmeldung „gibt es nicht“
          if (ok) {
            json(release);
          } else {
            res.statusCode = auth == null ? 404 : 401;
          }
        case '/api/repos/me/mync/releases/assets/7':
          if (ok &&
              req.headers.value(HttpHeaders.acceptHeader) ==
                  'application/octet-stream') {
            res.statusCode = HttpStatus.found;
            res.headers.set(HttpHeaders.locationHeader, '/signed/apk?sig=x');
          } else {
            res.statusCode = 404;
          }
        case '/signed/apk':
          // signierte Adresse: Anmeldung dort ist ein Fehler (wie bei GitHub)
          if (auth != null) {
            res.statusCode = 400;
            break;
          }
          final range = req.headers.value(HttpHeaders.rangeHeader);
          if (range == null) {
            res.add(apk);
          } else {
            final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
            final a = int.parse(m[1]!), b = int.parse(m[2]!);
            res.statusCode = HttpStatus.partialContent;
            res.add(Uint8List.sublistView(apk, a, b + 1));
          }
        default:
          res.statusCode = 404;
      }
      await res.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  test('Anmelden mit Code, Token bleibt gespeichert', () async {
    final a = GithubAuth(tmp.path, clientId: 'Iv1.test');
    expect(a.available, isTrue);
    final codes = <String>[];
    a.addListener(() {
      if (a.pending != null) codes.add(a.pending!.userCode);
    });
    expect(await a.signIn(), isTrue);
    expect(codes, contains('ABCD-1234'));
    expect(polls, 2); // erst „noch nicht bestätigt“, dann das Token
    expect(a.login, 'mrkleeblatt');
    final again = GithubAuth(tmp.path, clientId: 'Iv1.test');
    await again.load();
    expect(again.token, 'gho_gut');
    await again.signOut();
    expect(File('${tmp.path}/github.json').existsSync(), isFalse);
  });

  test('Ohne Client-ID keine Anmeldung', () async {
    final a = GithubAuth(tmp.path, clientId: '');
    expect(a.available, isFalse);
    expect(await a.signIn(), isFalse);
  });

  test('Privates Release: über die API zur signierten Adresse, Ranges', () async {
    final a = GithubAuth(tmp.path, clientId: 'Iv1.test');
    final url =
        '$base/me/mync/releases/download/v9.9.9/mync-v9.9.9-android-arm64.apk';
    final assets = GithubAssets(a, HttpClient.new);
    // ohne Anmeldung bleibt die Adresse, wie sie ist (öffentliches Repo)
    expect(await assets.direct(url), url);
    await a.signIn();
    final direct = await assets.direct(url);
    expect(direct, '$base/signed/apk?sig=x');
    final parts = await RangeLoader(
      HttpClient.new,
      url,
      resolve: () => assets.direct(url),
    ).load([(0, 10), (40000, 100)]);
    expect(parts[0], apk.sublist(0, 10));
    expect(parts[40000], apk.sublist(40000, 40100));
  });

  test('Ungültiges Token: abgemeldet, klare Meldung', () async {
    final a = GithubAuth(tmp.path, clientId: 'Iv1.test');
    await a.signIn();
    token = 'gho_neu'; // auf GitHub widerrufen
    final assets = GithubAssets(a, HttpClient.new);
    await expectLater(
      assets.direct(
        '$base/me/mync/releases/download/v9.9.9/mync-v9.9.9-android-arm64.apk',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Anmeldung abgelaufen',
        ),
      ),
    );
    expect(a.signedIn, isFalse);
  });
}
