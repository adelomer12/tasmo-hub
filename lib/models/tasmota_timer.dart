/// One Tasmota timer (`Timer<x>` JSON). Tasmota has 16 timers per device.
///
/// Mode: 0 = clock time, 1 = sunrise, 2 = sunset (Time is then an offset).
/// Action: 0 = off, 1 = on, 2 = toggle, 3 = rule (fires `Clock#Timer=<x>`).
/// Days: Sunday..Saturday, '0' or '-' = off, anything else = on.
class TasmotaTimer {
  TasmotaTimer({
    required this.index,
    this.enable = false,
    this.mode = 0,
    this.time = '00:00',
    this.window = 0,
    this.days = const [true, true, true, true, true, true, true],
    this.repeat = true,
    this.output = 1,
    this.action = 1,
  });

  static const count = 16;
  static const dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  static const dayLetters = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
  static const actionNames = ['Turn off', 'Turn on', 'Toggle', 'Rule'];
  static const modeNames = ['Time', 'Sunrise', 'Sunset'];

  final int index;
  bool enable;
  int mode;
  String time;
  int window;
  List<bool> days;
  bool repeat;
  int output;
  int action;

  factory TasmotaTimer.fromJson(int index, Map<String, dynamic> j) {
    int i(String k, int def) {
      final v = j[k];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? def;
      return def;
    }

    final rawDays = '${j['Days'] ?? '1111111'}';
    final days = List<bool>.generate(
        7, (n) => n < rawDays.length && rawDays[n] != '0' && rawDays[n] != '-');
    return TasmotaTimer(
      index: index,
      enable: i('Enable', 0) == 1,
      mode: i('Mode', 0),
      time: '${j['Time'] ?? '00:00'}',
      window: i('Window', 0),
      days: days,
      repeat: i('Repeat', 1) == 1,
      output: i('Output', 1),
      action: i('Action', 1),
    );
  }

  /// JSON payload for `Timer<x> {...}`.
  Map<String, dynamic> toJson() => {
        'Enable': enable ? 1 : 0,
        'Mode': mode,
        'Time': time,
        'Window': window,
        'Days': days.map((d) => d ? '1' : '0').join(),
        'Repeat': repeat ? 1 : 0,
        'Output': output,
        'Action': action,
      };

  TasmotaTimer copy() => TasmotaTimer.fromJson(index, toJson());

  /// "Sun, Mon, ..." / "Every day" / "Weekdays" / "Never".
  String get daysLabel {
    if (days.every((d) => d)) return 'Every day';
    if (!days.contains(true)) return 'No days selected';
    if (!days[0] && !days[6] && days.sublist(1, 6).every((d) => d)) {
      return 'Weekdays';
    }
    return [
      for (var n = 0; n < 7; n++)
        if (days[n]) dayNames[n]
    ].join(', ');
  }

  String get timeLabel {
    if (mode == 0) return time;
    final off = time.replaceFirst(RegExp(r'^\+?'), '');
    final name = modeNames[mode.clamp(0, 2)];
    return off == '00:00' || off == '-00:00'
        ? name
        : '$name ${time.startsWith('-') ? '' : '+'}$off';
  }

  String get actionLabel =>
      actionNames[action.clamp(0, actionNames.length - 1)];
}

/// Result of the `Timers` command: the global switch plus every timer found.
class TimerSet {
  TimerSet(this.active, this.timers);
  final bool? active;
  final Map<int, TasmotaTimer> timers;
}

/// Pulls `Timers` and `Timer<x>` out of a reply, however Tasmota chunked it
/// ({"Timers":"ON","Timers1":{"Timer1":{..}}} over HTTP, or one MQTT
/// message per chunk merged by the caller).
TimerSet parseTimers(Map<String, dynamic> j) {
  bool? active;
  final timers = <int, TasmotaTimer>{};
  void walk(Map<String, dynamic> m) {
    for (final e in m.entries) {
      final v = e.value;
      if (e.key == 'Timers' && v is String) {
        active = v.toUpperCase() == 'ON' || v == '1';
        continue;
      }
      final match = RegExp(r'^Timer(\d+)$').firstMatch(e.key);
      if (match != null && v is Map) {
        final idx = int.parse(match.group(1)!);
        timers[idx] = TasmotaTimer.fromJson(idx, Map<String, dynamic>.from(v));
      } else if (v is Map) {
        walk(Map<String, dynamic>.from(v));
      }
    }
  }

  walk(j);
  return TimerSet(active, timers);
}
