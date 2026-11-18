import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mync/core/mync_core.dart';
import 'package:mync/sync/channel.dart';

DeviceIdentity device(String id) {
  final (s, p) = x25519Keypair();
  return DeviceIdentity(id: id, name: 'Gerät $id', secret: s, public: p);
}

void main() {
  test('Kopplung: gleicher Code, danach authentisierte Verbindung, Fremde abgelehnt', () async {
    final pc = device('pc');
    final handy = device('handy');
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final known = <String, Uint8List>{};
    final accepted = StreamController<SecureChannel>();
    var allowPairing = true;
    server.listen((s) async {
      try {
        accepted.add(
          await SecureChannel.accept(
            s,
            handy,
            lookupPeer: (id) => known[id],
            allowPairing: allowPairing,
          ),
        );
      } catch (e) {
        // abgelehnt
      }
    });
    final acceptedIt = StreamIterator(accepted.stream);

    // 1. Kopplung
    final c1 = await SecureChannel.connect('127.0.0.1', server.port, pc);
    expect(await acceptedIt.moveNext(), isTrue);
    final s1 = acceptedIt.current;
    expect(c1.sas, isNotNull);
    expect(c1.sas, s1.sas);
    expect(c1.sas!.length, 6);
    expect(c1.peerId, 'handy');
    expect(s1.peerId, 'pc');
    known['pc'] = s1.peerStatic;
    final handyKey = c1.peerStatic;
    await c1.sendJson({'t': 'hallo', 'x': 1});
    expect(await s1.receive(), {'t': 'hallo', 'x': 1});
    await s1.sendBinary(7, [1, 2, 3]);
    final bin = await c1.receive() as (int, Uint8List);
    expect(bin.$1, 7);
    expect(bin.$2, [1, 2, 3]);
    await c1.close();
    await s1.close();

    // 2. Sync-Verbindung mit gespeicherten Schlüsseln
    allowPairing = false;
    final c2 = await SecureChannel.connect(
      '127.0.0.1',
      server.port,
      pc,
      knownPeerStatic: handyKey,
    );
    expect(await acceptedIt.moveNext(), isTrue);
    expect(c2.sas, isNull);
    await c2.close();

    // 3. Fremdes Gerät mit gleicher ID, aber anderem Schlüssel → abgelehnt
    final fake = device('pc');
    await expectLater(
      SecureChannel.connect(
        '127.0.0.1',
        server.port,
        fake,
        knownPeerStatic: handyKey,
      ),
      throwsA(isA<SyncProtocolException>()),
    );
    // 4. Kopplung nicht freigegeben → abgelehnt
    await expectLater(
      SecureChannel.connect('127.0.0.1', server.port, device('neu')),
      throwsA(isA<SyncProtocolException>()),
    );
    // 5. Erwarteter Schlüssel passt nicht (falsches Gerät am anderen Ende)
    await expectLater(
      SecureChannel.connect(
        '127.0.0.1',
        server.port,
        pc,
        knownPeerStatic: device('x').public,
      ),
      throwsA(isA<SyncProtocolException>()),
    );
  });
}
