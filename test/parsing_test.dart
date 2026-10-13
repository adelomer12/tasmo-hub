import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tasmo_hub/models/device.dart';
import 'package:tasmo_hub/services/discovery.dart';
import 'package:tasmo_hub/services/tasmota_api.dart';

const tasmotaStatus0 = '''
{"Status":{"Module":0,"DeviceName":"Office Plug","FriendlyName":["Office Plug"],"Topic":"tasmota_A1B2C3","Power":"1"},
"StatusPRM":{"Uptime":"2T03:04:05"},
"StatusFWR":{"Version":"14.2.0(release-tasmota)","Hardware":"ESP8266EX"},
"StatusNET":{"Hostname":"tasmota-A1B2C3-1234","IPAddress":"192.168.20.31","Mac":"AA:BB:CC:A1:B2:C3"},
"StatusSNS":{"Time":"2026-10-13T12:00:00","ENERGY":{"TotalStartTime":"2025-01-01T00:00:00","Total":12.345,"Today":0.4,"Power":61,"Voltage":231,"Current":0.27},"AM2301":{"Temperature":nan,"Humidity":48.2},"TempUnit":"C"},
"StatusSTS":{"Time":"2026-10-13T12:00:00","Uptime":"2T03:04:05","POWER":"ON","Wifi":{"SSId":"IoT","RSSI":78,"Signal":-61}}}
''';

const obkStatus0 = '''
{"Status":{"Module":0,"DeviceName":"OpenBK7231N_1A2B","FriendlyName":["OpenBK7231N_1A2B"],"Power":"10"},
"StatusFWR":{"Version":"1.17.551","Hardware":"BK7231N"},
"StatusNET":{"Hostname":"obk1A2B","IPAddress":"192.168.20.40","Mac":"C8:47:8C:00:1A:2B"},
"StatusSTS":{"POWER1":"OFF","POWER2":"ON","Dimmer":40,"HSBColor":"120,100,40","CT":300}}
''';

void main() {
  test('parses Tasmota Status 0 including nan sensors', () async {
    final api = TasmotaApi(
        client: MockClient((_) async => http.Response(tasmotaStatus0, 200)));
    final s = await api.fetchState('192.168.20.31');
    expect(s.online, isTrue);
    expect(s.power, {'POWER': true});
    expect(s.deviceName, 'Office Plug');
    expect(s.mac, 'AA:BB:CC:A1:B2:C3');
    expect(s.rssi, 78);
    expect(s.signal, -61);
    expect(s.uptime, '2T03:04:05');
    final power = s.sensors.firstWhere((r) => r.key == 'Power');
    expect(power.display, '61 W');
    expect(s.sensors.any((r) => r.key == 'TotalStartTime'), isFalse);
    expect(s.sensors.firstWhere((r) => r.key == 'Humidity').display, '48.2 %');
    expect(s.sensors.firstWhere((r) => r.key == 'Temperature').value, isNull);
    expect(detectFirmware(s), FirmwareType.tasmota);
  });

  test('parses OpenBeken multi-relay light', () {
    final s = parseStatus0(Map<String, dynamic>.from(jsonDecode(obkStatus0)));
    expect(s.relayKeys, ['POWER1', 'POWER2']);
    expect(s.power['POWER2'], isTrue);
    expect(s.dimmer, 40);
    expect(s.hsb, [120, 100, 40]);
    expect(s.ct, 300);
    expect(detectFirmware(s), FirmwareType.openbeken);
  });

  test('power bitmask fallback when StatusSTS lacks POWER keys', () {
    final s = parseStatus0({
      'Status': {'Power': '101'}
    });
    expect(s.power, {'POWER1': true, 'POWER2': false, 'POWER3': true});
  });

  test('password warning raises AuthRequiredException', () async {
    final api = TasmotaApi(
        client: MockClient((_) async => http.Response(
            '{"WARNING":"Need user=<username>&password=<password>"}', 200)));
    expect(api.send('10.0.0.5', 'Status 0'),
        throwsA(isA<AuthRequiredException>()));
  });

  test('builds /cm URI with encoded credentials', () {
    final uri = TasmotaApi().buildUri(
        '192.168.20.31', 'Backlog Power1 ON; Dimmer 50',
        username: 'admin', password: 'p&ss=1');
    expect(uri.path, '/cm');
    expect(uri.queryParameters['password'], 'p&ss=1');
    expect(uri.queryParameters['cmnd'], 'Backlog Power1 ON; Dimmer 50');
    expect(
        TasmotaApi().buildUri('h', 'Power').queryParameters.containsKey('user'),
        isFalse);
  });

  test('IPv4 range parsing', () {
    final r = Ipv4Range.parse('192.168.20.0/24');
    expect(r.count, 254);
    expect(r.hosts.first, '192.168.20.1');
    expect(r.hosts.last, '192.168.20.254');
    expect(Ipv4Range.parse('192.168.20.10-20').count, 11);
    expect(Ipv4Range.parse('10.0.0.5').count, 1);
    expect(() => Ipv4Range.parse('10.0.0.0/16'), throwsFormatException);
    expect(isPrivateIPv4('192.168.1.2'), isTrue);
    expect(isPrivateIPv4('8.8.8.8'), isFalse);
  });

  test('device JSON never contains passwords', () {
    final d = Device(id: 'x', host: '1.2.3.4', name: 'n');
    expect(Device.encodeList([d]).contains('password'), isFalse);
    expect(Device.decodeList(Device.encodeList([d])).single.host, '1.2.3.4');
  });
}
