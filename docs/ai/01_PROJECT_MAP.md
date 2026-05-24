# Project Map

## Repository layout

```
rcj_scoreboard/
├── lib/                        # All Dart/Flutter source
│   ├── main.dart               # Entry point, provider registration, orientation lock
│   ├── models/
│   │   ├── game.dart           # Central game state + timer + MQTT orchestration
│   │   ├── module.dart         # BLE robot module model + all BLE send logic
│   │   └── team.dart           # Team name + score
│   ├── screens/
│   │   ├── home.dart           # Main control UI (double-tap all actions)
│   │   ├── settings.dart       # Game/MQTT/match-data settings screen
│   │   ├── module_settings.dart# Per-module BLE connection screen
│   │   └── mac_qr_scanner.dart # QR code → MAC address scanner
│   ├── services/
│   │   ├── ble.dart            # BLE adapter init/enable helper only
│   │   ├── mqtt.dart           # MQTT publish service + SharedPreferences persistence
│   │   └── match_data.dart     # HTTP match schedule fetch + SharedPreferences
│   └── utils/
│       └── colors.dart         # App color constants (AppColors)
├── android/
│   ├── app/
│   │   ├── build.gradle        # App-level Gradle (AGP 8.1.4, targetSdk 35, NDK 25.x)
│   │   └── src/main/
│   │       ├── AndroidManifest.xml  # BLE + CAMERA + INTERNET permissions
│   │       ├── kotlin/.../MainActivity.kt  # Minimal: extends FlutterActivity
│   │       └── res/
│   │           ├── values/styles.xml       # LaunchTheme + NormalTheme (Light.NoTitleBar)
│   │           └── values-night/styles.xml # Dark variant (Black.NoTitleBar)
│   ├── build.gradle            # Root Gradle (AGP classpath 8.1.4) ← mismatch with settings.gradle
│   ├── settings.gradle         # AGP plugin 8.3.2, Kotlin 1.7.10 ← mismatch
│   └── gradle/wrapper/gradle-wrapper.properties  # Gradle 8.7
├── test/
│   └── widget_test.dart        # Broken smoke test (calls MyApp() without required game param)
├── pubspec.yaml                # Dependencies
├── pubspec.lock                # Locked versions (snapshot from 2025-07-17)
├── .flutter-plugins            # Plugin paths (generated, gitignored)
├── android/key.properties      # SIGNING CREDENTIALS — gitignored — never commit
└── docs/ai/                    # This AI documentation
```

## Entry points

### `lib/main.dart`
- `main()`: `WidgetsFlutterBinding.ensureInitialized()`, locks portrait, creates `Game`, calls `runApp(MyApp(game: game))`
- `MyApp.build()`: `MultiProvider` registering `Game`, 2 `Team`s, and all 10 `Module`s as `ChangeNotifierProvider`

### `android/.../MainActivity.kt`
- Single line: `class MainActivity: FlutterActivity()` — no custom platform channels or plugins

## Key classes and their locations

### `Game` — `lib/models/game.dart:15`
- `ChangeNotifier` root state object
- Owns: `List<Team> teams` (2 teams × 5 modules each), `MqttService`, `MatchDataService`
- Manages: timer (`Timer`), match stage (`MatchStage` enum), score coordination
- Key methods:
  - `gameInit()` — reset everything, re-enable/disable modules by count
  - `startTimer()` / `stopTimer()` / `toggleTimer()` — timer control
  - `playAll(bool removeDamage)` — calls `module.playAll()` or `module.playOrDamageAll()` for all enabled modules (NOT awaited)
  - `stopAll(bool removePenalty, {bool force})` — calls `module.stopAll()` for all enabled modules (NOT awaited)
  - `notifyModulesScore()` — calls `module.bleSendScore()` on all connected modules
  - `loadMatchData()` — async HTTP fetch, populates team names
  - `toggleTeamOrder()` — reverses `teams` list
  - `toggleAllModules()` — smart toggle based on state
  - `halfTimeAll()` / `gameOverAll()` — stop then send special BLE commands with 1s delay

### `Module` — `lib/models/module.dart:33`
- `ChangeNotifier` per-robot model
- Owns: BLE connection state, `BluetoothDevice?`, `BluetoothCharacteristic? bleTX/bleRX`, `ModuleState`, penalty timer
- BLE service UUID: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` (Nordic UART Service)
- BLE TX characteristic: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- BLE RX characteristic: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
- Key BLE send methods (all return `Future<bool>`):
  - `bleSendPlayAll()` — `write([4], timeout:0)` — fire-and-forget PLAY
  - `bleSendStopAll()` — `write([5], timeout:0)` — fire-and-forget STOP
  - `bleSendPlay()` — `write([4])` — confirmed PLAY
  - `bleSendStop()` — `write([5])` — confirmed STOP
  - `bleSendDamage(int seconds)` — 5-byte penalty packet
  - `bleSendHalfTime()` — 5-byte half-time packet with remaining-time millis
  - `bleSendGameOver()` — 3-byte packet with scores
  - `bleSendScore()` — 3-byte score packet (includes 200ms delay before send)
  - `bleSendName()` — 3-byte name packet

### `Team` — `lib/models/team.dart:4`
- `ChangeNotifier`, holds `String _name`, `String id` ('A' or 'B'), `List<Module> modules`, `int score`

### `MqttService` — `lib/services/mqtt.dart:18`
- Not a `ChangeNotifier`; uses `ValueNotifier<MqttConnectionStateEx> connectionStateNotifier`
- Persists settings to `SharedPreferences` (keys: `mqtt_*`)
- Key publish methods: `publishTime`, `publishScore`, `publishTeamNames`, `publishTeam`, `publishGameState`
- Topic structure: `rcj_soccer/[field_N]/[subtopic]`

### `MatchDataService` — `lib/services/match_data.dart:37`
- Not a `ChangeNotifier`; uses `ValueNotifier<String> stateNotifier`
- Persists settings to `SharedPreferences` (keys: `matches_url`, `match_id` — note: match_id not actually persisted)
- Fetches JSON from configurable URL, parses `Match` objects
- Hardcoded default URL in source code (points to external competition API)

### `BLEServices` — `lib/services/ble.dart:9`
- Utility only: `initCheck()` validates BLE adapter state, `enableBLE()` turns it on (Android only)

### UI Screens
- `Home` (`lib/screens/home.dart:13`) — `StatelessWidget`, reads `Game` via `Provider.of`
- `SettingsScreen` (`lib/screens/settings.dart:6`) — `StatefulWidget`, receives `Game` as param
- `ModuleSettingsScreen` (`lib/screens/module_settings.dart:12`) — `StatefulWidget`, reads `Module` via `Provider.of`
- `BarcodeScannerSimple` (`lib/screens/mac_qr_scanner.dart:4`) — returns MAC string via `Navigator.pop`

## BLE message protocol (`BleMsgId` enum, `lib/models/module.dart:18`)

| Index | Name | Payload |
|---|---|---|
| 0 | bleMsgPing | - |
| 1 | bleMsgFwVersion | - |
| 2 | bleMsgSetName | 2 bytes: name chars |
| 3 | bleMsgSetScore | 2 bytes: own score, opponent score |
| 4 | bleMsgPlay | - |
| 5 | bleMsgStop | - |
| 6 | bleMsgDamage | 4 bytes: milliseconds big-endian |
| 7 | bleMsgHalfBreak | 4 bytes: milliseconds big-endian |
| 8 | bleMsgGameOver | 2 bytes: own score, opponent score |
| 9 | bleMsgDisconnect | - |
| 10 | bleMsgAskForPenalty | (incoming from module → triggers penalty) |
| 11 | bleMsgMaxId | sentinel |

## `MatchStage` enum (`lib/models/game.dart:8`)
`firstHalf → halfTime → secondHalf → fullTime`

## `ModuleState` enum (`lib/models/module.dart:8`)
`play, stop, damage, halfTime, fullTime`

## Dependencies (from `pubspec.lock`, July 2025)

| Package | Locked version | Purpose |
|---|---|---|
| provider | 6.1.5 | State management |
| flutter_blue_plus | 1.35.5 | BLE (android plugin: 4.0.5) |
| mobile_scanner | 6.0.10 | QR/barcode scanning (uses MLKit) |
| mqtt_client | 10.3.0 | MQTT |
| shared_preferences | 2.3.3 | Settings persistence |
| http | 1.4.0 | Match data HTTP fetch |
| uuid | 4.5.1 | MQTT client ID generation |
| mask_text_input_formatter | 2.9.0 | MAC address input mask |
| flutter_settings_ui | 3.0.1 | (listed in pubspec but NOT used in code) |

## Native libraries in build output
From `build/app/intermediates/merged_native_libs/`:
- `libflutter.so` — Flutter engine (from Flutter 3.22.2)
- `libbarhopper_v3.so` — MLKit barcode scanner (from mobile_scanner)
- `libimage_processing_util_jni.so` — MLKit image processing (from mobile_scanner)
- `libapp.so` — compiled Dart code (release build)

**All of these require 16 kB page alignment for Android 15 devices with 16 kB page size.**
Flutter 3.22.2 does NOT produce 16 kB-aligned libraries.

## Settings persistence keys (SharedPreferences)
| Key | Owner | Type |
|---|---|---|
| `mqtt_enabled` | MqttService | bool |
| `mqtt_secure_connection` | MqttService | bool |
| `mqtt_auto_connect` | MqttService | bool |
| `mqtt_topic` | MqttService | String |
| `mqtt_port` | MqttService | int |
| `mqtt_server` | MqttService | String |
| `mqtt_username` | MqttService | String |
| `mqtt_password` | MqttService | String |
| `matches_url` | MatchDataService | String |

## Unknowns / not inspected
- iOS `Runner/AppDelegate.swift` — not relevant for Android work but exists (default Flutter AppDelegate)
- `web/` directory exists — Flutter web target, not tested or relevant
- No `linux/` or `windows/` desktop targets
- `module_app.zip` (2.7 MB) in root — likely robot module firmware or companion app, not inspected
- `flutter_settings_ui` is in `pubspec.yaml` but not imported anywhere in Dart code — unused dependency
