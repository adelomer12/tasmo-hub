import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/device.dart';
import '../services/device_store.dart';
import '../services/firmware_verify.dart';
import '../services/ota_service.dart';
import '../widgets/device_tile.dart';

/// Firmware update: get a file (official release or local), verify it
/// offline, upload it to the device, then confirm what the device runs.
class OtaScreen extends StatefulWidget {
  const OtaScreen({super.key, required this.store, required this.device});
  final DeviceStore store;
  final Device device;

  @override
  State<OtaScreen> createState() => _OtaScreenState();
}

class _OtaScreenState extends State<OtaScreen> {
  final OtaService _ota = OtaService();
  final _expected = TextEditingController();

  FwTarget? _target;
  String? _targetError;

  FirmwareSource? _source;
  String _origin = '';
  FirmwareReport? _report;

  bool _busy = false;
  String _step = '';
  double? _progress;
  String? _error;

  List<FwCheck>? _after;

  Device get d => widget.device;
  String? get _pw => widget.store.passwordOf(d);
  bool get _isObk => d.type == FirmwareType.openbeken;

  @override
  void initState() {
    super.initState();
    _loadTarget();
  }

  @override
  void dispose() {
    _expected.dispose();
    _ota.close();
    super.dispose();
  }

  Future<void> _loadTarget() async {
    setState(() => _targetError = null);
    try {
      final t = await _ota.readTarget(d, _pw);
      if (mounted) setState(() => _target = t);
    } catch (e) {
      if (mounted) setState(() => _targetError = '$e');
    }
  }

  void _setStep(String s, [double? progress]) {
    if (mounted) {
      setState(() {
        _step = s;
        _progress = progress;
      });
    }
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await job();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _step = '';
          _progress = null;
        });
      }
    }
  }

  Future<void> _official() => _run(() async {
        final t = _target!;
        _setStep('Looking up the latest release…');
        final src = await _ota.officialFirmware(t);
        _setStep('Downloading ${src.fileName}…', 0);
        final bytes = await _ota.download(src,
            onProgress: (got, total) => _setStep('Downloading ${src.fileName}…',
                total == null ? null : got / total));
        _source = src;
        _origin = src.origin;
        _verify(bytes, src.fileName, src.publishedSha256);
      });

  Future<void> _pickFile() => _run(() async {
        final f = await FilePicker.pickFile();
        if (f == null) return;
        final len = f.lengthSync() ?? await f.length();
        if (len != null && len > OtaService.maxFirmwareBytes) {
          throw OtaException('File is too large for a firmware image');
        }
        _setStep('Reading ${f.name}…');
        final bytes = await f.readAsBytes();
        _source = null;
        _origin = 'File on this phone';
        _verify(bytes, f.name, null);
      });

  void _verify(Uint8List bytes, String name, String? published) {
    final typed = normalizeDigest(_expected.text);
    final r = verifyFirmware(bytes, name, _target!,
        expectedSha256: typed ?? published);
    if (typed != null && published != null && typed != published) {
      r.add(CheckLevel.fail, 'Pasted SHA-256 differs from the release digest');
    }
    if (published != null && typed == null && r.digestVerified) {
      r.checks.removeLast();
      r.add(CheckLevel.ok, 'SHA-256 matches the release digest');
    }
    if (!r.digestVerified && typed == null) {
      r.add(
          CheckLevel.warn,
          'No published SHA-256 to compare',
          _source == null
              ? 'paste the release checksum above to verify the file itself'
              : 'downloaded over HTTPS from ${_source!.urls.first.host}');
    }
    setState(() {
      _report = r;
      _after = null;
    });
  }

  bool get _needsMinimal =>
      _report?.checks.any((c) => c.label.startsWith('Does not fit')) ?? false;

  Future<void> _confirmAndFlash() async {
    final r = _report!;
    final warnings = r.checks.where((c) => c.level == CheckLevel.warn);
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Flash ${d.name}?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${r.fileName} will be written to the device, which '
                    'then restarts. Keep the device powered and this screen '
                    'open until it is back.'),
                if (_needsMinimal) ...[
                  const SizedBox(height: 8),
                  const Text('The minimal firmware is flashed first to make '
                      'room, so the device restarts twice.'),
                ],
                if (warnings.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Warnings:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  for (final w in warnings) Text('• ${w.label}'),
                ],
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Flash')),
            ],
          ),
        ) ??
        false;
    if (ok) await _flash();
  }

  Future<void> _flash() => _run(() async {
        final r = _report!;
        final before = _target!;
        if (_isObk) {
          await _ota.flashObk(d, _pw, r.payload, onStep: _setStep);
        } else {
          if (_needsMinimal) await _flashMinimalFirst(before);
          await _ota.flashTasmota(d, _pw, r.payload, r.uploadName,
              esp32: before.isEsp32, onStep: _setStep);
        }
        _setStep('Waiting for the device to restart…');
        final after = await _ota.waitForDevice(d, _pw, onStep: _setStep);
        _target = after;
        _after = _postChecks(before, after, r);
        await widget.store.refresh(d);
      });

  Future<void> _flashMinimalFirst(FwTarget t) async {
    final src = _ota.tasmotaMinimal();
    _setStep('Downloading the minimal firmware…');
    final bytes = await _ota.download(src);
    final rep = verifyFirmware(bytes, src.fileName, t);
    if (!rep.ok) {
      throw OtaException('Minimal firmware failed verification: '
          '${rep.checks.firstWhere((c) => c.level == CheckLevel.fail).label}');
    }
    await _ota.flashTasmota(d, _pw, rep.payload, rep.uploadName,
        esp32: false, onStep: (s) => _setStep('Minimal: $s'));
    _setStep('Waiting for the minimal firmware to start…');
    final mid = await _ota.waitForDevice(d, _pw, onStep: _setStep);
    if (!mid.version.toLowerCase().contains('minimal')) {
      throw OtaException('Device did not switch to the minimal firmware '
          '(reports ${mid.version}). Nothing else was changed.');
    }
  }

  List<FwCheck> _postChecks(FwTarget before, FwTarget after, FirmwareReport r) {
    final out = <FwCheck>[
      const FwCheck(CheckLevel.ok, 'Device is back online'),
      FwCheck(CheckLevel.ok, 'Now running ${after.version}',
          before.version.isEmpty ? '' : 'was ${before.version}'),
    ];
    final want = _source?.version ?? '';
    if (want.isNotEmpty) {
      out.add(after.versionNumber == want
          ? FwCheck(CheckLevel.ok, 'Version matches the release', want)
          : FwCheck(CheckLevel.fail, 'Version does not match the release',
              'expected $want, device reports ${after.versionNumber}'));
    } else if (after.version == before.version) {
      out.add(const FwCheck(CheckLevel.warn, 'Version string unchanged',
          'fine if you re-flashed the same version'));
    }
    if (_isObk) {
      if (after.obkPlatform != before.obkPlatform) {
        out.add(FwCheck(CheckLevel.warn, 'Platform changed',
            '${before.obkPlatform} → ${after.obkPlatform}'));
      }
    } else {
      final fileVariant =
          r.uploadName.replaceFirst(RegExp(r'\.bin(\.gz)?$'), '');
      if (fileVariant.startsWith('tasmota') &&
          after.tasmotaVariant != fileVariant) {
        out.add(FwCheck(CheckLevel.warn, 'Build variant differs',
            'device reports ${after.tasmotaVariant}'));
      }
      if (after.version.toLowerCase().contains('safeboot')) {
        out.add(const FwCheck(CheckLevel.fail, 'Device is still in safeboot',
            'open its web UI and upload again, or restart it'));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = _target;
    final r = _report;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text('Firmware · ${d.name}')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: t == null
                    ? (_targetError == null
                        ? const LinearProgressIndicator()
                        : Row(children: [
                            Expanded(child: Text(_targetError!)),
                            TextButton(
                                onPressed: _loadTarget,
                                child: const Text('Retry')),
                          ]))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Installed', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 4),
                          Text(t.version.isEmpty ? 'Unknown' : t.version,
                              style: theme.textTheme.titleMedium),
                          if (t.isStepStone)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                  'This is a temporary ${t.codeImage} build. '
                                  'Flash the full ${t.tasmotaVariant} build now.',
                                  style: TextStyle(
                                      color: theme.colorScheme.tertiary)),
                            ),
                          Text([
                            if (t.hardware.isNotEmpty) t.hardware,
                            if (t.freeSketchKb != null)
                              '${t.freeSketchKb} KB free program space',
                          ].join(' · ')),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 8),
            if (t != null) ...[
              FilledButton.icon(
                onPressed: _busy ? null : _official,
                icon: const Icon(Icons.cloud_download_outlined),
                label: Text(_isObk
                    ? 'Latest OpenBeken release'
                    : 'Latest Tasmota release (${t.tasmotaVariant})'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose a file on this phone'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _expected,
                enabled: !_busy,
                autocorrect: false,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Expected SHA-256 (optional)',
                  helperText: 'Paste the checksum from the release page to '
                      'verify the exact file',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text(_step),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Card(
                color: theme.colorScheme.errorContainer,
                child: ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text(_error!),
                ),
              ),
            ],
            if (r != null) ...[
              const SizedBox(height: 16),
              _ReportCard(report: r, origin: _origin),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: r.hasWarnings
                    ? FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.tertiary)
                    : null,
                onPressed:
                    !_busy && r.ok && _after == null ? _confirmAndFlash : null,
                icon: const Icon(Icons.system_update_alt),
                label:
                    Text(r.ok ? 'Flash to ${d.name}' : 'Verification failed'),
              ),
            ],
            if (_after != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Text('After the update',
                          style: theme.textTheme.titleMedium),
                    ),
                    for (final c in _after!) _CheckTile(c),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              _isObk
                  ? 'OpenBeken keeps the old firmware if the new image fails '
                      'its CRC check at boot.'
                  : 'Files are checked on the phone before upload. The device '
                      'is sent exactly the verified bytes, over your LAN.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report, required this.origin});
  final FirmwareReport report;
  final String origin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = report;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Text(r.fileName),
            subtitle:
                Text('${(r.size / 1024).toStringAsFixed(0)} KB · $origin'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText('SHA-256 ${r.sha256}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontFamily: 'monospace')),
                ),
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: r.sha256));
                    showError(context, 'SHA-256 copied');
                  },
                ),
              ],
            ),
          ),
          for (final c in r.checks) _CheckTile(c),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _CheckTile extends StatelessWidget {
  const _CheckTile(this.c);
  final FwCheck c;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (c.level) {
      CheckLevel.ok => (Icons.check_circle, Colors.green),
      CheckLevel.warn => (Icons.warning_amber, Colors.amber.shade800),
      CheckLevel.fail => (Icons.cancel, Colors.red),
    };
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(c.label),
      subtitle: c.detail.isEmpty ? null : Text(c.detail),
    );
  }
}
