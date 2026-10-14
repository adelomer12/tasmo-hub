import 'dart:convert';

/// One step of a scene: a Tasmota command sent to one saved device.
///
/// Stored as a plain command (`POWER2 ON`, `Dimmer 40`, `CT 300`...) so the
/// same scene works over HTTP and MQTT and for any firmware command.
class SceneAction {
  SceneAction({required this.deviceId, required this.command});

  final String deviceId;
  String command;

  /// True for relay switching, which respects the device's switching lock.
  bool get isPower =>
      RegExp(r'^POWER\d*\b', caseSensitive: false).hasMatch(command.trim());

  factory SceneAction.fromJson(Map<String, dynamic> j) => SceneAction(
        deviceId: '${j['device'] ?? ''}',
        command: '${j['cmnd'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {'device': deviceId, 'cmnd': command};
}

/// A named group of commands across devices, run with one tap.
class Scene {
  Scene({required this.id, required this.name, List<SceneAction>? actions})
      : actions = actions ?? [];

  final String id;
  String name;
  final List<SceneAction> actions;

  factory Scene.fromJson(Map<String, dynamic> j) => Scene(
        id: '${j['id']}',
        name: '${j['name'] ?? 'Scene'}',
        actions: [
          for (final a in (j['actions'] as List? ?? const []))
            if (a is Map) SceneAction.fromJson(Map<String, dynamic>.from(a)),
        ],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'actions': actions.map((a) => a.toJson()).toList(),
      };

  Scene copy() => Scene.fromJson(jsonDecode(jsonEncode(toJson())));

  static List<Scene> decodeList(String raw) => [
        for (final e in jsonDecode(raw) as List)
          if (e is Map) Scene.fromJson(Map<String, dynamic>.from(e)),
      ];

  static String encodeList(List<Scene> scenes) =>
      jsonEncode(scenes.map((s) => s.toJson()).toList());
}

/// Outcome of running a scene.
class SceneRunResult {
  int ok = 0;
  final List<String> skipped = [];
  final List<String> failed = [];

  String get summary {
    final parts = <String>['$ok done'];
    if (skipped.isNotEmpty) parts.add('${skipped.length} skipped (locked)');
    if (failed.isNotEmpty) parts.add('${failed.length} failed');
    return parts.join(', ');
  }
}
