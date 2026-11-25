import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/sync/discovery.dart';

void main() {
  test(
    'Netze: Größe begrenzt, Broadcast, Nachbarn aus dem eigenen /24 zuerst',
    () {
      expect(scanNetLabel('192.168.1.23/24'), '192.168.1.0/24');
      expect(scanNetLabel('10.1.2.3/8'), '10.1.0.0/22'); // auf /22 begrenzt
      expect(scanNetLabel('192.168.43.1'), '192.168.43.0/24'); // ohne Länge
      expect(broadcastOf('192.168.1.23/24'), '192.168.1.255');
      expect(broadcastOf('172.16.105.7/22'), '172.16.107.255');
      final n = neighbours(['172.16.105.7/22']);
      expect(n, hasLength(1021));
      expect(n, isNot(contains('172.16.105.7')));
      expect(n.first, startsWith('172.16.105.'));
      expect(isPrivateIpv4('192.168.0.1'), isTrue);
      expect(isPrivateIpv4('172.32.0.1'), isFalse);
      expect(isPrivateIpv4('8.8.8.8'), isFalse);
    },
  );

  test('Suche fragt jede Adresse an und meldet Antworten', () async {
    final responder = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    var queries = 0;
    responder.listen((ev) {
      final d = responder.receive();
      if (d == null || utf8.decode(d.data) != discoveryQuery) return;
      queries++;
      responder.send(
        utf8.encode(jsonEncode({'mync': 1, 'id': 'x'})),
        d.address,
        d.port,
      );
    });
    List<String>? nets;
    final replies = await queryNetwork(
      port: responder.port,
      timeout: const Duration(milliseconds: 1500),
      addresses: () async => ['127.0.0.5/30'],
      onSubnets: (n) => nets = n,
    ).toList();
    responder.close();
    expect(nets, ['127.0.0.4/30']);
    expect(replies, isNotEmpty);
    expect(replies.first.host, '127.0.0.1');
    expect(replies.first.data['id'], 'x');
    // zwei Runden → mindestens zweimal gefragt
    expect(queries, greaterThanOrEqualTo(2));
  });
}
