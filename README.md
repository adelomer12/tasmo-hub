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
- **Console** for raw commands (`Backlog`, `Rule1`, `Timers`…), with pretty-printed JSON.
- Edit name / room / address / credentials, open the device web UI, restart, remove.
- Polls every N seconds (configurable, or manual) only while the app is in the foreground.
- Devices are keyed by MAC, so a DHCP address change can be fixed by re-scanning.

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
flutter build apk --release          # Android
flutter build ipa                    # iOS (needs Xcode + signing)
```

iOS: for mDNS browsing on a real device Apple requires the
`com.apple.developer.networking.multicast` entitlement; subnet scan works without it.
The first scan triggers the iOS "Local Network" permission prompt.

`.github/workflows/build.yml` builds a release APK as a CI artifact when the code
is pushed to GitHub.

## Roadmap

- MQTT mode (subscribe to `tele/+/STATE` and `stat/+/RESULT` for instant updates)
- Home-screen widgets and quick-settings tiles
- Timers / rules editor, firmware upgrade (`Upgrade 1`) and backup of `Status`/settings
- Scenes across devices
