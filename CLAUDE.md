# RCJ Soccer RefMate — CLAUDE.md

## What this project is
Cross-platform **Android + iOS (iPhone)** Flutter app (portrait-only) that controls RoboCup Junior Soccer robot modules via BLE and publishes match data via MQTT. Up to 10 robot modules are connected simultaneously. The UI is intentionally protected against accidental touch by requiring **double-tap** for all critical actions (start/stop robots, score goals, toggle timer). **Every change must work on both Android and iOS** (iOS support was added with Fabian; e.g. App Links on Android map to Universal Links on iOS).

## Critical invariants — never violate these
1. **Robot START/STOP latency**: `bleSendPlayAll()` and `bleSendStopAll()` use `timeout:0` (fire-and-forget) and are launched without `await` so all modules fire simultaneously. Never add awaits, blocking calls, queues, or synchronization that could delay or serialize robot commands.
2. **Double-tap/long-press safety**: All destructive UI actions (play/stop all, score, timer toggle, disconnect) default to `onDoubleTap`. The gesture is now routed through `CriticalGestureDetector`/`CriticalButton` so a user-facing Settings toggle (`Game.singleTapEnabled`, **default `false`**) can opt into single-tap. Never hardcode these sites back to a bare `onTap`, and never change the default away from double-tap — only the explicit opt-in may relax it.
3. **Provider tree integrity**: `Game`, both `Team`s, and all 10 `Module`s are registered as `ChangeNotifierProvider` in `main.dart`. The module provider list is static. Do not restructure provider registration without understanding this.
4. **Portrait-only**: `SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp])` is set in `main()`. Do not remove.
5. **BLE auto-reconnect is delegated to `connect(autoConnect:true)` — no manual loop, no cap (NOT a bug)**: per-module reconnection is owned entirely by the OS. `connect(autoConnect:true)` is called **once** and the platform retries **indefinitely on the same GATT client** until `disconnect()` is called. This is intentional and required: modules are powered off *on purpose* during a match (a penalised robot ~1 min, the halftime break ~5 min) and must rejoin the instant they return, with no referee action. A module stuck on "Connecting…" mid-match is intended; a genuinely-dead one is dismissed via the manual **Cancel** button. **Do NOT add an app-level reconnect loop (re-calling `bleConnect()`/`connect()` on each disconnect event) or a per-attempt cap.** A manual 2 s loop was tried (#42) and **device-verified** (Pixel 10, 3 modules) to leak ~1 GATT client per reconnect per module — each re-`connect()` registers a fresh `clientIf` without `close()`-ing the previous `BluetoothGatt` — exhausting Android's ~30-client ceiling within minutes of penalty/halftime cycling across 10 modules, which fails the whole field mid-match. Post-match teardown (so autoConnect doesn't chase units powered down for good) is a one-shot at the `MatchStage.fullTime` transition via `Game.disconnectInactiveModules`, **not** a per-disconnect action. The disconnect handler only reflects status. See `Module._onConnectionState`, `Game.disconnectInactiveModules`, and `docs/ai/02_RUNTIME_ARCHITECTURE.md` ("Auto-reconnect policy").

## Toolchain versions (as of 2026-06-01, shipped in Play release 0.9.8)
- Flutter: **3.44.0** / Dart 3.12 — upgraded (was 3.22.2); gives 16 kB page alignment
- Android Gradle Plugin: **8.11.1** (settings.gradle) — mismatch resolved
- Gradle wrapper: **8.14**
- NDK: **r28.2 (28.2.13676358)** — 16 kB page alignment
- targetSdk: **35**, minSdk: **24** (Flutter 3.44 raised its default from 21; Android 5–6 dropped, accepted)
- Kotlin: **2.2.20**

> Note: Flutter 3.44 build emits non-breaking KGP warnings from `mobile_scanner`
> and `shared_preferences_android` (upstream plugins) — expected, not actionable.

## State management
`provider` package. `Game` is the root `ChangeNotifier`. `Team` and `Module` are also `ChangeNotifier`. All are pre-registered in `MultiProvider` at app start.

## Key files
| Path | Role |
|---|---|
| `lib/main.dart` | Entry point, provider setup |
| `lib/models/game.dart` | `Game`: teams, match clock + stage machine, robot fan-out, MQTT/bridge sinks, settings |
| `lib/models/game_scoreboard.dart` | part of `game.dart`: scoreboard fixture apply/pair, result review + submit |
| `lib/models/game_resume.dart` | part of `game.dart`: cold-resume snapshot build/restore |
| `lib/models/match_persistence.dart` | `MatchPersistence`: dirty flag / coalesced flush / clear of the resume snapshot |
| `lib/models/ios_mac_pairing.dart` | `IosMacPairing`: iOS MAC→UUID cache + resolver bookkeeping (#82) |
| `lib/models/scoreboard_binding.dart` | `ScoreboardBinding`: side mapping, signatures, resumed-fixture state |
| `lib/models/module.dart` | `Module`: robot state machine + BLE link, all BLE frames (`bleSendPlayAll`/`bleSendStopAll` fire-and-forget) |
| `lib/models/team.dart` | Team name + score |
| `lib/models/scoreboard_result.dart` | `ScoreboardMatchConfig`, `ResultOutboxItem`, inspection / module report rows |
| `lib/models/bridge_message.dart` | `BridgeMessage` framing (`topic\x00value`) + `BridgeTopics` |
| `lib/services/scoreboard_result_service.dart` | Deep-link fixture staging/commit, retrying result outbox |
| `lib/services/referee_link.dart` | `parseRefereeLink`: https / `rcjrefmate://` link parsing |
| `lib/services/mqtt.dart` | MQTT publish, serialized connect, bounded reconnect |
| `lib/services/ble_bridge_service.dart` | BLE scoreboard bridge: MQTT-over-BLE publish, dedup queue, write-with-response ACK |
| `lib/services/ios_mac_resolver.dart` | iOS batch-scan resolve loop; scans only between play, stops at kickoff |
| `lib/services/match_state_store.dart` | Snapshot schema + tombstoned, coalesced prefs writes |
| `lib/services/match_data.dart` | HTTP fetch of the catigoal match schedule |
| `lib/services/ble_adapter_monitor.dart` | App-wide BLE adapter state (Home banner, module screen status) |
| `lib/utils/ble_address.dart` | MAC/UUID formats, `RCJs-m_<MAC>` name parsing, batch scan resolve |
| `lib/utils/format.dart` | `formatClock`, `parseMmSs`, kickoff/duration formatting |
| `lib/widgets/critical_gesture_detector.dart` | `CriticalGestureDetector` + `CriticalButton` — single/double-tap gating |
| `lib/widgets/app_dialogs.dart` | `showChoiceDialog` / `showInfoDialog` / `showTextInputDialog` / `showDarkSheet` |
| `lib/widgets/game_prompts.dart` | `GamePrompts`: the four Game→Home dialogs (side switch, resume, load, review) |
| `lib/widgets/` (module_button, team_panel, time_settings_sheet, settings_widgets, module_presets_section, bluetooth_banner) | Home/Settings building blocks |
| `lib/screens/home.dart` | Main control UI |
| `lib/screens/settings.dart` | All settings (MQTT, bridge, game params, match data) |
| `lib/screens/module_settings.dart` | Per-module BLE connect/scan/QR |
| `lib/screens/scoreboard_result_review.dart` | Full-time result review + submit |
| `lib/screens/mac_qr_scanner.dart` | QR scan to MAC address (+ iOS UUID resolve helper) |
| `android/app/build.gradle` | Android build config |
| `android/app/src/main/AndroidManifest.xml` | Permissions |

## Shipped (Play release 0.9.8 / versionCode 10, 2026-06-01, tag `v0.9.8`)
1. **Android 15 / Google Play compliance** — Flutter 3.44 upgrade, NDK r28.2, AGP
   8.11.1, Gradle 8.14, Kotlin 2.2.20; 16 kB page alignment verified (64-bit ABIs).
2. **BLE bridge feature (iteration 1)** — MQTT-over-BLE scoreboard bridge. Phone
   publishes the same `(topic,value)` data to both MQTT and the bridge; the bridge
   path is fully separate from robot control. See `05_BLE_BRIDGE_FEATURE_PLAN.md`.
   Firmware lives in a separate FW repo (written by the owner).
3. **UI polish** — module/bridge "Connecting…" status (autoConnect no longer flashes
   "Disconnected" mid-retry), Cancel a stuck "Connecting…" module, adaptive launcher
   icon + Android-12 splash.

## Planned / possible future work
- **BLE hub topology (deferred)** — use the bridge as a hub holding the 10 modules so
  the phone keeps a single BLE link, working around the ~8-GATT phone ceiling. The
  hub→module broadcast transport is the crux for the START/STOP latency invariant.
- Big-match (10 robots + scoreboard) capacity is currently solved by phone selection
  (Galaxy A52s handles 10+ connections), not by the hub.

## Where to read more
See `docs/ai/00_CONTEXT_INDEX.md` for the full reading order and per-topic pointers.

## Device-testing the scoreboard flow (local mock)
Runbook: `docs/ai/07_SCOREBOARD_DEVICE_TESTING.md`; mock: `docs/ai/tools/mock_scoreboard.py`
(stdlib GET/POST mock; now also serves `home/away_inspection_robots`). Flow:
`adb reverse tcp:8000 tcp:8000` → start mock → `adb shell am start -a
android.intent.action.VIEW -d 'rcjrefmate://r/tok?base_url=http://127.0.0.1:8000'`.
Android app id is **`com.robocup.rcj_soccer`**.

> **Env gotcha — `pkill -f mock_scoreboard.py` self-kills the shell (exit 144).**
> A Bash tool call runs as `bash -c '…mock_scoreboard.py…'`, so its **own argv
> contains the pattern** — `pkill -f mock_scoreboard.py` matches and kills the
> launching shell before anything runs, surfacing as **exit code 144** (looks
> like a network/sandbox block, but isn't). Fixes:
> - **Launch** the mock as a `run_in_background` Bash task with **no** self-matching
>   `pkill` in the same command (log to the scratchpad dir, not `/tmp`).
> - **Kill** it with the bracket trick so the pattern can't match the killer:
>   `pkill -f '[m]ock_scoreboard\.py'` (or kill by PID). Same rule for `pgrep`.
