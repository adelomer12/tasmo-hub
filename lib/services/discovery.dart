import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../models/device.dart';
import 'tasmota_api.dart';

class DiscoveredDevice {
  DiscoveredDevice({
    required this.host,
    required this.type,
    this.state,
    this.authRequired = false,
    this.source = 'scan',
  });

  final String host;
  FirmwareType type;
  DeviceState? state;
  bool authRequired;
  final String source;

  String get displayName {
    final s = state;
    if (s == null) return host;
    if (s.deviceName.isNotEmpty) return s.deviceName;
    if (s.friendlyName.isNotEmpty) return s.friendlyName;
    if (s.hostname.isNotEmpty) return s.hostname;
    return host;
  }
}

/// IPv4 range helpers. Accepts "192.168.20.0/24", "192.168.20.10-192.168.20.80"
/// or "192.168.20.10-80".
class Ipv4Range {
  Ipv4Range(this.start, this.end);
  final int start;
  final int end;

  int get count => end - start + 1;

  Iterable<String> get hosts sync* {
    for (var i = start; i <= end; i++) {
      yield intToIp(i);
    }
  }

  static int ipToInt(String ip) {
    final p = ip.trim().split('.').map(int.parse).toList();
    if (p.length != 4 || p.any((o) => o < 0 || o > 255)) {
      throw const FormatException('Bad IPv4 address');
    }
    return (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
  }

  static String intToIp(int v) =>
      '${(v >> 24) & 255}.${(v >> 16) & 255}.${(v >> 8) & 255}.${v & 255}';

  static Ipv4Range parse(String input) {
    final s = input.trim();
    if (s.contains('/')) {
      final parts = s.split('/');
      final prefix = int.parse(parts[1]);
      // Refuse anything bigger than a /22 (1022 hosts): this is a LAN scan.
      if (prefix < 22 || prefix > 30) {
        throw const FormatException('Use a prefix between /22 and /30');
      }
      final base = ipToInt(parts[0]);
      final mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
      final net = base & mask;
      final bcast = net | (~mask & 0xFFFFFFFF);
      return Ipv4Range(net + 1, bcast - 1);
    }
    if (s.contains('-')) {
      final parts = s.split('-');
      final a = ipToInt(parts[0]);
      final endStr = parts[1].trim();
      final b = endStr.contains('.')
          ? ipToInt(endStr)
          : (a & 0xFFFFFF00) | int.parse(endStr);
      if (b < a || b - a > 1023) {
        throw const FormatException('Range must be ascending, max 1024 hosts');
      }
      return Ipv4Range(a, b);
    }
    final one = ipToInt(s);
    return Ipv4Range(one, one);
  }

  static String cidr24For(String ip) {
    final p = ip.split('.');
    return '${p[0]}.${p[1]}.${p[2]}.0/24';
  }
}

bool isPrivateIPv4(String host) {
  try {
    final v = Ipv4Range.ipToInt(host);
    bool inNet(String net, int prefix) {
      final mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
      return (v & mask) == (Ipv4Range.ipToInt(net) & mask);
    }

    return inNet('10.0.0.0', 8) ||
        inNet('172.16.0.0', 12) ||
        inNet('192.168.0.0', 16) ||
        inNet('169.254.0.0', 16) ||
        inNet('100.64.0.0', 10); // CGNAT / Tailscale
  } catch (_) {
    // Hostnames: only trust mDNS-style local names.
    return host.endsWith('.local') ||
        host.endsWith('.lan') ||
        !host.contains('.');
  }
}

class DiscoveryService {
  DiscoveryService(this.api);
  final TasmotaApi api;
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  /// Suggests the phone's own /24 (works on the IoT VLAN only if the phone
  /// is on it; otherwise the user types the IoT subnet).
  static Future<String?> suggestedRange() async {
    try {
      final ip = await NetworkInfo().getWifiIP();
      if (ip != null && ip.contains('.')) return Ipv4Range.cidr24For(ip);
    } catch (_) {}
    try {
      for (final iface
          in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in iface.addresses) {
          if (!a.isLoopback && isPrivateIPv4(a.address)) {
            return Ipv4Range.cidr24For(a.address);
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Probes one host: a cheap TCP connect to :80 first, then `Status 0`.
  Future<DiscoveredDevice?> probe(String host,
      {String source = 'scan', String? username, String? password}) async {
    try {
      final sock = await Socket.connect(host, 80,
          timeout: const Duration(milliseconds: 700));
      sock.destroy();
    } catch (_) {
      return null;
    }
    try {
      final st =
          await api.fetchState(host, username: username, password: password);
      var type = detectFirmware(st);
      if (type == FirmwareType.unknown) {
        type = detectFirmware(st, indexHtml: await api.fetchIndex(host));
      }
      return DiscoveredDevice(
          host: host, type: type, state: st, source: source);
    } on AuthRequiredException {
      final html = await api.fetchIndex(host);
      return DiscoveredDevice(
        host: host,
        type: html == null
            ? FirmwareType.unknown
            : detectFirmware(DeviceState(), indexHtml: html),
        authRequired: true,
        source: source,
      );
    } catch (_) {
      return null;
    }
  }

  /// Scans a range with bounded concurrency, emitting devices as found.
  Stream<DiscoveredDevice> scan(Ipv4Range range,
      {int concurrency = 48,
      String? password,
      void Function(int done, int total)? onProgress}) {
    _cancelled = false;
    final ctrl = StreamController<DiscoveredDevice>();
    final hosts = range.hosts.toList();
    var next = 0;
    var done = 0;

    Future<void> worker() async {
      while (!_cancelled && next < hosts.length) {
        final h = hosts[next++];
        final d = await probe(h, password: password);
        done++;
        onProgress?.call(done, hosts.length);
        if (d != null && !ctrl.isClosed) ctrl.add(d);
      }
    }

    Future.wait(List.generate(concurrency, (_) => worker()))
        .whenComplete(ctrl.close);
    return ctrl.stream;
  }

  /// mDNS browse of _http._tcp (Tasmota with mDNS enabled, some OpenBeken
  /// builds). Multicast does not cross VLANs unless the router reflects it.
  Stream<DiscoveredDevice> mdns(
      {Duration timeout = const Duration(seconds: 5)}) async* {
    final client = MDnsClient(
        rawDatagramSocketFactory: (dynamic host, int port,
                {bool reuseAddress = true,
                bool reusePort = false,
                int ttl = 1}) =>
            RawDatagramSocket.bind(host, port,
                reuseAddress: true, reusePort: false, ttl: ttl));
    final seen = <String>{};
    try {
      await client.start();
      await for (final ptr in client.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer('_http._tcp.local'),
          timeout: timeout)) {
        if (_cancelled) break;
        await for (final srv in client.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(ptr.domainName),
            timeout: const Duration(seconds: 2))) {
          await for (final a in client.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target),
              timeout: const Duration(seconds: 2))) {
            final ip = a.address.address;
            if (!seen.add(ip)) continue;
            final d = await probe(ip, source: 'mDNS');
            if (d != null) yield d;
          }
        }
      }
    } catch (_) {
      // mDNS is best effort (e.g. iOS without the multicast entitlement).
    } finally {
      client.stop();
    }
  }
}
