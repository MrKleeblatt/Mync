// Geräte im lokalen Netz finden (wie bei Kassenbon): Ein Broadcast allein
// erreicht nicht jedes Gerät – im Hotspot des Handys etwa geht er oft nicht
// über die Hotspot-Schnittstelle, und manche WLANs filtern ihn. Deshalb fragt
// die Suche zusätzlich jede Adresse in den eigenen Netzen einzeln an (UDP auf
// den Erkennungsport, ein Paket je Adresse) und meldet Antworten, sobald sie
// eintreffen.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Anfrage an den Erkennungsport; mync antwortet mit seiner Kennung als JSON.
const discoveryQuery = 'MYNC?1';

const _net = MethodChannel('mync/net');

/// Private IPv4-Adressen dieses Geräts (WLAN, Hotspot, USB-Tethering) als
/// `a.b.c.d/Länge`. Auf Android über java.net.NetworkInterface (zuverlässig
/// auch für die Hotspot-Schnittstelle, mit Netzgröße), zusätzlich dart:io
/// (ohne Netzgröße, dann nur die Adresse).
Future<List<String>> localIpv4Addresses() async {
  final prefixes = <String, String?>{};
  if (Platform.isAndroid) {
    try {
      final list = await _net.invokeListMethod<String>('ipv4');
      for (final a in list ?? const <String>[]) {
        final [ip, ...len] = a.split('%').first.split('/');
        prefixes[ip] = len.firstOrNull;
      }
    } catch (_) {} // Kanal fehlt (Tests)
  }
  try {
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in i.addresses) {
        prefixes.putIfAbsent(a.address, () => null);
      }
    }
  } catch (_) {}
  return [
    for (final MapEntry(key: ip, value: len) in prefixes.entries)
      if (isPrivateIpv4(ip)) len == null ? ip : '$ip/$len',
  ];
}

/// Name dieses Geräts: unter Android der Gerätename aus den Einstellungen
/// (z. B. „Galaxy S23 von Max“), sonst der Rechnername.
Future<String> localDeviceName() async {
  if (Platform.isAndroid) {
    try {
      final n = await _net.invokeMethod<String>('deviceName');
      if (n != null && n.trim().isNotEmpty) return n.trim();
    } catch (_) {}
    return 'Android-Handy';
  }
  return Platform.localHostname;
}

bool isPrivateIpv4(String ip) {
  final p = ip.split('.').map(int.tryParse).toList();
  if (p.length != 4 || p.contains(null)) return false;
  return p[0] == 10 ||
      (p[0] == 172 && p[1]! >= 16 && p[1]! < 32) ||
      (p[0] == 192 && p[1] == 168);
}

/// Größtes Netz, das die Suche ganz durchprobiert: /22 sind 1022 Adressen.
/// Größere Netze (z. B. /16) werden auf die /22 um die eigene Adresse
/// beschränkt.
const maxScanPrefix = 22;

int _ipToInt(String ip) =>
    ip.split('.').map(int.parse).fold(0, (a, b) => a << 8 | b);
String _intToIp(int n) => [24, 16, 8, 0].map((s) => (n >> s) & 255).join('.');

/// Durchsuchtes Netz einer Adresse `a.b.c.d/Länge` (ohne Länge: /24) als
/// Anfang und Länge.
({int base, int prefix}) scanNet(String cidr) {
  final [ip, ...len] = cidr.split('/');
  final prefix = (int.tryParse(len.firstOrNull ?? '') ?? 24).clamp(
    maxScanPrefix,
    30,
  );
  final mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
  return (base: _ipToInt(ip) & mask, prefix: prefix);
}

/// Netz wie „192.168.1.0/24“ (wird in der App angezeigt).
String scanNetLabel(String cidr) {
  final n = scanNet(cidr);
  return '${_intToIp(n.base)}/${n.prefix}';
}

/// Broadcast-Adresse des durchsuchten Netzes, z. B. „192.168.1.255“.
String broadcastOf(String cidr) {
  final n = scanNet(cidr);
  return _intToIp(n.base + (1 << (32 - n.prefix)) - 1);
}

/// Alle anderen Adressen in den Netzen der eigenen Adressen
/// (`a.b.c.d/Länge`), die aus dem eigenen /24 zuerst – dort steht das andere
/// Gerät meistens.
List<String> neighbours(List<String> own) {
  final ips = {for (final c in own) c.split('/').first};
  final hosts = <String>{};
  for (final c in own) {
    final n = scanNet(c);
    for (var i = 1; i < (1 << (32 - n.prefix)) - 1; i++) {
      hosts.add(_intToIp(n.base + i));
    }
  }
  String net24(String ip) => ip.substring(0, ip.lastIndexOf('.'));
  final near = {for (final ip in ips) net24(ip)};
  final list = hosts.difference(ips).toList();
  return [
    ...list.where((h) => near.contains(net24(h))),
    ...list.where((h) => !near.contains(net24(h))),
  ];
}

/// Antwort eines Geräts auf [discoveryQuery].
typedef DiscoveryReply = ({String host, Map<String, dynamic> data});

/// Fragt per UDP auf [port] nach Geräten: Broadcast an alle und an jedes
/// eigene Netz, direkt an [hints] (zuletzt bekannte Adressen) und an jede
/// Adresse in den eigenen Netzen. Weil UDP-Pakete verloren gehen können,
/// wird zweimal nachgefragt. Antworten kommen, sobald sie eintreffen; nach
/// [timeout] endet der Strom. [onSubnets] meldet die durchsuchten Netze.
Stream<DiscoveryReply> queryNetwork({
  required int port,
  Iterable<String> hints = const [],
  Duration timeout = const Duration(seconds: 4),
  Future<List<String>> Function() addresses = localIpv4Addresses,
  void Function(List<String> subnets)? onSubnets,
  void Function(List<String> own)? onAddresses,
}) {
  final out = StreamController<DiscoveryReply>();
  RawDatagramSocket? socket;
  Timer? end;
  Future<void> stop() async {
    end?.cancel();
    socket?.close();
    socket = null;
    if (!out.isClosed) await out.close();
  }

  () async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket = s;
      s.broadcastEnabled = true;
      s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = s.receive();
        if (d == null || out.isClosed) return;
        try {
          final j = jsonDecode(utf8.decode(d.data));
          if (j is Map<String, dynamic>) {
            out.add((host: d.address.address, data: j));
          }
        } catch (_) {} // fremdes Paket
      });
      end = Timer(timeout, stop);
      final own = await addresses();
      onSubnets?.call({for (final c in own) scanNetLabel(c)}.toList());
      onAddresses?.call([for (final c in own) c.split('/').first]);
      final targets = <String>{
        '255.255.255.255',
        for (final c in own) broadcastOf(c),
        '127.0.0.1',
        ...hints,
        ...neighbours(own),
      }.toList();
      final msg = utf8.encode(discoveryQuery);
      for (final round in [Duration.zero, const Duration(milliseconds: 600)]) {
        await Future<void>.delayed(round);
        for (final (i, t) in targets.indexed) {
          if (socket == null) return;
          try {
            s.send(msg, InternetAddress(t), port);
          } catch (_) {} // z. B. Netz nicht erreichbar
          // dem Sendepuffer Luft lassen, sonst fallen Pakete still weg
          if (i % 64 == 63) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
        }
      }
    } catch (e) {
      if (!out.isClosed) out.addError(e);
      await stop();
    }
  }();
  out.onCancel = stop;
  return out.stream;
}
