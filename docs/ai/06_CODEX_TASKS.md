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
3. Add `Future<void> _loadPrefs()` method that reads the 4 values from SharedPreferences and sets the fields, then calls `gameInit()` if not already in game
4. Call `_loadPrefs()` at the end of the `Game()` constructor
5. Add `_savePrefs()` calls in setters for `periodTime`, `halfTimeDuration`, `numberOfPLayers`, `penaltyTime` (these are currently just public fields — they need to become setters)

SharedPreferences keys to use:
- `game_period_time` (int, default: 600)
- `game_halftime_duration` (int, default: 300)
- `game_num_players` (int, default: 2)
- `game_penalty_time` (int, default: 60)

**Acceptance criteria**:
- After changing game duration in settings, killing the app, and restarting, the same duration is shown in settings

**Verification commands**:
```bash
flutter analyze
grep -n "SharedPreferences\|_prefs\|game_period" lib/models/game.dart
```

**Manual test**: Set game duration to 2 mins, kill app, restart, verify 2 mins is still selected.

**Risks**: Medium. `Game` constructor is synchronous; SharedPreferences is async. The fields must have sensible defaults until prefs load. Use `late` with defaults or a `FutureBuilder` approach. Simplest: keep defaults in field initializers, call `_loadPrefs()` async from constructor (unawaited), then call `gameInit()` again once loaded.

---

## Group BRIDGE — BLE Bridge Feature

Complete tasks in order. Read `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md` before starting.

---

### BRIDGE-01 — Create BridgeMessage model

**Goal**: Define the `BridgeMessage` data class and protocol constants.

**Context files to read first**:
- `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md` → Protocol proposal section
- `lib/models/game.dart` (MatchStage enum for reference)

**Target files to create**:
- `lib/models/bridge_message.dart`

**Files NOT to touch**: All existing files.

**Implementation**:
Create `lib/models/bridge_message.dart` with:
```dart
// PROPOSED protocol — confirm UUIDs with bridge hardware before finalizing

enum BridgeMessageType {
  scoreUpdate,    // 0x10
  gameState,      // 0x11
  matchInfo,      // 0x12
  event,          // 0x14
}

enum BridgeEventType {
  goalScored,       // 0x01
  penaltyStarted,   // 0x02
  penaltyEnded,     // 0x03
  halfTimeStart,    // 0x04
  gameOver,         // 0x05
}

const int kBridgeProtocolVersion = 0x01;

// Same NUS UUIDs as robot modules — bridge is distinguished by MAC address, not service UUID
const String kBridgeServiceUUID = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
const String kBridgeTxCharUUID  = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
const String kBridgeRxCharUUID  = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';

class BridgeMessage {
  final BridgeMessageType type;
  final List<int> payload;
  final int seqNum;  // 0-255, set by BleBridgeService
  final bool deduplicatable;  // true = latest replaces older (score/state); false = preserve all (events)

  BridgeMessage({
    required this.type,
    required this.payload,
    this.seqNum = 0,
    required this.deduplicatable,
  });

  List<int> toBytes() {
    return [kBridgeProtocolVersion, type.index, seqNum] + payload;
  }

  static BridgeMessage scoreUpdate(int scoreA, int scoreB) => BridgeMessage(
    type: BridgeMessageType.scoreUpdate,
    payload: [scoreA, scoreB],
    deduplicatable: true,
  );

  static BridgeMessage gameState(int stageIndex, int remainingSeconds) => BridgeMessage(
    type: BridgeMessageType.gameState,
    payload: [stageIndex, (remainingSeconds >> 8) & 0xFF, remainingSeconds & 0xFF],
    deduplicatable: true,
  );
}
```

**Acceptance criteria**:
- `flutter analyze` returns 0 errors/warnings on the new file
- `grep -l "BridgeMessage" lib/models/bridge_message.dart` finds the file

**Verification commands**:
```bash
flutter analyze lib/models/bridge_message.dart
```

**Risks**: Very low. New file, no dependencies yet.

---

### BRIDGE-02 — Create BleBridgeService skeleton

**Goal**: Create the `BleBridgeService` class with connection management and settings persistence, but without the message queue yet.

**Context files to read first**:
- `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md`
- `lib/services/mqtt.dart` (follow its patterns for SharedPreferences + ValueNotifier)
- `lib/models/module.dart` (follow BLE connection patterns)
- `lib/models/bridge_message.dart` (from BRIDGE-01)

**Target files to create**:
- `lib/services/ble_bridge_service.dart`

**Files NOT to touch**: All existing files.

**Implementation**:
Create `lib/services/ble_bridge_service.dart` with:
- `BleBridgeService` extending `ChangeNotifier`
- `BridgeConnectionState` enum: `{disabled, disconnected, connecting, connected, error}`
- `ValueNotifier<BridgeConnectionState> connectionStateNotifier`
- `ValueNotifier<int> queueDepthNotifier`
- SharedPreferences fields + `loadPreferences()`: keys `bridge_enabled`, `bridge_mac_address`, `bridge_auto_connect`
- `connect()` / `disconnect()` async methods following same pattern as module.dart's `bleConnect()`
- Service discovery using `kBridgeServiceUUID` / `kBridgeTxCharUUID` / `kBridgeRxCharUUID` from `bridge_message.dart` (same NUS UUIDs as robot modules — bridge identified by MAC, not UUID)
- Connection state subscription (same pattern as `_registerBleSubscriber` in module.dart)
- Stub `publishScore(int a, int b)` / `publishGameState(int stage, int secs)` that do nothing yet (queue will be added in BRIDGE-03)
- `dispose()` that disconnects and closes streams

**Acceptance criteria**:
- `flutter analyze` returns 0 errors
- `BleBridgeService` can be instantiated without crashing: `BleBridgeService b = BleBridgeService();`

**Verification commands**:
```bash
flutter analyze lib/services/ble_bridge_service.dart
```

**Risks**: Low. New file with no integration yet.

---

### BRIDGE-03 — Add message queue and ACK logic to BleBridgeService

**Goal**: Implement the async FIFO queue, sequence numbers, and retry logic using write-with-response for delivery confirmation (no separate ACK channel needed).

**Context files to read first**:
- `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md` → "BleBridgeService — design" and "Why write-with-response is sufficient"
- `lib/services/ble_bridge_service.dart` (from BRIDGE-02)
- `lib/models/bridge_message.dart` (from BRIDGE-01)

**Target files to modify**:
- `lib/services/ble_bridge_service.dart`

**Files NOT to touch**: All existing files except ble_bridge_service.dart.

**Implementation**:
Add to `BleBridgeService`:
1. `final Queue<BridgeMessage> _queue = Queue<BridgeMessage>();`
2. `int _nextSeqNum = 0;`
3. `bool _sendInProgress = false;`

Implement `_enqueue(BridgeMessage msg)`:
- For `deduplicatable=true` messages: remove any existing same-type message in queue, then add new one
- For `deduplicatable=false` events: always append
- Update `queueDepthNotifier.value`
- If not already in progress, call `_processQueue()`

Implement `_processQueue()`:
```dart
Future<void> _processQueue() async {
  if (_sendInProgress || _queue.isEmpty || !isConnected) return;
  _sendInProgress = true;
  while (_queue.isNotEmpty) {
    final msg = _queue.first;
    final success = await _sendWithRetry(msg);
    // success or not — remove from queue and continue
    _queue.removeFirst();
    queueDepthNotifier.value = _queue.length;
  }
  _sendInProgress = false;
}
```

Implement `_sendWithRetry(BridgeMessage msg, {int maxRetries = 3})`:
```dart
Future<bool> _sendWithRetry(BridgeMessage msg, {int maxRetries = 3}) async {
  final bytes = msg.copyWith(seqNum: _nextSeqNum).toBytes();
  _nextSeqNum = (_nextSeqNum + 1) % 256;
  for (int attempt = 0; attempt < maxRetries; attempt++) {
    try {
      // write-with-response: ATT Write Response confirms delivery to bridge BLE stack
      await _txChar!.write(bytes, withoutResponse: false, timeout: 5);
      return true;
    } catch (e) {
      if (attempt == maxRetries - 1) {
        debugPrint('BleBridge: send failed after $maxRetries attempts: $e');
      }
    }
  }
  return false;
}
```

Implement the public publish methods to call `_enqueue`:
```dart
void publishScore(int a, int b) => _enqueue(BridgeMessage.scoreUpdate(a, b));
void publishGameState(int stageIndex, int remainingSeconds) =>
    _enqueue(BridgeMessage.gameState(stageIndex, remainingSeconds));
```

**Acceptance criteria**:
- `flutter analyze` returns 0 errors
- No `Completer` or application-level ACK parsing in the file
- `_sendWithRetry` uses `withoutResponse: false` (write-with-response)

**Verification commands**:
```bash
flutter analyze lib/services/ble_bridge_service.dart
grep -n "withoutResponse\|Completer" lib/services/ble_bridge_service.dart
```

**Risks**: Low. Write-with-response is straightforward — exception = failure, no exception = delivered.

---

### BRIDGE-04 — Integrate BleBridgeService into Game

**Goal**: Instantiate `BleBridgeService` in `Game` and add bridge publish calls as side effects.

**Context files to read first**:
- `lib/models/game.dart`
- `lib/services/ble_bridge_service.dart` (from BRIDGE-02/03)
- `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md` → "Integration with Game class"

**Target files to modify**:
- `lib/models/game.dart`

**Files NOT to touch**:
- `lib/models/module.dart` — no bridge references here
- `lib/services/ble_bridge_service.dart` — read only

**Implementation**:
1. Add `import 'package:rcj_scoreboard/services/ble_bridge_service.dart';`
2. Add field: `BleBridgeService bleBridgeService = BleBridgeService();`
3. In `notifyModulesScore()`: after existing MQTT publish line, add:
   ```dart
   bleBridgeService.publishScore(teams[0].score, teams[1].score);
   ```
4. In `startTimer()` timer callback, in the `_remainingTime > 0` branch, alongside `mqttService.publishTime(...)`, add:
   ```dart
   // Publish game state to bridge every 30 seconds (not every tick — avoid flooding)
   if (_remainingTime % 30 == 0) {
     bleBridgeService.publishGameState(currentStage.index, _remainingTime);
   }
   ```
5. In `startTimer()` on stage transition: after `mqttService.publishGameState(...)`, add:
   ```dart
   bleBridgeService.publishGameState(currentStage.index, _remainingTime);
   ```
6. In `gameInit()`: after MQTT publish calls, add:
   ```dart
   bleBridgeService.publishScore(0, 0);
   ```

**Critical**: Do NOT add `await` to bridge calls. They must be fire-and-forget from `Game`'s perspective.

**Acceptance criteria**:
- `flutter analyze` returns 0 errors
- Bridge calls appear in `notifyModulesScore()` and timer callback
- No `await` keyword before bridge calls in game.dart

**Verification commands**:
```bash
flutter analyze lib/models/game.dart
grep -n "bleBridgeService\|await.*bridge" lib/models/game.dart
```

**Risks**: Low. Purely additive — side effect calls only.

---

### BRIDGE-05 — Register BleBridgeService in Provider tree

**Goal**: Add `BleBridgeService` to the `MultiProvider` in `main.dart` so UI can observe its state.

**Context files to read first**:
- `lib/main.dart`
- `lib/models/game.dart` (bleBridgeService field added in BRIDGE-04)

**Target files to modify**:
- `lib/main.dart`

**Implementation**:
In `MyApp.build()`, in the `providers:` list of `MultiProvider`, add:
```dart
ChangeNotifierProvider.value(value: game.bleBridgeService),
```
Place it after the `ChangeNotifierProvider.value(value: game)` line.

**Acceptance criteria**:
- `grep "bleBridgeService" lib/main.dart` finds the provider registration
- `flutter analyze` returns 0 errors

**Verification commands**:
```bash
grep -n "bleBridgeService" lib/main.dart
flutter analyze
```

**Risks**: Very low. Additive provider registration.

---

### BRIDGE-06 — Add BLE Bridge settings section to SettingsScreen

**Goal**: Add a new "BLE Bridge" settings section to `SettingsScreen` with MAC field, auto-connect toggle, connect/disconnect button, and status display.

**Context files to read first**:
- `lib/screens/settings.dart` (study the MQTT section as the template — lines ~167-268)
- `lib/services/ble_bridge_service.dart` (BRIDGE-02)
- `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md` → "Settings UI integration"

**Target files to modify**:
- `lib/screens/settings.dart`

**Files NOT to touch**:
- `lib/screens/home.dart` — no bridge UI on main screen
- `lib/models/game.dart`

**Implementation**:
1. Add import for `BleBridgeService`
2. In `_SettingsScreenState.build()`, in the `ListView` children list, add a new `ValueListenableBuilder<BridgeConnectionState>` widget between the "Current Game" and "MQTT" sections:

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
          onChanged: (value) { widget.game.bleBridgeService.bridgeMacAddress = value; },
        ),
        SettingSwitch(
          title: 'Auto-connect',
          value: widget.game.bleBridgeService.autoConnect,
          onChanged: (value) {
            setState(() { widget.game.bleBridgeService.autoConnect = value; });
          },
        ),
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

**Acceptance criteria**:
- `grep -n "BLE Bridge\|bleBridgeService" lib/screens/settings.dart` shows the new section
- `flutter analyze` returns 0 errors

**Verification commands**:
```bash
grep -n "BLE Bridge\|bleBridgeService" lib/screens/settings.dart
flutter analyze
```

**Manual test**: Open settings, verify "BLE Bridge" section appears between Current Game and MQTT.

**Risks**: Low. Additive UI section.

---

### BRIDGE-07 — Add auto-connect on app start

**Goal**: If `bridge_auto_connect = true` and a MAC is configured, attempt BLE bridge connection when the app starts.

**Context files to read first**:
- `lib/main.dart`
- `lib/services/ble_bridge_service.dart` (BRIDGE-02)

**Target files to modify**:
- `lib/services/ble_bridge_service.dart`

**Implementation**:
In `BleBridgeService.loadPreferences()`, at the end, after loading all preferences:
```dart
if (_isEnabled && _autoConnect && _bridgeMacAddress.isNotEmpty) {
  // Delay to allow BLE adapter to initialize
  Future.delayed(const Duration(seconds: 2), () => connect());
}
```

**Acceptance criteria**:
- If `bridge_enabled=true`, `bridge_auto_connect=true`, `bridge_mac_address` set: connection attempt starts ~2 seconds after app launch

**Verification commands**:
```bash
grep -n "autoConnect\|_autoConnect\|loadPreferences" lib/services/ble_bridge_service.dart
flutter analyze lib/services/ble_bridge_service.dart
```

**Manual test**: Configure bridge MAC and auto-connect, kill and restart app, observe Settings → BLE Bridge status transitions to "Connecting".

**Risks**: Low. Delayed and guarded by conditions.

---

### BRIDGE-08 — Write bridge message unit tests

**Goal**: Add unit tests for `BridgeMessage` serialization, sequence number wrapping, and queue deduplication logic.

**Context files to read first**:
- `lib/models/bridge_message.dart` (BRIDGE-01)
- `lib/services/ble_bridge_service.dart` (BRIDGE-03)
- `test/widget_test.dart` (existing test structure)

**Target files to create**:
- `test/bridge_message_test.dart`

**Files NOT to touch**: Production source files.

**Implementation**:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/models/bridge_message.dart';

void main() {
  group('BridgeMessage', () {
    test('scoreUpdate serializes correctly', () {
      final msg = BridgeMessage.scoreUpdate(2, 3);
      final bytes = msg.copyWith(seqNum: 5).toBytes();
      expect(bytes[0], kBridgeProtocolVersion);
      expect(bytes[1], BridgeMessageType.scoreUpdate.index);
      expect(bytes[2], 5); // seqNum
      expect(bytes[3], 2); // scoreA
      expect(bytes[4], 3); // scoreB
    });

    test('gameState serializes remaining time correctly', () {
      final msg = BridgeMessage.gameState(0, 300);
      final bytes = msg.toBytes();
      expect(bytes[3], 0);   // stageIndex
      expect(bytes[4], 1);   // 300 >> 8 = 1
      expect(bytes[5], 44);  // 300 & 0xFF = 44
    });

    test('score message is deduplicatable', () {
      expect(BridgeMessage.scoreUpdate(1, 0).deduplicatable, isTrue);
    });
  });
}
```

**Acceptance criteria**:
- `flutter test test/bridge_message_test.dart` passes

**Verification commands**:
```bash
flutter test test/bridge_message_test.dart
```

**Risks**: Very low.

---

### BRIDGE-09 — Update documentation

**Goal**: After completing BRIDGE-01 through BRIDGE-08, update AI documentation to reflect the actual implementation.

**Context files to read first**:
- `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md`
- `docs/ai/01_PROJECT_MAP.md`

**Target files to modify**:
- `docs/ai/01_PROJECT_MAP.md` — add `ble_bridge_service.dart` and `bridge_message.dart` to file map and key classes table
- `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md` — update PROPOSED sections with confirmed protocol values (UUIDs etc)

**Implementation**: Update the relevant sections with actual confirmed values from the implementation.

**Risks**: Very low. Documentation only.

---

## Dependency ordering

```
PLAY-01 → PLAY-02 → PLAY-03 → PLAY-04 → PLAY-05 → PLAY-06 → PLAY-07
AUDIT-FIX-01 (independent)
AUDIT-FIX-02 (independent)
AUDIT-FIX-03 (independent)
BRIDGE-01 → BRIDGE-02 → BRIDGE-03 → BRIDGE-04 → BRIDGE-05 → BRIDGE-06 → BRIDGE-07 → BRIDGE-08 → BRIDGE-09
```

PLAY and AUDIT tasks are independent of BRIDGE tasks. Run PLAY tasks first for safety.
