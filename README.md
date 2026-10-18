# TasmoHub

A local-only phone app (Android + iOS, Flutter) that discovers and controls
**Tasmota** and **OpenBeken** devices, in the spirit of Tasmotrol.
No cloud, no account, no telemetry: the phone talks straight to each
device's `/cm?cmnd=` HTTP API.

## Features (MVP)

- **Discovery**: subnet scan (`192.168.20.0/24`, `192.168.20.10-80`, or a single IP)
  with bounded concurrency and a TCP pre-check on port 80, plus optional mDNS browse
  of `_http._tcp`. Detects Tasmota vs OpenBeken from `Status 0` (falls back to the web page).
- **Dashboard** grouped by room, with per-relay switches, live sensor headline
  (temperature, humidity, power), online/offline/locked indicator and room "All on / All off".
- **Device page**: all relays, brightness, white temperature (CT), colour hue and presets,
  every sensor from `StatusSNS` (energy, climate, etc.), firmware/hardware/IP/MAC/Wi-Fi/uptime.
- **Timers** (Tasmota): global *Timer control active* switch and Timer1–16 cards with
  enable, action (on/off/toggle/rule), output, time or sunrise/sunset offset, weekdays,
  repeat and random window. Works over HTTP and MQTT.
- **Energy card** with power, voltage, current and Reset for today / yesterday / total,
  plus device time and an app-side **Lock switching** toggle per device.
- **Android widgets and Quick Settings tiles**: a 1x1 resizable widget and three tiles
  (*TasmoHub 1–3*), each bound to one device output via a picker. They toggle over local
  HTTP without starting the app; passwords for them are encrypted with an Android
  Keystore key. Long-press a tile or reconfigure a widget to change its device.
- **Rules editor** for Tasmota Rule1-3: enable, Once, Stop-on-error, one trigger per line, example snippets.
- **Scenes**: named groups of commands across devices (relay on/off/toggle, dimmer, CT, colour or any command), run from chips on the home screen; capture a device's current state as steps.
- **Firmware update (OTA) with verification**: download the latest official release for the device's chip and build variant (HTTPS only), or pick a file. Before anything is sent the app checks the file: gzip CRC, ESP image checksums, ESP32 chip ID, the SHA-256 built into ESP32 images, factory/bootloader images rejected, free program space (ESP8266 flashes the minimal build first when needed), and the SHA-256 against the GitHub release digest or one you paste. After the upload it waits for the device and confirms the version it now runs. OpenBeken: platform-matched OTA file (`.rbl` etc.) via `/api/ota`.
- **Console** for raw commands (`Backlog`, `Rule1`, `Timers`…), with pretty-printed JSON.
- Edit name / room / address / credentials, open the device web UI, restart, remove.
- Optional MQTT: live push updates, control through the broker, Tasmota MQTT discovery.
- Polls every N seconds (configurable, or manual) only while the app is in the foreground.
- Devices are keyed by MAC, so a DHCP address change can be fixed by re-scanning.

## MQTT (optional)

Menu → **MQTT broker**: host, port, TLS (with an explicit, off-by-default
"accept self-signed" switch), username/password (stored in the keystore).

- **Live updates**: subscribes per device to `stat/<topic>/#` and `tele/<topic>/#`
  (honours a custom `FullTopic` and prefixes), and handles `LWT`, `STATE`, `SENSOR`,
  `RESULT`, `POWERn` and `STATUS0/8/10`. Polling skips MQTT devices, which push changes.
- **Control over MQTT**: commands go to `cmnd/<topic>/<Command>` and wait for
  `stat/<topic>/RESULT`. This works even when the phone cannot reach the IoT VLAN
  over HTTP, as long as it can reach the broker. Can be turned off so MQTT is
  used for updates only.
- **Broker discovery**: reads Tasmota's retained `tasmota/discovery/<MAC>/config`
  (SetOption19 0, the default) and lists those devices in *Find devices* without
  any network scan. Saved devices whose IP changed get updated automatically.
- The MQTT topic is picked up from `Status 0` for HTTP-added devices and can be
  edited per device. OpenBeken devices are controlled through the Tasmota-style
  `cmnd/<topic>/...` topics; if a build does not publish `stat/` replies, HTTP still
  covers its state.

Suggested broker hardening: per-user ACLs (the app's user only needs
`cmnd/#` write and `stat/#`, `tele/#`, `tasmota/discovery/#` read), TLS on 8883,
and no anonymous access.

## Security model

- Web passwords are stored in the Android Keystore / iOS Keychain
  (`flutter_secure_storage`), never in plain preferences; Android backup is disabled.
- Tasmota only accepts credentials as URL query parameters over plain HTTP, so they
  travel in clear text on the LAN. Put IoT devices on their own VLAN, allow the phone
  (or a trusted VLAN) to reach them on TCP/80 only, and never port-forward them.
  Use WireGuard to reach them from outside.
- The app warns when you add a non-private address.

### MikroTik notes

- If the phone is on a different VLAN than the devices, type the IoT subnet in the
  scan field; you need a forward rule from the trusted VLAN to the IoT VLAN on TCP/80.
- mDNS is link-local and will not cross VLANs unless you enable an mDNS repeater
  (`/ip dns set mdns-repeat-ifaces=...` on RouterOS 7.16+). The subnet scan does not need it.

## Build

```bash
flutter pub get
flutter test
# optional, against a real broker:
MQTT_LIVE_PORT=1883 MQTT_LIVE_PW=... flutter test test/mqtt_live_test.dart
flutter build apk --release          # Android
flutter build ipa                    # iOS (needs Xcode + signing)
```

iOS: for mDNS browsing on a real device Apple requires the
`com.apple.developer.networking.multicast` entitlement; subnet scan works without it.
The first scan triggers the iOS "Local Network" permission prompt.

`.github/workflows/build.yml` builds a release APK as a CI artifact when the code
is pushed to GitHub.

## F-Droid

The repo is set up to be built by F-Droid from source:

- Store text, icon and per-version changelogs live in `fastlane/metadata/android/en-US/`.
  Add `changelogs/<versionCode>.txt` (500 characters max) whenever the version in
  `pubspec.yaml` goes up; CI warns when it is missing.
- CI tags `v<version>` on `main` after a passing build; F-Droid picks up new releases from those tags.
- `TASMOHUB_UNSIGNED=1 flutter build apk --release` builds the unsigned APK F-Droid signs itself.
- `fdroid/com.adelhajjaj.tasmo_hub.yml` is the draft recipe for the fdroiddata repository.

F-Droid signs with its own key, so its build cannot update an APK installed from
GitHub Actions (or the other way round) without uninstalling first.

## License

GPL-3.0-or-later, see [LICENSE](LICENSE).

## Roadmap

- iOS widgets
