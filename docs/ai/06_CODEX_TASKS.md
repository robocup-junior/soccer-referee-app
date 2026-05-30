# Codex Task Queue

Tasks are ordered sequentially within each group. Complete PLAY tasks before BRIDGE tasks.
Each task is designed to be small and independently verifiable.

---

## Group PLAY — Android 15 / Google Play Compliance

### PLAY-01 — Fix AGP version mismatch

**Goal**: Make `android/build.gradle` and `android/settings.gradle` consistent on a single AGP version.

**Context files to read first**:
- `docs/ai/04_ANDROID15_PLAY_COMPLIANCE_PLAN.md` → "Current configuration" table
- `android/build.gradle`
- `android/settings.gradle`

**Target files to modify**:
- `android/build.gradle`

**Files/areas NOT to touch**:
- `android/settings.gradle` (keep its AGP 8.3.2 declarative plugin block as the source of truth)
- `android/app/build.gradle`
- Any Dart/Flutter files

**Implementation**:
1. Open `android/build.gradle`
2. Remove the entire `buildscript { }` block (lines ~8-16). This block declares `classpath "com.android.tools.build:gradle:8.1.4"` which conflicts with the declarative plugin in `settings.gradle`.
3. The `buildscript` block is redundant when using the new declarative plugin system in `settings.gradle`.
4. Keep the `allprojects { }` block, `rootProject.buildDir`, `subprojects`, and `clean` task.

**Acceptance criteria**:
- `android/build.gradle` no longer contains a `buildscript` block
- `android/settings.gradle` still declares `id "com.android.application" version "8.3.2"`
- `grep -n "buildscript\|classpath.*gradle" android/build.gradle` returns no matches

**Verification commands**:
```bash
grep -n "buildscript\|classpath.*gradle" android/build.gradle
cat android/build.gradle
```

**Manual test**: Full build is NOT required. Code review only.

**Risks**: Very low. This removes a redundant block.

**Rollback**: Revert the change to `android/build.gradle`.

---

### PLAY-02 — Upgrade Kotlin plugin version

**Goal**: Update Kotlin plugin from 1.7.10 to a version compatible with AGP 8.3.2.

**Context files to read first**:
- `android/settings.gradle` (current: `org.jetbrains.kotlin.android version "1.7.10"`)
- `docs/ai/04_ANDROID15_PLAY_COMPLIANCE_PLAN.md`

**Target files to modify**:
- `android/settings.gradle`

**Files/areas NOT to touch**:
- Any Dart/Flutter files
- `android/app/build.gradle`
- `android/build.gradle`

**Implementation**:
1. In `android/settings.gradle`, change `id "org.jetbrains.kotlin.android" version "1.7.10"` to `id "org.jetbrains.kotlin.android" version "1.9.25"` (latest stable compatible with AGP 8.3.2)
2. Verify AGP 8.3.2 compatibility with Kotlin 1.9.x: confirmed compatible.

**Acceptance criteria**:
- `grep "kotlin.android" android/settings.gradle` shows version `1.9.25`

**Verification commands**:
```bash
grep "kotlin.android" android/settings.gradle
```

**Risks**: Low. Kotlin 1.9.x is backwards compatible with 1.7.x for this app (no advanced Kotlin features used in the single-line MainActivity).

**Rollback**: Revert `settings.gradle` change.

---

### PLAY-03 — Upgrade Flutter SDK (manual step — Codex assists with plan only)

**Goal**: Document the exact commands to upgrade Flutter from 3.22.2 to the latest stable ≥3.27.x.

**IMPORTANT**: Codex must NOT run `flutter upgrade` or `flutter pub upgrade`. This is a human-executed step. Codex should only verify the current version and check what version is available.

**Context files to read first**:
- `docs/ai/04_ANDROID15_PLAY_COMPLIANCE_PLAN.md`
- `CLAUDE.md` → toolchain section

**Target files to modify**: NONE (documentation update only)

**Implementation — provide these commands for the human to run**:
```bash
# Check current version
flutter --version

# Switch to latest stable
flutter channel stable
flutter upgrade

# Verify new version
flutter --version

# Update pub dependencies to match new Flutter
flutter pub get

# Check for breaking changes
flutter analyze
```

**Post-upgrade checks Codex should perform after human runs upgrade**:
```bash
# Verify Flutter version
flutter --version

# Check pub dependencies are resolved
cat pubspec.lock | grep "flutter_blue_plus\|mobile_scanner"

# Run analyze
flutter analyze
```

**Acceptance criteria**:
- `flutter --version` shows ≥3.27.0
- `flutter analyze` shows 0 errors

**Risks**: Flutter upgrade can introduce breaking API changes. Review `flutter analyze` output carefully after upgrade.

---

### PLAY-04 — Update NDK version

**Goal**: Update NDK from 25.1.8937393 to r26b for 16 kB page size support.

**Context files to read first**:
- `android/app/build.gradle` (current: `ndkVersion "25.1.8937393"`)
- `docs/ai/04_ANDROID15_PLAY_COMPLIANCE_PLAN.md` → Warning C section

**Target files to modify**:
- `android/app/build.gradle`

**Files/areas NOT to touch**:
- Any Dart/Flutter files
- `android/settings.gradle`
- `android/build.gradle`

**Pre-requisite**: Human must install NDK r26b via Android Studio SDK Manager first.
NDK r26b version string: `26.3.11579264`

**Implementation**:
1. In `android/app/build.gradle`, change `ndkVersion "25.1.8937393"` to `ndkVersion "26.3.11579264"`

**Acceptance criteria**:
- `grep ndkVersion android/app/build.gradle` shows `26.3.11579264`

**Verification commands**:
```bash
grep ndkVersion android/app/build.gradle
ls "$ANDROID_SDK/ndk/26.3.11579264" 2>/dev/null && echo "NDK r26b installed" || echo "NDK r26b NOT installed"
```

**Manual test**: Build required to verify NDK is found. `flutter build apk --debug` (do not release build).

**Risks**: Medium. NDK version change requires NDK r26b to be installed. Build will fail if NDK is not installed.

**Rollback**: Revert `ndkVersion` to `"25.1.8937393"`.

---

### PLAY-05 — Update compileSdk to 35

**Goal**: Set `compileSdk = 35` explicitly in `android/app/build.gradle` instead of relying on `flutter.compileSdkVersion` (which is 34 for Flutter 3.22.2).

**Note**: After Flutter upgrade (PLAY-03), `flutter.compileSdkVersion` may already be 35. Verify first.

**Context files to read first**:
- `android/app/build.gradle`
- `docs/ai/04_ANDROID15_PLAY_COMPLIANCE_PLAN.md`

**Target files to modify**:
- `android/app/build.gradle`

**Implementation**:
1. Check `cat android/app/build.gradle`
2. If `compileSdk = flutter.compileSdkVersion` and the value is not 35:
   - Change to `compileSdk = 35`
3. If `flutter.compileSdkVersion` is already 35 (after Flutter upgrade), leave unchanged.

**Acceptance criteria**:
- `grep compileSdk android/app/build.gradle` shows either `compileSdk = 35` or `compileSdk = flutter.compileSdkVersion` where flutter.compileSdkVersion resolves to 35

**Verification commands**:
```bash
grep compileSdk android/app/build.gradle
```

**Risks**: Low.

---

### PLAY-06 — Add SafeArea to all screens for edge-to-edge

**Goal**: Wrap Scaffold body content in `SafeArea` in all 4 screens to prevent UI overlap with status bar and navigation bar on Android 15.

**Context files to read first**:
- `docs/ai/04_ANDROID15_PLAY_COMPLIANCE_PLAN.md` → Warning A section
- `lib/screens/home.dart`
- `lib/screens/settings.dart`
- `lib/screens/module_settings.dart`
- `lib/screens/mac_qr_scanner.dart`

**Target files to modify**:
- `lib/screens/home.dart`
- `lib/screens/settings.dart`
- `lib/screens/module_settings.dart`
- `lib/screens/mac_qr_scanner.dart`

**Files/areas NOT to touch**:
- `lib/models/` — no model changes
- `lib/services/` — no service changes
- The double-tap gesture detectors — do NOT wrap them in a way that reduces touch targets

**Implementation**:

For `home.dart`:
- Locate the `Scaffold` widget's `body:` property
- Wrap the outermost `Padding` (currently `Padding(padding: EdgeInsets.all(8.0), ...)`) with `SafeArea`
- Preserve `resizeToAvoidBottomInset: false` on the Scaffold (it is already there)
- Result: `body: SafeArea(child: Padding(padding: EdgeInsets.all(8.0), child: Column(...)))`

For `settings.dart`:
- Wrap the `Padding(padding: EdgeInsets.all(16.0), child: Column(...))` in `body:` with `SafeArea`

For `module_settings.dart`:
- Wrap the `Padding(padding: EdgeInsets.all(10.0), child: Column(...))` in `body:` with `SafeArea`

For `mac_qr_scanner.dart`:
- The `Stack` contains `MobileScanner` (fills screen) and an `Align(alignment: Alignment.bottomCenter, child: Container(height: 100, ...))` for the info bar
- Add `SafeArea(bottom: true, top: false, child: ...)` around the bottom `Align` container so it appears above the navigation bar
- Do NOT add SafeArea around the full-screen `MobileScanner` (it should fill the screen including under system bars for proper camera view)

**Acceptance criteria**:
- `grep -n "SafeArea" lib/screens/*.dart` shows SafeArea in all 4 files
- `flutter analyze` returns 0 errors
- Visual inspection on Android 15 device/emulator: no UI cut off

**Verification commands**:
```bash
grep -n "SafeArea" lib/screens/home.dart lib/screens/settings.dart lib/screens/module_settings.dart lib/screens/mac_qr_scanner.dart
flutter analyze
```

**Manual test**: Run on Android 15 emulator or device with gesture navigation. Verify bottom button visible.

**Risks**: Low. SafeArea is purely additive. The only risk is reduced available screen height on small phones. Verify robot module buttons still have adequate tap targets.

**Rollback**: Remove the SafeArea wrappers.

---

### PLAY-07 — Add packagingOptions for uncompressed native libs

**Goal**: Add `jniLibs.useLegacyPackaging = false` to ensure native `.so` files are stored uncompressed in the APK, which is required for proper 16 kB page alignment mapping.

**Pre-requisite**: PLAY-03 (Flutter upgrade) and PLAY-01 (AGP fix) must be complete.

**Context files to read first**:
- `android/app/build.gradle`
- `docs/ai/04_ANDROID15_PLAY_COMPLIANCE_PLAN.md` → Warning C → Gradle flag section

**Target files to modify**:
- `android/app/build.gradle`

**Implementation**:
Add inside the `android { }` block in `android/app/build.gradle`:
```groovy
packagingOptions {
    jniLibs {
        useLegacyPackaging = false
    }
}
```
Place this block after the `buildTypes { }` block and before `flutter { source = "../.." }`.

**Acceptance criteria**:
- `grep -A3 "packagingOptions" android/app/build.gradle` shows the jniLibs block

**Verification commands**:
```bash
grep -A5 "packagingOptions" android/app/build.gradle
# After build:
python3 - <<'EOF'
import zipfile
with zipfile.ZipFile('build/app/outputs/flutter-apk/app-release.apk') as z:
    for info in z.infolist():
        if info.filename.endswith('.so'):
            print(f"{info.filename.split('/')[-1]:45s} compress={info.compress_type}")
EOF
```
Verify `compress_type=0` (stored, not compressed) for all `.so` files.

**Risks**: Low. This only affects APK packaging, not code behavior.

---

## Group AUDIT — Bug Fixes

### AUDIT-FIX-01 — Fix broken widget test

**Goal**: Make `test/widget_test.dart` compile and pass without requiring BLE hardware or external services.

**Context files to read first**:
- `test/widget_test.dart`
- `lib/main.dart` (MyApp constructor signature)
- `docs/ai/03_AUDIT_FINDINGS.md` → AUDIT-02

**Target files to modify**:
- `test/widget_test.dart`

**Implementation**:
Replace the test content with a minimal smoke test:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/main.dart';
import 'package:rcj_scoreboard/models/game.dart';

void main() {
  testWidgets('App starts without crashing', (WidgetTester tester) async {
    final game = Game();
    await tester.pumpWidget(MyApp(game: game));
    expect(find.text('RCJ Soccer - RefMate'), findsOneWidget);
  });
}
```

**Acceptance criteria**:
- `flutter test` exits 0
- Test name: 'App starts without crashing' passes

**Verification commands**:
```bash
flutter test
```

**Risks**: Low. Test isolation — Game constructor calls MqttService and MatchDataService which use SharedPreferences. In test environment, SharedPreferences must be initialized. May need `SharedPreferences.setMockInitialValues({})` setup.

**Rollback**: Revert `widget_test.dart`.

---

### AUDIT-FIX-02 — Fix scan listener leak in ModuleSettingsScreen

**Goal**: Prevent multiple `scanResults` stream subscriptions from accumulating when user presses "Scan" multiple times.

**Context files to read first**:
- `lib/screens/module_settings.dart` (lines 73-105)
- `docs/ai/03_AUDIT_FINDINGS.md` → AUDIT-04

**Target files to modify**:
- `lib/screens/module_settings.dart`

**Files/areas NOT to touch**:
- Any model or service files

**Implementation**:
1. Add a field: `StreamSubscription<List<ScanResult>>? _scanSubscription;`
2. In `startScanning()`, before the new `FlutterBluePlus.scanResults.listen(...)` call:
   - Add `await _scanSubscription?.cancel();`
3. Assign the result: `_scanSubscription = FlutterBluePlus.scanResults.listen(...);`
4. In `dispose()`, add `_scanSubscription?.cancel();`

**Acceptance criteria**:
- `grep "_scanSubscription" lib/screens/module_settings.dart` shows field declaration, assignment, and cancel calls
- `flutter analyze` returns 0 errors

**Verification commands**:
```bash
grep -n "_scanSubscription\|scanResults.listen" lib/screens/module_settings.dart
flutter analyze
```

**Risks**: Very low. Pure cleanup.

---

### AUDIT-FIX-03 — Persist game parameters across app restarts

**Goal**: Persist `periodTime`, `halfTimeDuration`, `numberOfPLayers`, `penaltyTime` to SharedPreferences.

**Context files to read first**:
- `lib/models/game.dart`
- `docs/ai/03_AUDIT_FINDINGS.md` → AUDIT-09

**Target files to modify**:
- `lib/models/game.dart`

**Files/areas NOT to touch**:
- `lib/screens/settings.dart` — setters are already called there correctly
- BLE-related methods

**Implementation**:
1. Add `import 'package:shared_preferences/shared_preferences.dart';` to `game.dart`
2. Add a `SharedPreferences? _prefs;` field to `Game`
3. Convert the four public fields into private backing fields with getters and
   setters. The setter writes the new value through to SharedPreferences:
   ```dart
   int _periodTime = 600;
   int get periodTime => _periodTime;
   set periodTime(int v) { _periodTime = v; _prefs?.setInt('game_period_time', v); }
   ```
   Do the same shape for `halfTimeDuration`, `numberOfPLayers`, `penaltyTime`.
   NOTE: `lib/screens/settings.dart` already assigns these fields directly (e.g.
   `widget.game.periodTime = value.values;`) — turning them into setters must keep
   those assignments working unchanged.
4. Add `Future<void> _loadPrefs()` method that:
   - does `_prefs = await SharedPreferences.getInstance();`
   - reads the 4 keys with default fallbacks (see keys below)
   - **assigns the read values to the private backing fields directly (NOT through
     the setters)** — otherwise you immediately write the just-read value back to
     disk.
   - **clamps `game_num_players` to the range 1–5 on load** — an out-of-range
     stored value would break the module enable loop in `gameInit()`.
   - if not currently in a running game (`inGame == false`), calls `gameInit()` so
     the loaded values take effect (e.g. `_remainingTime` picks up `periodTime`)
   - calls `notifyListeners();`
5. Call `_loadPrefs()` **unawaited** at the end of the `Game()` constructor (the
   constructor stays synchronous; defaults hold until prefs load, then refresh).

SharedPreferences keys to use:
- `game_period_time` (int, default: 600)
- `game_halftime_duration` (int, default: 300)
- `game_num_players` (int, default: 2, clamp loaded value to 1–5)
- `game_penalty_time` (int, default: 60)

**Acceptance criteria**:
- After changing game duration in settings, killing the app, and restarting, the same duration is shown in settings

**Verification commands**:
```bash
flutter analyze
grep -n "SharedPreferences\|_prefs\|game_period" lib/models/game.dart
```

**Manual test**: Set game duration to 2 mins, kill app, restart, verify 2 mins is still selected. Repeat sanity check for number of players, halftime, and penalty time.

**Risks**: Medium. `Game` constructor is synchronous; SharedPreferences is async. The fields must have sensible defaults until prefs load. Use `late` with defaults or a `FutureBuilder` approach. Simplest: keep defaults in field initializers, call `_loadPrefs()` async from constructor (unawaited), then call `gameInit()` again once loaded.

**Required handoff report**: After finishing, write a report to
`docs/ai/handoff/AUDIT-FIX-03_REPORT.md` (create the `handoff/` folder if needed)
containing:
- **Summary**: one paragraph on what changed.
- **Files changed**: list each file + a one-line description.
- **Deviations**: anything you did differently from this spec and why (write
  "none" if you followed it exactly).
- **Verification results**: paste the actual output of `flutter analyze` and the
  `grep` command above.
- **Manual test status**: state whether you ran the kill/restart test on a device
  or emulator; if you could not, say so explicitly.
- **Open questions / risks**: anything the reviewer should double-check.
Keep it concise and factual. Do not include secrets (MQTT credentials, signing
keys). This file is how the reviewing agent verifies your work.

---

## Group BRIDGE — BLE Bridge Feature

Complete tasks in order. Read `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md` before starting.

### Required handoff report (applies to EVERY BRIDGE task)

After finishing each BRIDGE-NN task, append a section to a single cumulative
report file `docs/ai/handoff/BRIDGE_REPORT.md` (create the `handoff/` folder and
the file if they do not exist). Each task's section must contain:
- **Task ID + heading** (e.g. `## BRIDGE-02`)
- **Summary**: one paragraph on what changed.
- **Files changed/created**: list each file + a one-line description.
- **Deviations**: anything done differently from the spec and why ("none" if exact).
- **Verification results**: paste the ACTUAL output of that task's verification
  commands (`flutter analyze`, `flutter test`, `grep`, etc.).
- **Manual test status**: state whether any required manual/on-device test was
  run; if it could not be run in the environment, say so explicitly.
- **Open questions / risks**: anything the reviewer should double-check.

Keep it concise and factual. Never paste secrets (MQTT credentials, signing keys,
the default HiveMQ server/username from mqtt.dart). This file is how the reviewing
agent (Claude Code) verifies each step before it is committed. Do NOT mark a task
done without its report section.

---

The BRIDGE work is organized into **3 milestones**. Each milestone ends in a
**TEST GATE** — a concrete on-device check on the Pixel 10. **Do not start the
next milestone until the current milestone's test gate passes.** Hand Codex one
milestone at a time; review its handoff-report section(s), run the gate, then
proceed.

Task order is deliberately NOT the old numeric order: the connection pipe (UI +
service) is built and proven FIRST, then data is pushed through it.

```
Milestone A (connect):   BRIDGE-01 → 02a → 02b → 05 → 06   → GATE A
Milestone B (send data): BRIDGE-03 → 04                    → GATE B
Milestone C (polish):    BRIDGE-07 → 08 → 09               → GATE C
```

---

## MILESTONE A — Build the pipe and prove a connection

Goal: be able to enter a bridge MAC (typed or QR), tap Connect, and see
"Connected" in Settings. **No data sending yet.**

---

### BRIDGE-01 — Create bridge_message.dart (topic/value framing)

**Goal**: Define the BLE bridge protocol as **MQTT-over-BLE**: each message is a
`topic\x00value` UTF-8 byte frame (NOT a binary typed protocol). See the
CONFIRMED ARCHITECTURE box at the top of `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md`.

**Context files to read first**:
- `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md` → CONFIRMED ARCHITECTURE box (top)
- `lib/services/mqtt.dart` → `publishCMMessage` / `publishScore` (topic names to mirror)

**Target files to create**:
- `lib/models/bridge_message.dart`

**Files NOT to touch**: All existing files.

**Implementation**:
Create `lib/models/bridge_message.dart` with:
```dart
// Bridge protocol: "MQTT-over-BLE". Each message is a (topic, value) pair,
// framed as UTF-8 bytes:  <topic> 0x00 <value>
// The bridge forwards every frame verbatim to RS485/RPi/MQTT, and additionally
// parses a few known topics (scores, colors) to drive its own LED display.

import 'dart:convert';

// Same Nordic UART Service UUIDs as robot modules. The bridge is distinguished
// from robot modules ONLY by its MAC address, not by service UUID.
const String kBridgeServiceUUID = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
const String kBridgeTxCharUUID  = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E'; // phone writes
const String kBridgeRxCharUUID  = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E'; // future use

// Separator between topic and value inside a frame.
const int kBridgeFieldSeparator = 0x00;

// Known topic names (mirror lib/services/mqtt.dart). Iteration 1 uses only the
// score + color topics; the rest are reserved for iteration 2.
class BridgeTopics {
  static const String team1Score = 'team1_score';
  static const String team2Score = 'team2_score';
  static const String team1Color = 'team1_color'; // RGB hex, e.g. "77FF00"
  static const String team2Color = 'team2_color';
  // Reserved (iteration 2): team1_name, team2_name, team1_id, team2_id,
  // game_stage, time, field, and timer sync topics.
}

class BridgeMessage {
  final String topic;
  final String value;

  const BridgeMessage(this.topic, this.value);

  /// Encodes the message as `<topic> 0x00 <value>` in UTF-8 bytes.
  List<int> toBytes() {
    return [
      ...utf8.encode(topic),
      kBridgeFieldSeparator,
      ...utf8.encode(value),
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is BridgeMessage && other.topic == topic && other.value == value;

  @override
  int get hashCode => Object.hash(topic, value);

  @override
  String toString() => 'BridgeMessage($topic=$value)';
}
```

**Acceptance criteria**:
- `flutter analyze lib/models/bridge_message.dart` returns 0 errors/warnings
- `toBytes()` for `BridgeMessage('team1_score', '3')` yields the UTF-8 bytes of
  `team1_score`, then `0x00`, then `0x33`

**Verification commands**:
```bash
flutter analyze lib/models/bridge_message.dart
```

**Risks**: Very low. New file, no dependencies.

---

### BRIDGE-02a — BleBridgeService skeleton (state + settings, NO BLE yet)

**Goal**: Create `BleBridgeService` with its state notifiers and SharedPreferences
persistence ONLY. No BLE connection logic yet — that is BRIDGE-02b. This isolates
the simple, testable persistence/state code from the trickier BLE code.

**Context files to read first**:
- `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md` → CONFIRMED ARCHITECTURE box
- `lib/services/mqtt.dart` (copy its SharedPreferences + ValueNotifier patterns exactly)

**Target files to create**:
- `lib/services/ble_bridge_service.dart`

**Files NOT to touch**: All existing files.

**Implementation**:
Create `lib/services/ble_bridge_service.dart` with:
- `enum BridgeConnectionState { disabled, disconnected, connecting, connected, error }`
- `class BleBridgeService extends ChangeNotifier`
- `final ValueNotifier<BridgeConnectionState> connectionStateNotifier =
   ValueNotifier(BridgeConnectionState.disconnected);`
- `final ValueNotifier<int> queueDepthNotifier = ValueNotifier(0);` (used later)
- Persisted settings with getters/setters that write to SharedPreferences
  (follow mqtt.dart exactly), keys:
  - `bridge_enabled` (bool) → `isEnabled`
  - `bridge_mac_address` (String) → `bridgeMacAddress`
  - (No `bridge_auto_connect` — phone-side launch auto-connect was dropped
    on 2026-05-31 after Gate A. Referees swap phones between games, so a
    freshly-opened app must NOT auto-grab the bridge. Connect is always
    manual. GATT-level `autoConnect: true` in `connect()` is unrelated and
    stays.)
- `Future<void> loadPreferences()` (called from constructor, same as MqttService)
- `bool get isConnected => connectionStateNotifier.value == BridgeConnectionState.connected;`
- Stub methods that BRIDGE-02b/03 will fill in (declare them now so the file
  compiles and the type is stable):
  - `Future<void> connect() async {}`
  - `Future<void> disconnect() async {}`
  - `void publishTopic(String topic, String value) {}`
- `dispose()` that disposes the notifiers

**Acceptance criteria**:
- `flutter analyze lib/services/ble_bridge_service.dart` returns 0 errors
- `BleBridgeService()` instantiates without crashing
- Settings persist: setting `bridgeMacAddress` then reading it back returns the value

**Verification commands**:
```bash
flutter analyze lib/services/ble_bridge_service.dart
grep -n "bridge_enabled\|bridge_mac_address\|BridgeConnectionState" lib/services/ble_bridge_service.dart
```

**Risks**: Very low. No BLE, pure state + prefs.

---

### BRIDGE-02b — Add BLE connect/disconnect/discover/MTU to BleBridgeService

**Goal**: Implement the actual BLE connection logic in `BleBridgeService`:
connect to the configured MAC, request a larger MTU, discover the NUS service,
locate the TX characteristic, and track connection state. Still NO message queue
(that is BRIDGE-03).

**Context files to read first**:
- `lib/models/module.dart` (copy `bleConnect`, `_registerBleSubscriber`,
  `bleCheckServicesAndGetCharacteristics` patterns)
- `lib/services/ble_bridge_service.dart` (from BRIDGE-02a)
- `lib/models/bridge_message.dart` (UUID constants from BRIDGE-01)

**Target files to modify**:
- `lib/services/ble_bridge_service.dart`

**Files NOT to touch**: All existing files except `ble_bridge_service.dart`.
In particular do NOT modify `lib/models/module.dart` — copy patterns, don't share code.

**Implementation**:
Add fields:
- `BluetoothDevice? _device;`
- `BluetoothCharacteristic? _txChar;`
- `StreamSubscription<BluetoothConnectionState>? _connSub;`

Implement `connect()`:
- guard: if `bridgeMacAddress` is empty, return (optionally set `error`)
- `connectionStateNotifier.value = BridgeConnectionState.connecting;`
- `_device = BluetoothDevice.fromId(bridgeMacAddress);`
- register `_connSub` on `_device!.connectionState` (same shape as module.dart's
  `_registerBleSubscriber`):
  - on `connected`: discover services, find `kBridgeServiceUUID`, get the
    `kBridgeTxCharUUID` characteristic into `_txChar`, set state `connected`,
    then call `_processQueue()` (the method exists as a stub until BRIDGE-03)
  - on `disconnected`: `_txChar = null;` set state `disconnected`
- request a larger MTU so longer values (iteration 2) are not fragmented:
  connect with `autoConnect: true` and then `await _device!.requestMtu(247);`
  after the connection is established (or pass mtu on connect if the flutter_blue_plus
  version supports it). Use `autoConnect: true` for reliable reconnect in harsh
  field conditions, mirroring robot modules.
- wrap in try/catch; on error set state `error` (do NOT rethrow)

Implement `disconnect()`:
- `await _connSub?.cancel();` `_connSub = null;`
- `await _device?.disconnect();`
- `_txChar = null;` set state `disconnected`

Update `dispose()` to cancel `_connSub` and disconnect.

**Acceptance criteria**:
- `flutter analyze lib/services/ble_bridge_service.dart` returns 0 errors
- connect/disconnect compile and use `kBridgeServiceUUID` / `kBridgeTxCharUUID`
- an MTU request (~247) is issued on connect

**Verification commands**:
```bash
flutter analyze lib/services/ble_bridge_service.dart
grep -n "requestMtu\|kBridgeServiceUUID\|kBridgeTxCharUUID\|connectionState" lib/services/ble_bridge_service.dart
```

**Risks**: Medium — this is the trickiest BLE code. Keep it close to the proven
module.dart patterns. Errors must set the `error` state, never throw to callers.

---

### BRIDGE-05 — Register BleBridgeService in the Provider tree

**Goal**: Expose `bleBridgeService` to the UI via `MultiProvider` in `main.dart`.
(Done before the settings UI so the UI can observe it.)

**Context files to read first**:
- `lib/main.dart`
- `lib/models/game.dart`

**Target files to modify**:
- `lib/main.dart`
- `lib/models/game.dart` (only to add the `bleBridgeService` field — see note)

**Files NOT to touch**: The static module provider list and the existing Game /
Team provider registration structure (CLAUDE.md invariant) — only ADD lines.

**Implementation**:
1. In `lib/models/game.dart`, add (near the `mqttService` field):
   ```dart
   import 'package:rcj_scoreboard/services/ble_bridge_service.dart';
   // ...
   BleBridgeService bleBridgeService = BleBridgeService();
   ```
   (This field is also used by BRIDGE-04; adding it here lets the provider and
   settings UI reference it during Milestone A. Do NOT add any publish calls yet.)
2. In `lib/main.dart`, in the `providers:` list of `MultiProvider`, after the
   existing `ChangeNotifierProvider.value(value: game)` line, add:
   ```dart
   ChangeNotifierProvider.value(value: game.bleBridgeService),
   ```

**Acceptance criteria**:
- `grep "bleBridgeService" lib/main.dart` finds the registration
- `flutter analyze` returns 0 errors

**Verification commands**:
```bash
grep -n "bleBridgeService" lib/main.dart lib/models/game.dart
flutter analyze
```

**Risks**: Very low. Additive field + provider registration.

---

### BRIDGE-06 — Add "BLE Bridge" settings section (MAC + QR + connect)

**Goal**: Add a collapsible "BLE Bridge" section to `SettingsScreen`, styled like
the MQTT section: enable toggle, MAC input field, **QR scan button** (reuse the
existing scanner), connect/disconnect button, and status display.

**Context files to read first**:
- `lib/screens/settings.dart` (MQTT section is the template, ~lines 169-270)
- `lib/screens/module_settings.dart` → `buildQRButton()` (how it pushes
  `BarcodeScannerSimple` and reads back a MAC string)
- `lib/screens/mac_qr_scanner.dart` (`BarcodeScannerSimple`)
- `lib/services/ble_bridge_service.dart` (BRIDGE-02a/02b)

**Target files to modify**:
- `lib/screens/settings.dart`

**Files NOT to touch**:
- `lib/screens/home.dart` — no bridge UI on the main control screen
- `lib/models/game.dart`

**Implementation**:
1. Add imports for `BleBridgeService` (for `BridgeConnectionState`) and
   `BarcodeScannerSimple` (`mac_qr_scanner.dart`).
2. In `_SettingsScreenState.build()`, insert a new section in the `ListView`
   children BETWEEN the "Current Game" section and the MQTT
   `ValueListenableBuilder`, wrapped in `ValueListenableBuilder<BridgeConnectionState>`:
```dart
ValueListenableBuilder<BridgeConnectionState>(
  valueListenable: widget.game.bleBridgeService.connectionStateNotifier,
  builder: (context, bridgeState, child) {
    return SettingsSection(
      title: 'BLE Bridge',
      locked: false,
      enabled: widget.game.bleBridgeService.isEnabled,
      onToggle: (value) {
        setState(() { widget.game.bleBridgeService.isEnabled = value; });
      },
      settings: [
        SettingStatus(
          title: 'Bridge status',
          status: bridgeState == BridgeConnectionState.connected ? 'Connected'
              : bridgeState == BridgeConnectionState.connecting ? 'Connecting...'
              : bridgeState == BridgeConnectionState.error ? 'Error'
              : 'Disconnected',
        ),
        SettingInputField(
          title: 'Bridge MAC',
          initialValue: widget.game.bleBridgeService.bridgeMacAddress,
          onChanged: (value) {
            widget.game.bleBridgeService.bridgeMacAddress = value;
          },
        ),
        SettingButton(
          title: 'Scan QR code',
          buttonText: 'Scan QR',
          onPressed: () async {
            final result = await Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const BarcodeScannerSimple()),
            );
            if (result != null) {
              setState(() {
                widget.game.bleBridgeService.bridgeMacAddress = result as String;
              });
            }
          },
        ),
        // (No "Auto-connect" switch — phone-side launch auto-connect was
        // dropped after Gate A. Connect is always manual.)
        SettingButton(
          title: 'Bridge connection',
          buttonText: bridgeState == BridgeConnectionState.connected ? 'Disconnect' : 'Connect',
          onPressed: () async {
            if (bridgeState == BridgeConnectionState.connected) {
              await widget.game.bleBridgeService.disconnect();
            } else {
              await widget.game.bleBridgeService.connect();
            }
            setState(() {});
          },
        ),
      ],
    );
  },
),
```
   NOTE: after a QR scan the MAC text field shows the scanned value on next open;
   `setState` after setting the MAC is enough for the Connect button. If the field
   must update live, give it a controller — but keep changes minimal and
   consistent with existing `SettingInputField` usage.

**Acceptance criteria**:
- `grep -n "BLE Bridge\|bleBridgeService" lib/screens/settings.dart` shows the section
- `flutter analyze` returns 0 errors

**Verification commands**:
```bash
grep -n "BLE Bridge\|bleBridgeService\|BarcodeScannerSimple" lib/screens/settings.dart
flutter analyze
```

**Risks**: Low. Additive UI following the MQTT pattern.

---

### ✅ TEST GATE A — Connection works end to end (on Pixel 10)

Run the app on the Pixel 10 with a real bridge device powered on. Verify:
1. Settings shows a "BLE Bridge" section between "Current Game" and "MQTT".
2. Enable the section toggle.
3. Enter the bridge MAC manually OR tap "Scan QR" and scan the bridge's MAC QR.
4. Tap "Connect" → status becomes "Connecting..." then "Connected".
5. Tap "Disconnect" → status becomes "Disconnected".
6. Confirm the MAC persists across an app restart (reopen Settings, MAC still
   present). Connect stays manual — the app does NOT auto-connect on launch.

**Do not proceed to Milestone B until Gate A passes.** If connection fails,
the problem is isolated to BRIDGE-02b (BLE logic) or BRIDGE-06 (UI wiring).

---

## MILESTONE B — Push score + color through the pipe

Goal: when the score changes, the scoreboard displays the new score in the
correct team colors.

---

### BRIDGE-03 — Add queue + write-with-response to BleBridgeService

**Goal**: Implement the async FIFO queue with **change-only dedup**, single
in-flight write, and **write-with-response** (the ACK) with retry.

**Context files to read first**:
- `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md` → CONFIRMED ARCHITECTURE box (perf disciplines)
- `lib/services/ble_bridge_service.dart` (from BRIDGE-02a/02b)
- `lib/models/bridge_message.dart` (from BRIDGE-01)

**Target files to modify**:
- `lib/services/ble_bridge_service.dart`

**Files NOT to touch**: All existing files except `ble_bridge_service.dart`.

**Implementation**:
Add (import `dart:collection`):
1. `final Queue<BridgeMessage> _queue = Queue<BridgeMessage>();`
2. `bool _sendInProgress = false;`
3. Replace the `publishTopic` stub:
```dart
/// Enqueue a (topic, value) for delivery to the bridge. Non-blocking.
/// Safe to call when disconnected/disabled — the message is dropped (no throw),
/// mirroring MqttService.publishMessage's no-op-when-disconnected guard.
void publishTopic(String topic, String value) {
  if (!isEnabled) return;                 // guard: bridge disabled
  final msg = BridgeMessage(topic, value);
  // Change-only dedup: a newer value for the same topic replaces an older,
  // not-yet-sent one (latest wins for score/color snapshots).
  _queue.removeWhere((m) => m.topic == topic);
  _queue.add(msg);
  queueDepthNotifier.value = _queue.length;
  _processQueue();                        // fire-and-forget
}
```
4. Queue processor — one in flight; removes whether or not it succeeded:
```dart
Future<void> _processQueue() async {
  if (_sendInProgress || _queue.isEmpty || !isConnected) return;
  _sendInProgress = true;
  while (_queue.isNotEmpty && isConnected) {
    final msg = _queue.first;
    await _sendWithRetry(msg);            // ACK handled inside (write-with-response)
    _queue.removeFirst();
    queueDepthNotifier.value = _queue.length;
  }
  _sendInProgress = false;
}
```
5. Send with retry — **write-with-response is the ACK**:
```dart
Future<bool> _sendWithRetry(BridgeMessage msg, {int maxRetries = 3}) async {
  final bytes = msg.toBytes();
  for (int attempt = 0; attempt < maxRetries; attempt++) {
    try {
      // withoutResponse:false => ATT Write Request; the bridge BLE stack ACKs.
      // Completion without throw == delivered to the bridge.
      await _txChar!.write(bytes, withoutResponse: false, timeout: 5);
      return true;
    } catch (e) {
      if (attempt == maxRetries - 1) {
        debugPrint('BleBridge: send "${msg.topic}" failed after $maxRetries: $e');
      }
    }
  }
  return false;
}
```
6. Ensure the `connected` transition in BRIDGE-02b calls `_processQueue()` so
   anything queued while disconnected drains on connect.

**CRITICAL invariants**:
- Exactly one write in flight (`_sendInProgress`).
- `publishTopic` NEVER throws and NEVER blocks the caller.
- Write-with-response stays (`withoutResponse: false`) — it is the delivery ACK.
- No application-level ACK parsing, no `Completer`.

**Acceptance criteria**:
- `flutter analyze lib/services/ble_bridge_service.dart` returns 0 errors
- `_sendWithRetry` uses `withoutResponse: false`
- `publishTopic` guards disconnected/disabled and cannot throw

**Verification commands**:
```bash
flutter analyze lib/services/ble_bridge_service.dart
grep -n "withoutResponse\|_sendInProgress\|removeWhere\|Completer" lib/services/ble_bridge_service.dart
```

**Risks**: Low. Write-with-response: exception = failure, no exception = delivered.

---

### BRIDGE-04 — Publish score + color from Game (fan-out, fire-and-forget)

**Goal**: When the score changes, send all four messages — `team1_score`,
`team2_score`, `team1_color`, `team2_color` — to the bridge, alongside the
existing MQTT publish. Fire-and-forget from `Game` (no `await`); each service
self-guards so either link can be down.

**Context files to read first**:
- `lib/models/game.dart` (`notifyModulesScore`, `gameInit`; `bleBridgeService`
  field was added in BRIDGE-05)
- `lib/models/team.dart` (team `id`)
- `lib/models/bridge_message.dart` (`BridgeTopics`)
- `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md` → CONFIRMED ARCHITECTURE box

**Target files to modify**:
- `lib/models/game.dart`

**Files NOT to touch**:
- `lib/models/module.dart` — robot path untouched
- `lib/services/ble_bridge_service.dart` — read only
- the robot play/stop methods (`playAll`, `stopAll`, `bleSendPlayAll`, etc.)

**Implementation**:
1. Ensure `import 'package:rcj_scoreboard/models/bridge_message.dart';` (for
   `BridgeTopics`). The `bleBridgeService` field already exists from BRIDGE-05.
2. Add a private helper mapping a team to its RGB hex color. Colors live ONLY in
   the app; use the SAME colors as `lib/screens/home.dart` (team A neon green
   `0x77FF00`, team B neon magenta `0xFF00FF`), keyed by team `id`:
```dart
String _teamColorHex(Team team) => team.id == 'A' ? '77FF00' : 'FF00FF';
```
3. Add a fan-out method (neither call may throw upward — each service guards itself):
```dart
void _publishScoreToBridge() {
  bleBridgeService.publishTopic(BridgeTopics.team1Score, teams[0].score.toString());
  bleBridgeService.publishTopic(BridgeTopics.team2Score, teams[1].score.toString());
  bleBridgeService.publishTopic(BridgeTopics.team1Color, _teamColorHex(teams[0]));
  bleBridgeService.publishTopic(BridgeTopics.team2Color, _teamColorHex(teams[1]));
}
```
4. Call `_publishScoreToBridge()` in `notifyModulesScore()` right AFTER the
   existing `mqttService.publishScore(teams);` line.
5. Call `_publishScoreToBridge()` at the end of `gameInit()` (after the MQTT
   publish calls) so the bridge gets the reset 0–0 + colors on a new game.

**CRITICAL**:
- Do NOT add `await` before any `bleBridgeService` call. Fire-and-forget from
  Game; the write-with-response ACK happens INSIDE the bridge service on its own
  queue and must never block Game's logic or the robot play/stop path.
- Do not reorder or remove existing MQTT publish calls.

**Acceptance criteria**:
- `flutter analyze lib/models/game.dart` returns 0 errors
- `_publishScoreToBridge` is called in `notifyModulesScore` and `gameInit`
- No `await` precedes any `bleBridgeService` call in game.dart

**Verification commands**:
```bash
flutter analyze lib/models/game.dart
grep -n "bleBridgeService\|_publishScoreToBridge\|_teamColorHex" lib/models/game.dart
grep -n "await.*bleBridgeService" lib/models/game.dart   # must return NOTHING
```

**Risks**: Low. Additive side-effect calls; score changes happen right after
`stopAll`, so robots are not awaiting the radio at that instant.

---

### ✅ TEST GATE B — Score reaches the scoreboard (on Pixel 10)

With the bridge connected (Gate A passing):
1. Increment Team A score → scoreboard shows the new score in **neon green**.
2. Increment Team B score → scoreboard shows the new score in **neon magenta**.
3. Use "Switch team order" in settings, score again → colors still follow the
   correct team (color is keyed by team id, not screen position).
4. Reset the game → scoreboard returns to 0–0.
5. (If a bridge debug log / RS485 capture is available) confirm each goal yields
   the 4 frames `team1_score`, `team2_score`, `team1_color`, `team2_color`.

**Do not proceed to Milestone C until Gate B passes.**

---

## MILESTONE C — Polish, tests, and the safety regression

---

### BRIDGE-07 — ~~Auto-connect the bridge on app start~~ CANCELLED (2026-05-31)

**CANCELLED after Gate A.** Phone-side launch auto-connect is intentionally NOT
implemented. Referees swap phones between games, so a freshly-opened app must not
auto-grab a bridge that another phone may now be driving. Connect is always
manual. (GATT-level `autoConnect: true` inside `connect()`, which makes the
bridge/module reconnect after a link drop, is a separate mechanism and stays.)
The `bridge_auto_connect` pref and the "Auto-connect" toggle were removed.

Milestone C is now just BRIDGE-08 → 09.

---

### BRIDGE-08 — Unit tests for framing and queue dedup

**Goal**: Test `BridgeMessage` framing and (if reachable without hardware) the
queue's change-only dedup.

**Context files to read first**:
- `lib/models/bridge_message.dart` (BRIDGE-01)
- `lib/services/ble_bridge_service.dart` (BRIDGE-03)
- `test/widget_test.dart` (existing setup; SharedPreferences may need
  `SharedPreferences.setMockInitialValues({})` in `setUp`)

**Target files to create**:
- `test/bridge_message_test.dart`

**Files NOT to touch**: Production source files.

**Implementation**:
```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/models/bridge_message.dart';

void main() {
  group('BridgeMessage framing', () {
    test('encodes topic 0x00 value in UTF-8', () {
      final bytes = const BridgeMessage('team1_score', '3').toBytes();
      final sep = bytes.indexOf(0x00);
      expect(sep, greaterThan(0));
      expect(utf8.decode(bytes.sublist(0, sep)), 'team1_score');
      expect(utf8.decode(bytes.sublist(sep + 1)), '3');
    });

    test('color value survives framing', () {
      final bytes = const BridgeMessage('team1_color', '77FF00').toBytes();
      final sep = bytes.indexOf(0x00);
      expect(utf8.decode(bytes.sublist(sep + 1)), '77FF00');
    });

    test('equality is by topic+value', () {
      expect(const BridgeMessage('t', '1'), const BridgeMessage('t', '1'));
      expect(const BridgeMessage('t', '1') == const BridgeMessage('t', '2'), isFalse);
    });
  });
}
```
If the dedup logic is reachable without real BLE (e.g. via an exposed queue or a
testable enqueue), add a test that enqueuing two `team1_score` values leaves only
the latest. If not testable without a risky refactor, state that in the report
rather than forcing it.

**Acceptance criteria**:
- `flutter test test/bridge_message_test.dart` passes

**Verification commands**:
```bash
flutter test test/bridge_message_test.dart
```

**Risks**: Very low.

---

### BRIDGE-09 — Docs update + robot-latency regression check

**Goal**: Update docs to reflect what was built, and run the play/stop latency
regression check with the bridge connected.

**Context files to read first**:
- `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md`
- `docs/ai/01_PROJECT_MAP.md`

**Target files to modify**:
- `docs/ai/01_PROJECT_MAP.md` — add `ble_bridge_service.dart` and
  `bridge_message.dart` to the file map / key classes table
- `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md` — mark iteration-1 items DONE; keep
  iteration-2 items (timer sync, names, stage, events, full MQTT mirror) as TODO

**Regression check (REQUIRED, record result in the report)**:
- With 10 robot modules connected AND the bridge connected and actively receiving
  score updates, verify robot START/STOP latency is unchanged vs. without the
  bridge (no perceptible serialization/delay). This validates the "one shared
  radio" discipline. If on-device testing is unavailable, state that explicitly
  and flag it for the owner to test on the Pixel 10.

**Risks**: Very low for docs. The regression check is the real gate — if latency
regresses, do NOT mark the feature complete; report it.

---

### ✅ TEST GATE C — Polish verified (on Pixel 10)

1. Kill and relaunch → MAC still set; bridge does NOT auto-connect (Connect is
   manual by design — see cancelled BRIDGE-07).
2. `flutter test` passes.
3. **Latency regression**: 10 modules + bridge connected and receiving scores →
   START/STOP feels identical to before the bridge existed. THIS IS THE SAFETY
   GATE — if it regresses, stop and report.

---

## Dependency ordering

```
PLAY-01 → PLAY-02 → PLAY-03 → PLAY-04 → PLAY-05 → PLAY-06 → PLAY-07   [DONE]
AUDIT-FIX-01 (independent)
AUDIT-FIX-02 (independent)                                            [DONE]
AUDIT-FIX-03 (independent)                                            [DONE]

BRIDGE — do one MILESTONE at a time; pass its TEST GATE before the next:
  Milestone A: BRIDGE-01 → 02a → 02b → 05 → 06   → GATE A (connect)
  Milestone B: BRIDGE-03 → 04                    → GATE B (score+color displays)
  Milestone C: BRIDGE-08 → 09 (BRIDGE-07 cancelled) → GATE C (polish + latency safety)
```

PLAY and AUDIT tasks are independent of BRIDGE tasks. Within BRIDGE, the order
above is intentional (the connection pipe is built and tested before any data is
sent). Do not skip a test gate.
