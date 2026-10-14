import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/device.dart';

/// Hands the device list to the Android side so home-screen widgets and
/// Quick Settings tiles can switch devices without starting Flutter.
/// Passwords are re-encrypted there with an Android Keystore key.
class NativeBridge {
  static const _channel = MethodChannel('tasmohub/native');
  static String? _lastSignature;

  static Future<void> syncDevices(
    List<Device> devices,
    Map<String, List<String>> relays,
    Map<String, String> passwords,
  ) async {
    if (!Platform.isAndroid) return;
    final list = [
      for (final d in devices)
        {
          'id': d.id,
          'name': d.name,
          'host': d.host,
          'user': d.username,
          'locked': d.locked,
          'relays': relays[d.id] ?? const <String>[],
        }
    ];
    final json = jsonEncode(list);
    // Cheap change check so frequent state updates don't hit the channel.
    final signature =
        '$json|${passwords.entries.map((e) => '${e.key}=${e.value.hashCode}').join(',')}';
    if (signature == _lastSignature) return;
    try {
      await _channel.invokeMethod<void>('syncDevices', {
        'devices': json,
        'passwords': passwords,
      });
      _lastSignature = signature;
    } on MissingPluginException {
      // Not running inside the Android app (tests, other platforms).
    } on PlatformException {
      // Best effort; next change retries.
    }
  }
}
