# RCJ Soccer RefMate — CLAUDE.md

## What this project is
Android Flutter app (portrait-only) that controls RoboCup Junior Soccer robot modules via BLE and publishes match data via MQTT. Up to 10 robot modules are connected simultaneously. The UI is intentionally protected against accidental touch by requiring **double-tap** for all critical actions (start/stop robots, score goals, toggle timer).

## Critical invariants — never violate these
1. **Robot START/STOP latency**: `bleSendPlayAll()` and `bleSendStopAll()` use `timeout:0` (fire-and-forget) and are launched without `await` so all modules fire simultaneously. Never add awaits, blocking calls, queues, or synchronization that could delay or serialize robot commands.
2. **Double-tap/long-press safety**: All destructive UI actions (play/stop all, score, timer toggle, disconnect) use `onDoubleTap`. Do not change them to `onTap`.
3. **Provider tree integrity**: `Game`, both `Team`s, and all 10 `Module`s are registered as `ChangeNotifierProvider` in `main.dart`. The module provider list is static. Do not restructure provider registration without understanding this.
4. **Portrait-only**: `SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp])` is set in `main()`. Do not remove.

## Toolchain versions (as of last analysis)
- Flutter: **3.22.2** / Dart 3.4.3 — **upgrade to ≥3.27.x is planned** for Android 15 / 16 kB page fixes
- Android Gradle Plugin: 8.1.4 (build.gradle) / 8.3.2 (settings.gradle) — **mismatch, needs cleanup**
- Gradle wrapper: **8.7**
- NDK: **25.1.8937393** — planned upgrade to r28 for 16 kB page alignment
- targetSdk: **35**, minSdk: **21**
- Kotlin: **1.7.10** — old, upgrade planned

## State management
`provider` package. `Game` is the root `ChangeNotifier`. `Team` and `Module` are also `ChangeNotifier`. All are pre-registered in `MultiProvider` at app start.

## Key files
| Path | Role |
|---|---|
| `lib/main.dart` | Entry point, provider setup |
| `lib/models/game.dart` | Central game state, timer, MQTT orchestration |
| `lib/models/module.dart` | BLE per-module logic, all BLE send methods |
| `lib/models/team.dart` | Team name + score |
| `lib/services/ble.dart` | BLE adapter init/enable only |
| `lib/services/mqtt.dart` | MQTT publish, connection management |
| `lib/services/match_data.dart` | HTTP fetch of match schedule |
| `lib/screens/home.dart` | Main control UI |
| `lib/screens/settings.dart` | All settings (MQTT, game params, match data) |
| `lib/screens/module_settings.dart` | Per-module BLE connect/scan/QR |
| `lib/screens/mac_qr_scanner.dart` | QR scan to MAC address |
| `android/app/build.gradle` | Android build config |
| `android/app/src/main/AndroidManifest.xml` | Permissions |

## Planned work
1. **Android 15 / Google Play compliance** — edge-to-edge, deprecated window APIs, 16 kB page size (all require Flutter upgrade)
2. **BLE bridge feature** — second BLE device type for reliable match data forwarding; must not touch robot control path

## Where to read more
See `docs/ai/00_CONTEXT_INDEX.md` for the full reading order and per-topic pointers.
