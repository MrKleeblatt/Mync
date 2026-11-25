// Geräte per mDNS/DNS-SD finden (Dienst „_mync._tcp.local“), zusätzlich zur
// Suche über den Erkennungsport (discovery.dart). mDNS ist der übliche Weg
// im Heimnetz: eine Anfrage an alle, ohne jede Adresse einzeln anzufragen –
// auch in Netzen größer als /22.
//
// Android: NsdManager (Kanal „mync/mdns“, Mdns.kt) – das System beantwortet
// Anfragen auch, während mync im Hintergrund ist. Linux und andere: eigene
// kleine Umsetzung über UDP-Multicast (224.0.0.251:5353), neben Avahi.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../log.dart';

/// Dienstname (ohne „.local“).
const mdnsService = '_mync._tcp';
const _domain = 'local';
const _group = '224.0.0.251';
const mdnsPort = 5353;

/// Ein per mDNS gefundenes Gerät.
typedef MdnsFound = ({String host, int port, Map<String, String> txt});

abstract class Mdns {
  /// Für diese Plattform passende Umsetzung.
  factory Mdns.platform() => Platform.isAndroid ? _AndroidMdns() : DartMdns();

  /// Macht dieses Gerät als [instance] mit [port] und [txt] bekannt
  /// (erneuter Aufruf ersetzt die Angaben).
  Future<void> advertise({
    required String instance,
    required int port,
    required Map<String, String> txt,
  });

  Future<void> stopAdvertising();

  /// Sucht [timeout] lang; meldet jedes Gerät, sobald es antwortet.
  Stream<MdnsFound> browse({Duration timeout = const Duration(seconds: 4)});
}

// ─── Android: NsdManager ─────────────────────────────────────────────────

class _AndroidMdns implements Mdns {
  _AndroidMdns() {
    _ch.setMethodCallHandler((call) async {
      if (call.method != 'found') return;
      final a = Map<String, dynamic>.from(call.arguments as Map);
      final found = (
        host: a['host'] as String,
        port: a['port'] as int,
        txt: Map<String, String>.from(a['txt'] as Map),
      );
      for (final c in _browsers.toList()) {
        if (!c.isClosed) c.add(found);
      }
    });
  }

  static const _ch = MethodChannel('mync/mdns');
  final _browsers = <StreamController<MdnsFound>>{};

  @override
  Future<void> advertise({
    required String instance,
    required int port,
    required Map<String, String> txt,
  }) async {
    try {
      await _ch.invokeMethod('register', {
        'name': instance,
        'type': mdnsService,
        'port': port,
        'txt': txt,
      });
    } catch (e) {
      logWarning('mDNS: Bekanntmachen fehlgeschlagen: $e');
    }
  }

  @override
  Future<void> stopAdvertising() async {
    try {
      await _ch.invokeMethod('unregister');
    } catch (_) {}
  }

  @override
  Stream<MdnsFound> browse({Duration timeout = const Duration(seconds: 4)}) {
    late final StreamController<MdnsFound> c;
    Timer? end;
    Future<void> stop() async {
      end?.cancel();
      if (_browsers.remove(c) && _browsers.isEmpty) {
        try {
          await _ch.invokeMethod('stopBrowse');
        } catch (_) {}
      }
      if (!c.isClosed) await c.close();
    }

    c = StreamController<MdnsFound>(
      onListen: () async {
        _browsers.add(c);
        end = Timer(timeout, stop);
        try {
          await _ch.invokeMethod('browse', {'type': mdnsService});
        } catch (e) {
          logWarning('mDNS: Suche nicht möglich: $e');
          await stop();
        }
      },
      onCancel: stop,
    );
    return c.stream;
  }
}

// ─── Eigene Umsetzung (Linux, Tests) ─────────────────────────────────────

/// mDNS über UDP-Multicast: beantwortet Anfragen nach [mdnsService] und
/// sucht selbst. Läuft neben Avahi (Port 5353 mit SO_REUSEADDR geteilt).
class DartMdns implements Mdns {
  DartMdns({this.port = mdnsPort, this.group = _group});

  /// In Tests ein anderer Port, damit das System-mDNS nicht stört.
  final int port;
  final String group;

  Future<RawDatagramSocket?>? _opening;
  final _browsers = <StreamController<MdnsFound>>{};

  String? _instance;
  int _port = 0;
  Map<String, String> _txt = const {};

  String get _serviceFqdn => '$mdnsService.$_domain';

  Future<RawDatagramSocket?> _open() => _opening ??= () async {
    try {
      final s = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
      s.multicastLoopback = true;
      final g = InternetAddress(group);
      var joined = false;
      try {
        for (final i in await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        )) {
          try {
            s.joinMulticast(g, i);
            joined = true;
          } catch (_) {}
        }
      } catch (_) {}
      if (!joined) s.joinMulticast(g);
      s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = s.receive();
        if (d != null) _onPacket(s, d);
      });
      return s;
    } catch (e) {
      logWarning('mDNS: Port $port nicht nutzbar: $e');
      return null;
    }
  }();

  Future<List<String>> _ownIps() async {
    try {
      return [
        for (final i in await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        ))
          for (final a in i.addresses)
            if (!a.isLoopback) a.address,
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<Uint8List?> _response({int id = 0, bool withQuestion = false}) async {
    final inst = _instance;
    if (inst == null) return null;
    return encodeResponse(
      id: id,
      service: _serviceFqdn,
      instance: '$inst.$_serviceFqdn',
      host: '$inst.$_domain',
      port: _port,
      txt: _txt,
      ips: await _ownIps(),
      withQuestion: withQuestion,
    );
  }

  void _onPacket(RawDatagramSocket s, Datagram d) {
    final DnsMessage m;
    try {
      m = DnsMessage.decode(d.data);
    } catch (_) {
      return; // kein gültiges DNS-Paket
    }
    if (m.isResponse) {
      final f = m.found(_serviceFqdn, d.address.address);
      if (f != null) {
        for (final c in _browsers.toList()) {
          if (!c.isClosed) c.add(f);
        }
      }
      return;
    }
    if (_instance == null ||
        !m.questions.any(
          (q) =>
              _sameName(q.name, _serviceFqdn) &&
              (q.type == 12 || q.type == 255),
        )) {
      return;
    }
    () async {
      // Altmodische Anfrage (nicht von Port 5353): direkt antworten, mit
      // derselben Kennung; sonst an alle.
      final legacy = d.port != port;
      final unicast = legacy || m.questions.any((q) => q.unicast);
      final r = await _response(id: legacy ? m.id : 0, withQuestion: legacy);
      if (r == null) return;
      try {
        s.send(
          r,
          unicast ? d.address : InternetAddress(group),
          unicast ? d.port : port,
        );
      } catch (_) {}
    }();
  }

  @override
  Future<void> advertise({
    required String instance,
    required int port,
    required Map<String, String> txt,
  }) async {
    _instance = instance;
    _port = port;
    _txt = txt;
    final s = await _open();
    final r = await _response();
    if (s == null || r == null) return;
    // unaufgefordert bekannt machen (Suchende sehen es sofort)
    for (final wait in const [0, 1000]) {
      await Future<void>.delayed(Duration(milliseconds: wait));
      try {
        s.send(r, InternetAddress(group), this.port);
      } catch (_) {}
    }
  }

  @override
  Future<void> stopAdvertising() async => _instance = null;

  @override
  Stream<MdnsFound> browse({Duration timeout = const Duration(seconds: 4)}) {
    late final StreamController<MdnsFound> c;
    RawDatagramSocket? legacy;
    Timer? end;
    Future<void> stop() async {
      end?.cancel();
      _browsers.remove(c);
      legacy?.close();
      legacy = null;
      if (!c.isClosed) await c.close();
    }

    c = StreamController<MdnsFound>(
      onListen: () async {
        _browsers.add(c);
        end = Timer(timeout, stop);
        final q = encodeQuery(_serviceFqdn);
        final s = await _open();
        // Zusätzlich von einem eigenen Port fragen: Antworten kommen dann
        // direkt zurück, auch wenn Port 5353 nicht nutzbar ist.
        try {
          final l = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
          legacy = l;
          l.listen((ev) {
            if (ev != RawSocketEvent.read) return;
            final d = l.receive();
            if (d == null || c.isClosed) return;
            try {
              final f = DnsMessage.decode(d.data)
                  .found(_serviceFqdn, d.address.address);
              if (f != null) c.add(f);
            } catch (_) {}
          });
        } catch (_) {}
        for (final wait in const [0, 1000, 2000]) {
          await Future<void>.delayed(Duration(milliseconds: wait));
          if (c.isClosed) return;
          final g = InternetAddress(group);
          for (final sock in [?s, ?legacy]) {
            try {
              sock.send(q, g, port);
            } catch (_) {}
          }
        }
      },
      onCancel: stop,
    );
    return c.stream;
  }
}

bool _sameName(String a, String b) => a.toLowerCase() == b.toLowerCase();

// ─── DNS-Nachrichten ─────────────────────────────────────────────────────

/// Anfrage nach PTR-Einträgen für [service] (z. B. „_mync._tcp.local“).
Uint8List encodeQuery(String service, {int id = 0}) {
  final w = _Writer()
    ..u16(id)
    ..u16(0) // Flags: Anfrage
    ..u16(1) // eine Frage
    ..u16(0)
    ..u16(0)
    ..u16(0)
    ..name(service)
    ..u16(12) // PTR
    ..u16(1); // IN
  return w.bytes();
}

/// Antwort mit PTR, SRV, TXT und A-Einträgen.
Uint8List encodeResponse({
  int id = 0,
  required String service,
  required String instance,
  required String host,
  required int port,
  required Map<String, String> txt,
  required List<String> ips,
  int ttl = 120,
  bool withQuestion = false,
}) {
  final w = _Writer()
    ..u16(id)
    ..u16(0x8400) // Antwort, maßgeblich
    ..u16(withQuestion ? 1 : 0)
    ..u16(1) // PTR
    ..u16(0)
    ..u16(2 + ips.length); // SRV, TXT, A…
  if (withQuestion) {
    w
      ..name(service)
      ..u16(12)
      ..u16(1);
  }
  void rr(String name, int type, int cls, void Function(_Writer) data) {
    final d = _Writer();
    data(d);
    final b = d.bytes();
    w
      ..name(name)
      ..u16(type)
      ..u16(cls)
      ..u32(ttl)
      ..u16(b.length)
      ..raw(b);
  }

  rr(service, 12, 1, (d) => d.name(instance));
  // 0x8001: „cache flush“ – diese Einträge gehören nur diesem Gerät
  rr(instance, 33, 0x8001, (d) {
    d
      ..u16(0)
      ..u16(0)
      ..u16(port)
      ..name(host);
  });
  rr(instance, 16, 0x8001, (d) {
    final entries = txt.entries.isEmpty
        ? [<int>[]]
        : [
            for (final e in txt.entries)
              _limit(utf8.encode('${e.key}=${e.value}')),
          ];
    for (final e in entries) {
      d
        ..u8(e.length)
        ..raw(e);
    }
  });
  for (final ip in ips) {
    rr(host, 1, 0x8001, (d) => d.raw(InternetAddress(ip).rawAddress));
  }
  return w.bytes();
}

List<int> _limit(List<int> b) => b.length <= 255 ? b : b.sublist(0, 255);

class DnsQuestion {
  DnsQuestion(this.name, this.type, this.unicast);
  final String name;
  final int type;

  /// QU-Bit: Antwort direkt an den Fragenden erwünscht.
  final bool unicast;
}

class DnsRecord {
  DnsRecord(this.name, this.type, this.data);
  final String name;
  final int type;

  /// PTR: Name; SRV: (port, target); TXT: Map; A: Adresse; sonst Bytes.
  final Object data;
}

class DnsMessage {
  DnsMessage(this.id, this.isResponse, this.questions, this.records);
  final int id;
  final bool isResponse;
  final List<DnsQuestion> questions;
  final List<DnsRecord> records;

  factory DnsMessage.decode(Uint8List b) {
    final r = _Reader(b);
    final id = r.u16();
    final flags = r.u16();
    final qd = r.u16(), an = r.u16(), ns = r.u16(), ar = r.u16();
    final questions = <DnsQuestion>[];
    for (var i = 0; i < qd; i++) {
      final name = r.name();
      final type = r.u16();
      final cls = r.u16();
      questions.add(DnsQuestion(name, type, cls & 0x8000 != 0));
    }
    final records = <DnsRecord>[];
    for (var i = 0; i < an + ns + ar; i++) {
      final name = r.name();
      final type = r.u16();
      r.u16(); // Klasse
      r.u32(); // TTL
      final len = r.u16();
      final end = r.pos + len;
      final Object data = switch (type) {
        12 => r.name(),
        33 => () {
          r.u16();
          r.u16();
          final port = r.u16();
          return (port, r.name());
        }(),
        16 => () {
          final m = <String, String>{};
          while (r.pos < end) {
            final l = r.u8();
            final s = utf8.decode(r.bytes(l), allowMalformed: true);
            final eq = s.indexOf('=');
            if (eq > 0) m[s.substring(0, eq)] = s.substring(eq + 1);
          }
          return m;
        }(),
        1 when len == 4 => InternetAddress.fromRawAddress(
          Uint8List.fromList(r.bytes(4)),
        ).address,
        _ => r.bytes(len),
      };
      r.pos = end;
      records.add(DnsRecord(name, type, data));
    }
    return DnsMessage(id, flags & 0x8000 != 0, questions, records);
  }

  /// Ein Gerät mit [service] in dieser Antwort; Adresse aus dem A-Eintrag,
  /// sonst [from] (Absender des Pakets).
  MdnsFound? found(String service, String from) {
    final ptr = records
        .where((r) => r.type == 12 && _sameName(r.name, service))
        .map((r) => r.data as String)
        .firstOrNull;
    if (ptr == null) return null;
    final srv = records
        .where((r) => r.type == 33 && _sameName(r.name, ptr))
        .map((r) => r.data as (int, String))
        .firstOrNull;
    if (srv == null) return null;
    final txt = records
        .where((r) => r.type == 16 && _sameName(r.name, ptr))
        .map((r) => r.data as Map<String, String>)
        .firstOrNull;
    final ips = [
      for (final r in records)
        if (r.type == 1 && _sameName(r.name, srv.$2)) r.data as String,
    ];
    // Absender bevorzugen: die Adresse, über die es uns tatsächlich erreicht
    final host = ips.isEmpty || ips.contains(from) ? from : ips.first;
    return (host: host, port: srv.$1, txt: txt ?? const {});
  }
}

class _Writer {
  final _b = BytesBuilder();
  void u8(int v) => _b.addByte(v & 0xFF);
  void u16(int v) => _b.add([(v >> 8) & 0xFF, v & 0xFF]);
  void u32(int v) =>
      _b.add([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
  void raw(List<int> b) => _b.add(b);
  void name(String n) {
    for (final label in n.split('.')) {
      if (label.isEmpty) continue;
      final b = _limit(utf8.encode(label));
      u8(b.length > 63 ? 63 : b.length);
      raw(b.length > 63 ? b.sublist(0, 63) : b);
    }
    u8(0);
  }

  Uint8List bytes() => _b.toBytes();
}

class _Reader {
  _Reader(this.b);
  final Uint8List b;
  int pos = 0;

  int u8() => b[pos++];
  int u16() => (u8() << 8) | u8();
  int u32() => (u16() << 16) | u16();
  List<int> bytes(int n) {
    if (pos + n > b.length) throw const FormatException('zu kurz');
    final r = b.sublist(pos, pos + n);
    pos += n;
    return r;
  }

  /// Name mit Kompression (Zeiger auf frühere Stellen).
  String name() {
    final labels = <String>[];
    var p = pos;
    var jumped = false;
    var hops = 0;
    while (true) {
      if (p >= b.length) throw const FormatException('Name zu kurz');
      final l = b[p];
      if (l == 0) {
        p++;
        break;
      }
      if (l & 0xC0 == 0xC0) {
        if (++hops > 32) throw const FormatException('Zeigerschleife');
        final target = ((l & 0x3F) << 8) | b[p + 1];
        if (!jumped) pos = p + 2;
        jumped = true;
        p = target;
        continue;
      }
      labels.add(
        utf8.decode(b.sublist(p + 1, p + 1 + l), allowMalformed: true),
      );
      p += 1 + l;
    }
    if (!jumped) pos = p;
    return labels.join('.');
  }
}
