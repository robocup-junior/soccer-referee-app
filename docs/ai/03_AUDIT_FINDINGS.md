# Audit Findings

Severity scale: **Critical** / **High** / **Medium** / **Low** / **UNKNOWN**

---

## Confirmed Issues

### AUDIT-01 — AGP version mismatch
**Severity**: High  
**Files**: `android/build.gradle:14`, `android/settings.gradle:21`  
**Issue**: `android/build.gradle` declares `classpath "com.android.tools.build:gradle:8.1.4"` while `android/settings.gradle` declares `id "com.android.application" version "8.3.2"`. Two different AGP versions are in play. The settings.gradle plugin version wins for the new declarative plugin approach, but the classpath in build.gradle is also evaluated. This creates an ambiguous build configuration.  
**Why it matters**: Inconsistent AGP can cause confusing build failures, especially during Flutter upgrade. Both files need to agree on the same version.  
**What to change**: Remove the `buildscript { classpath "..." }` block from `android/build.gradle` (it's redundant with the declarative plugin approach in `settings.gradle`), or align both to the same version. Prefer keeping `settings.gradle` approach.  
**Codex verification**: `grep -n "com.android.tools.build:gradle\|com.android.application" android/build.gradle android/settings.gradle`  
**Safe for small task**: Yes (PLAY-01)

---

### AUDIT-02 — Widget test is broken
**Severity**: Low  
**File**: `test/widget_test.dart:17`  
**Issue**: `await tester.pumpWidget(MyApp())` — `MyApp` requires a `game` parameter (named, required). The test has been broken since the `MyApp` constructor was changed. Also the test assertions look for a counter (`find.text('0')`, `find.byIcon(Icons.add)`) that does not exist in this app.  
**Why it matters**: `flutter test` will fail. CI would catch this but there is no CI for tests. More importantly, there are zero meaningful tests for any business logic.  
**What to change**: Either delete the test or replace with a minimal smoke test that correctly constructs `MyApp(game: Game())`.  
**Codex verification**: `flutter test`  
**Safe for small task**: Yes (see AUDIT task in CODEX_TASKS)

---

### AUDIT-03 — No automatic BLE reconnect for robot modules
**Severity**: Medium  
**File**: `lib/models/module.dart:502-523` (`_registerBleSubscriber`)  
**Issue**: When a BLE device disconnects, the handler sets `_isConnected = false` and calls `notifyListeners()`. The comment says "typically, start a periodic timer that tries to reconnect" but this is not implemented.  
**Why it matters**: During a RoboCup match, if a robot module BLE connection drops, it stays disconnected and the referee must manually reconnect via settings. This is a usability risk during competition.  
**What to change**: On disconnection, if `bleDevice != null` and module `isEnabled`, schedule a reconnect attempt (e.g., `Future.delayed(2s).then((_) => bleConnect())`).  
**Risk of fix**: Medium — reconnect logic can cause race conditions if not carefully bounded (e.g., don't reconnect if user explicitly disconnected, don't reconnect during `disable()`).  
**Codex verification**: Cannot be verified without a real BLE device. Mark as manual test.

---

### AUDIT-04 — Duplicate BLE scan listeners accumulate
**Severity**: Medium  
**File**: `lib/screens/module_settings.dart:83`  
**Issue**: `FlutterBluePlus.scanResults.listen(...)` is called inside `startScanning()` without saving the subscription or canceling a previous one. If the user presses "Scan" multiple times, multiple listeners attach, causing devices to potentially be processed multiple times (though the `!devices.contains(...)` check mitigates visible duplicates).  
**Why it matters**: Memory leak / listener accumulation if scanning is started multiple times in one screen session.  
**What to change**: Save `scanResults.listen(...)` to a `StreamSubscription` field, and `cancel()` it before re-subscribing.  
**Codex verification**: Code review only. Manual test: open module settings, scan, scan again, verify single listener via debug logs.  
**Safe for small task**: Yes

---

### AUDIT-05 — `setupGameCallbacks` called every build cycle
**Severity**: Medium  
**File**: `lib/screens/home.dart:36`, `lib/screens/home.dart:524`  
**Issue**: `setupGameCallbacks(game, context)` is called in `Home.build()`. This overwrites `game.onRequestSwitchTeamOrderDialog` on every rebuild. The callback captures `context`, which is valid since it's the current build context. However, if the widget rebuilds while a dialog is shown, the callback is replaced with a new closure capturing a potentially different context position. In practice this is harmless today, but it is fragile.  
**Why it matters**: `Home` is a `StatelessWidget` which rebuilds whenever `Game` notifies. Since `setupGameCallbacks` overwrites a Game field, it creates a subtle coupling between the view and model.  
**What to change**: Move `setupGameCallbacks` to a `StatefulWidget.initState()` or a dedicated `didChangeDependencies()`. Convert `Home` to `StatefulWidget`.  
**Safe for small task**: Medium complexity

---

### AUDIT-06 — `bleSendScore()` has hardcoded 200ms delay
**Severity**: Low  
**File**: `lib/models/module.dart:228`  
**Issue**: `await Future.delayed(const Duration(milliseconds: 200))` is called before every score BLE write. This means all score updates to all modules take at least 200ms + network. With 10 modules, sends are concurrent (not awaited in caller) so the total wall-clock time is ~200ms + BLE round-trip, not 2000ms.  
**Why it matters**: Minor latency on score display in robot UI. The 200ms was added to avoid BLE write conflicts during reconnect initialization. This is a reasonable tradeoff but should be documented.  
**Safe for change**: Low risk to reduce or remove the delay once reconnect is stable.

---

### AUDIT-07 — `halfTimeAll()` and `gameOverAll()` use `Future.delayed(1s)` with fire-and-forget
**Severity**: Low  
**File**: `lib/models/game.dart:273-295`  
**Issue**: Both methods are declared `async` but called without `await` (e.g., from `startTimer()` callback). Inside, they call `stopAll(true)`, then `await Future.delayed(1s)`, then send half-time/game-over BLE commands. Since the caller doesn't await, the 1-second delay runs in the background.  
**Why it matters**: This is intentional but fragile — if the game state changes during that 1-second window (e.g., user resets game), the delayed half-time/game-over commands will still fire. No guard checks current stage before the delayed send.  
**What to change**: Add a stage check before the delayed command: `if (currentStage != expectedStage) return;`  
**Safe for small task**: Yes, low risk

---

### AUDIT-08 — MQTT reconnect loop can run indefinitely with no circuit-breaker
**Severity**: Low  
**File**: `lib/services/mqtt.dart:376-389`  
**Issue**: `_attemptReconnect()` loops `while (_isEnabled == true && _client != null && !isConnected)` with 5-second delays. If the broker is permanently unreachable, this loop runs forever. `_client` is only set to `null` on solicited disconnect, not on failed reconnects. Battery drain risk during competitions with poor connectivity.  
**What to change**: Add a max-retries counter (e.g., stop after 10 attempts or switch to exponential backoff with a cap).  
**Safe for small task**: Yes

---

### AUDIT-09 — Game parameters not persisted across app restarts
**Severity**: Low  
**File**: `lib/models/game.dart:22-24`  
**Issue**: `periodTime`, `halfTimeDuration`, `numberOfPLayers`, `penaltyTime` are in-memory only. If the app is killed and restarted mid-setup, the referee must re-enter all game parameters.  
**Why it matters**: RoboCup competitions require specific time settings. Having to re-enter settings after an app crash mid-match is a usability risk.  
**What to change**: Persist these 4 values to `SharedPreferences` on change, load in `Game` constructor.  
**Safe for small task**: Yes

---

### AUDIT-10 — `bleSendHalfTime()` variable named `seconds` holds milliseconds
**Severity**: Low (naming only, no functional bug)  
**File**: `lib/models/module.dart:184-200`  
**Issue**: `int seconds = 300; seconds = (_game.remainingTime * 1000) + 1000;` — the variable is reassigned to milliseconds immediately. The initial value `300` is never used. Naming is misleading.  
**What to change**: Rename to `millis` or `durationMs`.  
**Safe for small task**: Yes (pure rename)

---

### AUDIT-11 — `flutter_settings_ui` is an unused dependency
**Severity**: Low  
**File**: `pubspec.yaml:38`  
**Issue**: `flutter_settings_ui: ^3.0.1` appears in `pubspec.yaml` dependencies but is never imported in any Dart file. The settings UI is built with custom widgets.  
**What to change**: Remove from `pubspec.yaml` and run `flutter pub get`.  
**Safe for small task**: Yes

---

### AUDIT-12 — `android/key.properties` credentials in plain text
**Severity**: Low (file is gitignored, but file exists locally)  
**File**: `android/key.properties`  
**Issue**: File contains keystore store password, key password, key alias, and path to keystore JKS file in plain text. File is correctly listed in `.gitignore`.  
**Risk**: If `.gitignore` is ever cleared or file is accidentally added, credentials would be committed. The keystore path is an absolute path on the developer machine.  
**What to change**: No code change needed. Ensure the keystore is backed up separately. Consider using environment variables for CI.

---

### AUDIT-13 — Default MQTT credentials hardcoded in source
**Severity**: Medium (information exposure)  
**File**: `lib/services/mqtt.dart:63-65`  
**Issue**: Default server address, username, and port are hardcoded as fallback values for `SharedPreferences`. These will appear in any public fork or decompiled APK.  
**What to change**: Move defaults to a config file not included in source, or use empty string defaults and require user configuration.  
**Safe for small task**: Yes, but requires deciding on new defaults.

---

## Risks / UNKNOWNs

### RISK-01 — BLE connection limit with 10 robots UNKNOWN
**Severity**: UNKNOWN  
**Issue**: Android OS typically supports 7-10 BLE connections simultaneously. The app supports up to 10 modules. Whether 10 concurrent connections reliably work depends on the Android BLE stack version and hardware. The 100ms delay in `bleConnect()` (line 102 of module.dart) suggests this has been observed to cause issues.  
**How to verify**: Test on competition hardware with 10 simultaneous connections.

---

### RISK-02 — App lifecycle / background BLE behavior UNKNOWN
**Severity**: UNKNOWN  
**Issue**: When the phone screen turns off or the app is backgrounded, Android may restrict BLE write operations. The app does not hold a foreground service or wake lock. BLE connections may drop or writes may fail silently.  
**How to verify**: During a match simulation, turn off the phone screen and verify BLE commands still reach robots.

---

### RISK-03 — `BluetoothDevice.fromId()` on Android with address validation UNKNOWN
**Severity**: Low/UNKNOWN  
**File**: `lib/screens/module_settings.dart:218`  
**Issue**: `BluetoothDevice.fromId(_controller.text.toUpperCase())` creates a device from a MAC string without validating it against a scanned device list. On some Android versions, random/private BLE addresses change over time. If a module uses a random address, the saved MAC may become invalid.  
**How to verify**: Test whether modules use static (public) or random BLE addresses.

---

### RISK-04 — Half-time switch-team dialog context safety
**Severity**: Low/UNKNOWN  
**File**: `lib/screens/home.dart:524-568`  
**Issue**: `game.onRequestSwitchTeamOrderDialog` calls `showDialog(context: context)` where context is captured in the closure. If the Home widget is unmounted or context is stale when the timer fires, this could throw. Modern Flutter catches most of these but it's worth verifying.

---

## Performance Notes

- Robot BLE sends are concurrent (unawaited async calls to each module). The core latency path is sound.
- MQTT publish calls are synchronous on the event loop but non-blocking (they just queue messages in the MQTT client). Risk of event loop jank is low.
- The 1-second timer tick calls `notifyAllModulesTimer()` which iterates all damage-state modules. With ≤10 modules this is trivial.
- `notifyListeners()` in `Game` during timer tick triggers rebuilds of all widgets subscribed to `Game`. The home screen layout is rebuilt every second. This is acceptable for this UI scale.
