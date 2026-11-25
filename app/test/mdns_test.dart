import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/sync/mdns.dart';

void main() {
  test('DNS: Antwort hin und zurück (PTR, SRV, TXT, A)', () {
    final b = encodeResponse(
      id: 7,
      service: '_mync._tcp.local',
      instance: 'mync-ab12._mync._tcp.local',
      host: 'mync-ab12.local',
      port: 47788,
      txt: {'id': 'ab12', 'name': 'Galaxy S23 von Max', 'pair': '0'},
      ips: ['192.168.1.20', '10.0.0.5'],
      withQuestion: true,
    );
    final m = DnsMessage.decode(b);
    expect(m.isResponse, isTrue);
    expect(m.id, 7);
    expect(m.questions.single.name, '_mync._tcp.local');
    final f = m.found('_mync._tcp.local', '10.0.0.5')!;
    expect(f.host, '10.0.0.5'); // Absender ist eine der Adressen
    expect(f.port, 47788);
    expect(f.txt['name'], 'Galaxy S23 von Max');
    // Absender unbekannt: erste A-Adresse
    expect(m.found('_mync._tcp.local', '172.16.0.1')!.host, '192.168.1.20');
    expect(m.found('_other._tcp.local', '10.0.0.5'), isNull);
  });

  test('DNS: Anfrage und komprimierte Namen', () {
    final q = DnsMessage.decode(encodeQuery('_mync._tcp.local', id: 3));
    expect(q.isResponse, isFalse);
    expect(q.questions.single.type, 12);
    final m = DnsMessage.decode(
      Uint8ListHelper.of([
        0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, //
        1, 'x'.codeUnitAt(0), 5, ...'local'.codeUnits, 0, 0, 1, 0, 1, //
        0, 0, 0, 120, 0, 4, 10, 1, 2, 3,
      ]),
    );
    expect(m.records.single.name, 'x.local');
    expect(m.records.single.data, '10.1.2.3');
    final p = DnsMessage.decode(
      Uint8ListHelper.of([
        0, 0, 0x84, 0, 0, 0, 0, 2, 0, 0, 0, 0, //
        1, 'x'.codeUnitAt(0), 5, ...'local'.codeUnits, 0, 0, 1, 0, 1, //
        0, 0, 0, 120, 0, 4, 10, 1, 2, 3, //
        1, 'y'.codeUnitAt(0), 0xC0, 14, 0, 1, 0, 1, 0, 0, 0, 120, 0, 4, //
        10, 1, 2, 4,
      ]),
    );
    expect(p.records[1].name, 'y.local');
  });

  test(
    'Suche findet ein bekannt gemachtes Gerät (Multicast, Loopback)',
    () async {
      final a = DartMdns(port: 45354);
      final b = DartMdns(port: 45354);
      await a.advertise(
        instance: 'mync-test',
        port: 1234,
        txt: {'mync': '1', 'id': 'test'},
      );
      final found = await b
          .browse(timeout: const Duration(seconds: 3))
          .firstWhere((f) => f.txt['id'] == 'test')
          .timeout(const Duration(seconds: 4));
      expect(found.port, 1234);
      await a.stopAdvertising();
    },
  );
}

abstract final class Uint8ListHelper {
  static Uint8List of(List<int> b) => Uint8List.fromList(b);
}
