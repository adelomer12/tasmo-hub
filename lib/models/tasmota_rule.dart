/// One Tasmota rule set (`Rule1`..`Rule3`).
///
/// Tasmota 9+ replies `{"Rule1":{"State":"ON","Once":"OFF",
/// "StopOnError":"OFF","Length":42,"Free":469,"Rules":"ON ..."}}`;
/// older builds reply flat: `{"Rule1":"ON","Once":"OFF",...,"Rules":"..."}`.
class TasmotaRule {
  TasmotaRule({
    required this.index,
    this.enabled = false,
    this.once = false,
    this.stopOnError = false,
    this.text = '',
    this.free,
  });

  static const count = 3;

  /// Tasmota stores up to 511 chars per rule set (compressed on ESP8266,
  /// so long rules may still fit); used only as a soft hint in the editor.
  static const maxLength = 511;

  final int index;
  bool enabled;
  bool once;
  bool stopOnError;
  String text;
  int? free;

  /// Command that replaces the rule text. `Rule<x> "` clears it.
  String get setTextCommand {
    final t = text.trim();
    return t.isEmpty ? 'Rule$index "' : 'Rule$index $t';
  }

  /// `Rule<x> 0/1` disable/enable, `4/5` once off/on, `8/9` stop-on-error.
  String enableCommand(bool on) => 'Rule$index ${on ? 1 : 0}';
  String onceCommand(bool on) => 'Rule$index ${on ? 5 : 4}';
  String stopOnErrorCommand(bool on) => 'Rule$index ${on ? 9 : 8}';
}

bool _onOff(Object? v) {
  if (v is num) return v != 0;
  if (v is bool) return v;
  return '$v'.toUpperCase() == 'ON' || '$v' == '1';
}

/// Parses a `Rule<x>` reply. Returns null if the reply has no such rule.
TasmotaRule? parseRule(int index, Map<String, dynamic> reply) {
  final key = 'Rule$index';
  Object? raw;
  for (final e in reply.entries) {
    if (e.key.toLowerCase() == key.toLowerCase()) raw = e.value;
  }
  if (raw == null) return null;
  final Map<String, dynamic> j;
  if (raw is Map) {
    j = Map<String, dynamic>.from(raw);
  } else {
    // Legacy flat form: the state sits under "Rule1", the rest is top level.
    j = {...reply, 'State': raw};
  }
  final free = j['Free'];
  return TasmotaRule(
    index: index,
    enabled: _onOff(j['State']),
    once: _onOff(j['Once']),
    stopOnError: _onOff(j['StopOnError']),
    text: '${j['Rules'] ?? ''}',
    free: free is num ? free.toInt() : null,
  );
}

/// Ready-made snippets for the editor. `%value%`, `%topic%` and `%sunset%`
/// are Tasmota's own rule variables; sensor names must match the device.
const ruleSnippets = <(String, String)>[
  ('On boot', 'ON System#Boot DO Power1 ON ENDON'),
  ('Button → toggle', 'ON Button1#State DO Power1 TOGGLE ENDON'),
  ('Switch → relay', 'ON Switch1#State DO Power1 %value% ENDON'),
  (
    'Auto-off after 5 min',
    'ON Power1#State=1 DO RuleTimer1 300 ENDON '
        'ON Rules#Timer=1 DO Power1 OFF ENDON'
  ),
  ('Temp above 25 → on', 'ON Tele-SI7021#Temperature>25 DO Power1 ON ENDON'),
  ('Power over 2000 W → off', 'ON Energy#Power>2000 DO Power1 OFF ENDON'),
  (
    'MQTT connected',
    'ON Mqtt#Connected DO Publish stat/%topic%/hello up ENDON'
  ),
  ('Timer as trigger', 'ON Clock#Timer=1 DO Power1 ON ENDON'),
  ('Sunset', 'ON Time#Minute=%sunset% DO Power1 ON ENDON'),
];
