# Descriptive Errors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace generic/silent error messages across BLE, bridge, match-data, and the global Bluetooth-off condition with descriptive "what happened — what to do" messages, matching the MQTT service's existing standard.

**Architecture:** One pure mapping helper (`error_messages.dart`) is the single source of truth turning exceptions/states into `ErrorInfo(message, hint)`. Each service surfaces that message the way MQTT already does. A `MaterialBanner` on Home, driven by a testable `BleAdapterMonitor` around `FlutterBluePlus.adapterState`, makes Bluetooth-off immediately visible.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_blue_plus` 1.36.8, `mqtt_client`, `provider`, `flutter_test`. Package name: `rcj_scoreboard`.

## Global Constraints

- **START/STOP latency invariant:** never add `await`/blocking/synchronization to `bleSendPlayAll()`/`bleSendStopAll()` or the `playAll`/`stopAll` paths (`module.dart`). This plan does not touch them.
- **Double-tap safety:** all destructive UI actions stay `onDoubleTap`. The banner's only action is a non-destructive "Open settings" button.
- **Provider tree:** the existing registrations in `main.dart` (Game, bridge, 2 Teams, 10+10 Modules) must remain. New providers may be **added** only.
- **Portrait-only:** do not touch `SystemChrome.setPreferredOrientations`.
- **No new packages.** Only already-present deps.
- **Message style:** one-line message + optional short hint, phrased "what happened — what to do".
- **Tests** live in `test/`, use `package:flutter_test`, import via `package:rcj_scoreboard/...`. Run with `flutter test`.

---

### Task 1: Error-message helper (the single source of truth)

**Files:**
- Create: `lib/services/error_messages.dart`
- Test: `test/error_messages_test.dart`

**Interfaces:**
- Consumes: `flutter_blue_plus` (`BluetoothAdapterState`, `FlutterBluePlusException`), `mqtt_client` (`MqttConnectReturnCode`).
- Produces (later tasks rely on these exact signatures):
  - `class ErrorInfo { final String message; final String? hint; const ErrorInfo(this.message, {this.hint}); }`
  - `class HttpStatusException implements Exception { final int statusCode; final String? url; const HttpStatusException(this.statusCode, {this.url}); }`
  - `ErrorInfo describeError(Object error)`
  - `ErrorInfo describeAdapterState(BluetoothAdapterState state)`
  - `String describeMqttReturnCode(MqttConnectReturnCode code)`

- [ ] **Step 1: Write the failing test**

```dart
// test/error_messages_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';

void main() {
  group('describeAdapterState', () {
    test('off is descriptive and actionable', () {
      final info = describeAdapterState(BluetoothAdapterState.off);
      expect(info.message, 'Bluetooth is off');
      expect(info.hint, 'Turn it on to connect robots');
    });

    test('unauthorized points at permissions', () {
      final info = describeAdapterState(BluetoothAdapterState.unauthorized);
      expect(info.message, 'Bluetooth permission denied');
      expect(info.hint, 'Allow Bluetooth in app settings');
    });

    test('unavailable means no hardware', () {
      final info = describeAdapterState(BluetoothAdapterState.unavailable);
      expect(info.message, 'Bluetooth unavailable on this device');
    });
  });

  group('describeError', () {
    test('HttpStatusException includes the status code', () {
      final info = describeError(const HttpStatusException(404, url: 'http://x'));
      expect(info.message, 'Server returned 404');
      expect(info.hint, 'Check the match-data URL in settings');
    });

    test('SocketException is a network error', () {
      final info = describeError(const SocketException('boom'));
      expect(info.message, 'Network error: unable to connect');
      expect(info.hint, 'Check the network / Wi-Fi connection');
    });

    test('TimeoutException is a timeout', () {
      final info = describeError(TimeoutException('slow'));
      expect(info.message, 'Connection timed out');
      expect(info.hint, 'Move closer or check the device is powered');
    });

    test('FormatException is a bad response format', () {
      final info = describeError(const FormatException('bad json'));
      expect(info.message, 'Unexpected response format');
      expect(info.hint, 'Check the match-data URL in settings');
    });

    test('FlutterBluePlusException is a BLE failure', () {
      final info = describeError(
        FlutterBluePlusException(ErrorPlatform.android, 'connect', 133, 'gatt'),
      );
      expect(info.message, 'Bluetooth connection failed');
      expect(info.hint, 'Move closer, re-power the robot, or re-scan');
    });

    test('unknown error falls back without crashing', () {
      final info = describeError('weird');
      expect(info.message, startsWith('Something went wrong'));
    });
  });

  group('describeMqttReturnCode', () {
    test('bad credentials map to the existing string', () {
      expect(describeMqttReturnCode(MqttConnectReturnCode.badUsernameOrPassword),
          'Auth failed: Bad username/password');
    });

    test('broker unavailable maps to the existing string', () {
      expect(describeMqttReturnCode(MqttConnectReturnCode.brokerUnavailable),
          'Connection failed: Broker unavailable');
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/error_messages_test.dart`
Expected: FAIL — `error_messages.dart` / `describeError` not found (compile error).

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/services/error_messages.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mqtt_client/mqtt_client.dart';

/// A user-facing error: one-line [message] plus an optional actionable [hint].
class ErrorInfo {
  final String message;
  final String? hint;
  const ErrorInfo(this.message, {this.hint});
}

/// Thrown by match-data fetches when the server responds with a non-200 code.
/// Defined here (not in match_data.dart) so [describeError] can classify it
/// without a circular import.
class HttpStatusException implements Exception {
  final int statusCode;
  final String? url;
  const HttpStatusException(this.statusCode, {this.url});

  @override
  String toString() => 'HttpStatusException($statusCode, $url)';
}

/// Classify a caught error into a user-facing [ErrorInfo]. Classifies by type,
/// not by brittle string matching.
ErrorInfo describeError(Object error) {
  if (error is HttpStatusException) {
    return ErrorInfo('Server returned ${error.statusCode}',
        hint: 'Check the match-data URL in settings');
  }
  if (error is TimeoutException) {
    return const ErrorInfo('Connection timed out',
        hint: 'Move closer or check the device is powered');
  }
  if (error is SocketException) {
    return const ErrorInfo('Network error: unable to connect',
        hint: 'Check the network / Wi-Fi connection');
  }
  if (error is FormatException) {
    return const ErrorInfo('Unexpected response format',
        hint: 'Check the match-data URL in settings');
  }
  if (error is FlutterBluePlusException) {
    return const ErrorInfo('Bluetooth connection failed',
        hint: 'Move closer, re-power the robot, or re-scan');
  }
  return ErrorInfo('Something went wrong: $error');
}

/// Map a BLE adapter state to a user-facing message for the Home banner and
/// the connect screen.
ErrorInfo describeAdapterState(BluetoothAdapterState state) {
  switch (state) {
    case BluetoothAdapterState.off:
    case BluetoothAdapterState.turningOff:
      return const ErrorInfo('Bluetooth is off',
          hint: 'Turn it on to connect robots');
    case BluetoothAdapterState.unauthorized:
      return const ErrorInfo('Bluetooth permission denied',
          hint: 'Allow Bluetooth in app settings');
    case BluetoothAdapterState.unavailable:
      return const ErrorInfo('Bluetooth unavailable on this device');
    default:
      // on / turningOn / unknown — caller decides whether to show anything.
      return const ErrorInfo('Bluetooth not ready');
  }
}

/// MQTT broker return code → message. Relocated verbatim from mqtt.dart so the
/// strings stay identical (single source of truth).
String describeMqttReturnCode(MqttConnectReturnCode code) {
  switch (code) {
    case MqttConnectReturnCode.unacceptedProtocolVersion:
      return 'Connection failed: Invalid protocol version';
    case MqttConnectReturnCode.identifierRejected:
      return 'Connection failed: Invalid client identifier';
    case MqttConnectReturnCode.brokerUnavailable:
      return 'Connection failed: Broker unavailable';
    case MqttConnectReturnCode.badUsernameOrPassword:
      return 'Auth failed: Bad username/password';
    case MqttConnectReturnCode.notAuthorized:
      return 'Auth failed: Invalid credentials';
    case MqttConnectReturnCode.noneSpecified:
      return 'Connection failed: No return code specified';
    default:
      return 'Connection failed: $code';
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/error_messages_test.dart`
Expected: PASS (all groups).

- [ ] **Step 5: Commit**

```bash
git add lib/services/error_messages.dart test/error_messages_test.dart
git commit -F - <<'EOF'
feat(errors): add error_messages helper as single source of truth

Errors were classified ad hoc (or not at all) per call site. This adds a
pure mapping helper that turns exceptions and BLE adapter states into a
user-facing ErrorInfo(message, hint), to be consumed by every subsystem.

- describeError: HTTP status, socket, timeout, format, BLE, fallback
- describeAdapterState: off/unauthorized/unavailable wording
- describeMqttReturnCode: MQTT strings relocated verbatim from mqtt.dart
- HttpStatusException defined here to avoid a circular import
EOF
```

---

### Task 2: Route MQTT through the shared mapper (no behavior change)

**Files:**
- Modify: `lib/services/mqtt.dart:199-213` (the return-code if-chain)
- Test: `test/error_messages_test.dart` (already covers the strings — this task only proves the relocation didn't change them)

**Interfaces:**
- Consumes: `describeMqttReturnCode(MqttConnectReturnCode)` from Task 1.
- Produces: nothing new.

- [ ] **Step 1: Verify the relocation target strings are already asserted**

The `describeMqttReturnCode` tests in Task 1 assert the exact strings. No new test needed; this task makes `mqtt.dart` call the helper so those strings have one definition.

- [ ] **Step 2: Replace the inline if-chain with the helper**

Add the import near the top of `lib/services/mqtt.dart` (with the other imports):

```dart
import 'package:rcj_scoreboard/services/error_messages.dart';
```

Replace the block at `mqtt.dart:198-213` (from `final status = ...` through the closing `}` of the if/else-if chain) with:

```dart
      final status = _client!.connectionStatus!;
      _lastErrorMessage = describeMqttReturnCode(status.returnCode);
```

Leave the surrounding `NoConnectionException`/`SocketException` catches (`mqtt.dart:183-190`) unchanged — they are tied to MQTT's connect flow.

- [ ] **Step 3: Run tests + analyze**

Run: `flutter test test/error_messages_test.dart && flutter analyze lib/services/mqtt.dart`
Expected: tests PASS; analyze reports no new issues.

- [ ] **Step 4: Commit**

```bash
git add lib/services/mqtt.dart
git commit -F - <<'EOF'
refactor(mqtt): use shared describeMqttReturnCode mapper

The broker return-code -> message if-chain lived inline in connect().
This routes it through the shared helper so the strings have a single
definition. Behavior is unchanged (same strings, asserted by tests).
EOF
```

---

### Task 3: Descriptive match-data / HTTP errors

**Files:**
- Modify: `lib/services/match_data.dart:57-69` (`fetchMatches`), `:110-121` (`loadMatch` catch)
- Test: `test/match_data_error_test.dart` (create)

**Interfaces:**
- Consumes: `HttpStatusException`, `describeError` from Task 1.
- Produces: `fetchMatches` now throws `HttpStatusException` on non-200.

- [ ] **Step 1: Write the failing test**

```dart
// test/match_data_error_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';

void main() {
  // loadMatch() drives stateNotifier through describeError; this proves the
  // mapping produces the descriptive schedule-load message for an HTTP error.
  test('describeError on a 404 yields the schedule-load message', () {
    final info = describeError(const HttpStatusException(404));
    expect(info.message, 'Server returned 404');
    expect(info.hint, 'Check the match-data URL in settings');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/match_data_error_test.dart`
Expected: FAIL until Task 1 is present; if Task 1 is merged it PASSES — that's fine, this test mainly guards the wiring done in Step 3.

- [ ] **Step 3: Wire match_data to throw/translate**

In `lib/services/match_data.dart`, add the import:

```dart
import 'package:rcj_scoreboard/services/error_messages.dart';
```

Replace the `else` branch of `fetchMatches` (`match_data.dart:66-68`):

```dart
    } else {
      throw HttpStatusException(response.statusCode, url: url);
    }
```

Replace the first `catch` in `loadMatch` (`match_data.dart:117-121`):

```dart
    } catch (e) {
      stateNotifier.value = describeError(e).message;
      debugPrint('Error loading matches: $e');
      return null;
    }
```

Leave the "Match not found" branch (`:131`) as-is — it is already specific.

- [ ] **Step 4: Run tests + analyze**

Run: `flutter test test/match_data_error_test.dart && flutter analyze lib/services/match_data.dart`
Expected: PASS; no new analyze issues.

- [ ] **Step 5: Commit**

```bash
git add lib/services/match_data.dart test/match_data_error_test.dart
git commit -F - <<'EOF'
feat(match-data): surface HTTP status instead of generic load error

fetchMatches threw a generic Exception and loadMatch showed "Error
loading matches", hiding the cause (404, timeout, bad URL). It now
throws HttpStatusException with the code and translates failures via
describeError, so the schedule status names what went wrong.
EOF
```

---

### Task 4: Descriptive BLE module errors (connect + service discovery)

**Files:**
- Modify: `lib/models/module.dart` — `bleConnect()` (`:122-133`), `bleCheckServicesAndGetCharacteristics()` (`:137-158`), `bleDisconnect()` (`:319-342`)
- Test: covered by Task 1's `describeError` tests (module wiring is exercised manually — BLE needs a device).

**Interfaces:**
- Consumes: `describeError` from Task 1.
- Produces: `bleDisconnect({String? reason})` — when `reason` is non-null, `bleStatus` is set to it instead of `'Disconnected'`.

- [ ] **Step 1: Add the import**

In `lib/models/module.dart` add (with the other imports at the top):

```dart
import 'package:rcj_scoreboard/services/error_messages.dart';
```

- [ ] **Step 2: Make the connect catch descriptive**

Replace the catch body in `bleConnect()` (`module.dart:125-132`):

```dart
    } catch (e) {
      // Gave up — drop the connect intent (parity with the bridge) so a stray
      // event can never flip the message back to "Connecting...".
      _connectIntent = false;
      bleStatus = describeError(e).message;
      debugPrint('BLE connect error: $e');
      subscription?.cancel();
    }
```

- [ ] **Step 3: Let bleDisconnect carry a reason**

Change the signature and the status line in `bleDisconnect()` (`module.dart:319`, `:336`):

```dart
  void bleDisconnect({String? reason}) async {
```

and

```dart
    bleStatus = reason ?? 'Disconnected';
```

(Leave everything else in the method unchanged.)

- [ ] **Step 4: Surface service/characteristic discovery failures**

In `bleCheckServicesAndGetCharacteristics()` replace the two silent failure branches (`module.dart:141-145` and `:148-152`):

```dart
    if (service.isEmpty) {
      debugPrint('Required service not found');
      bleDisconnect(reason: "Couldn't find robot service");
      return false;
    }
```

and

```dart
    if (characteristic == null || characteristic.isEmpty) {
      debugPrint('Required characteristics not found');
      bleDisconnect(reason: 'Robot is missing expected data channel');
      return false;
    }
```

- [ ] **Step 5: Stop the mislabeled/silent send logs (low-risk wording)**

In `enableRXNotifications()` (`module.dart:167-169`) keep the catch but make the log accurate (no user-facing change; the channel is non-fatal):

```dart
      } catch (e) {
        debugPrint('Error enabling RX notifications: $e');
      }
```

(Already correct — confirm it reads `$e` and leave it. Do NOT touch `bleSendStopAll`/`bleSendPlayAll`.)

- [ ] **Step 6: Verify it compiles and the app analyzes clean**

Run: `flutter analyze lib/models/module.dart`
Expected: no new issues. (`bleDisconnect` has no positional callers, so the optional named param is backward compatible — confirm with: `grep -rn "bleDisconnect(" lib/` shows only no-arg calls.)

- [ ] **Step 7: Commit**

```bash
git add lib/models/module.dart
git commit -F - <<'EOF'
feat(ble-module): show why a module failed to connect

bleConnect showed a flat "Connection error" and service/characteristic
discovery failed silently (debugPrint only) before reverting to
"Disconnected", so a referee could not tell wrong-device from
firmware-not-running from out-of-range.

- bleConnect catch now uses describeError(e).message
- bleDisconnect gains an optional reason that becomes the visible status
- service-not-found / characteristic-not-found set descriptive reasons
- START/STOP fire-and-forget send paths left untouched
EOF
```

---

### Task 5: Descriptive BLE bridge errors

**Files:**
- Modify: `lib/services/ble_bridge_service.dart` — add `lastErrorMessage`, `connect()` catch (`:81-84`), `_onConnected` (`:173-177`, `:182-185`), `_setErrorAndDisconnect()` (`:188-204`), `_discoverBridgeCharacteristic()` (`:206-232`)
- Modify: `lib/screens/settings.dart` — bridge status rendering (~`:189-198`) to show `lastErrorMessage`
- Test: covered by Task 1's `describeError`; bridge connect needs a radio (manual).

**Interfaces:**
- Consumes: `describeError` from Task 1.
- Produces: `String? get lastErrorMessage`; `_setErrorAndDisconnect({String? message})`.

- [ ] **Step 1: Add the import + field**

In `lib/services/ble_bridge_service.dart` add the import and a field with a getter (place the field near the other private fields):

```dart
import 'package:rcj_scoreboard/services/error_messages.dart';
```

```dart
  String? _lastErrorMessage;
  String? get lastErrorMessage => _lastErrorMessage;
```

- [ ] **Step 2: Make connect()'s catch descriptive**

Replace the catch in `connect()` (`ble_bridge_service.dart:81-84`):

```dart
    } catch (e) {
      debugPrint('BleBridge: connect error: $e');
      await _setErrorAndDisconnect(message: describeError(e).message);
    }
```

- [ ] **Step 3: Give discovery failures a reason**

Replace the `if (!ready)` branch in `_onConnected` (`ble_bridge_service.dart:174-177`):

```dart
      final ready = await _discoverBridgeCharacteristic();
      if (!ready) {
        await _setErrorAndDisconnect(
            message: 'Scoreboard service not found on this device');
        return;
      }
```

and the `_onConnected` outer catch (`:182-185`):

```dart
    } catch (e) {
      debugPrint('BleBridge: initialization error: $e');
      await _setErrorAndDisconnect(message: describeError(e).message);
    }
```

- [ ] **Step 4: Let _setErrorAndDisconnect record the message**

Change the signature and add one line at the top of `_setErrorAndDisconnect()` (`ble_bridge_service.dart:188`):

```dart
  Future<void> _setErrorAndDisconnect({String? message}) async {
    _lastErrorMessage = message ?? 'Connection error';
```

(Leave the rest of the method unchanged; it already sets the error state and notifies.)

- [ ] **Step 5: Show the message in settings**

In `lib/screens/settings.dart`, find the bridge status rendering near line 189-198 (the `BridgeConnectionState.error` → `'Error'` case). Replace the bare `'Error'` text with the recorded message, falling back to `'Error'`:

```dart
            bridgeService.lastErrorMessage ?? 'Error',
```

(Match the surrounding widget/variable name used for the bridge service in that file; if it is `context.watch<BleBridgeService>()`, read `lastErrorMessage` off that instance.)

- [ ] **Step 6: Verify analyze + existing bridge tests still pass**

Run: `flutter test test/bridge_message_test.dart && flutter analyze lib/services/ble_bridge_service.dart lib/screens/settings.dart`
Expected: PASS; no new analyze issues. (The bridge queue tests never reach the error path, so they remain green.)

- [ ] **Step 7: Commit**

```bash
git add lib/services/ble_bridge_service.dart lib/screens/settings.dart
git commit -F - <<'EOF'
feat(bridge): surface a cause instead of a bare "Error"

The bridge showed a generic "Error" and logged the real reason only to
the console; discovery failures were silent. It now records a
lastErrorMessage (parity with MQTT) populated from describeError or a
specific discovery reason, and settings renders it.
EOF
```

---

### Task 6: Bluetooth adapter monitor + ble.dart cleanup

**Files:**
- Create: `lib/services/ble_adapter_monitor.dart`
- Modify: `lib/services/ble.dart` — `initCheck()` (`:24-33`) to reuse `describeAdapterState`; `enableBLE()` (`:69-72`) to stop swallowing
- Modify: `lib/models/game.dart` — hold a `BleAdapterMonitor` (mirror `bleBridgeService`)
- Modify: `lib/main.dart:32` — register the monitor as a provider
- Test: `test/ble_adapter_monitor_test.dart` (create)

**Interfaces:**
- Consumes: `describeAdapterState` from Task 1.
- Produces:
  - `class BleAdapterMonitor extends ChangeNotifier { BleAdapterMonitor({Stream<BluetoothAdapterState>? stream}); BluetoothAdapterState get state; bool get isOn; void dispose(); }`
  - `game.bleAdapterMonitor` (a `BleAdapterMonitor`).

- [ ] **Step 1: Write the failing test**

```dart
// test/ble_adapter_monitor_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/services/ble_adapter_monitor.dart';

void main() {
  test('tracks the latest adapter state and notifies', () async {
    final controller = StreamController<BluetoothAdapterState>();
    final monitor = BleAdapterMonitor(stream: controller.stream);
    var notifications = 0;
    monitor.addListener(() => notifications++);

    controller.add(BluetoothAdapterState.off);
    await Future.delayed(Duration.zero);
    expect(monitor.state, BluetoothAdapterState.off);
    expect(monitor.isOn, isFalse);

    controller.add(BluetoothAdapterState.on);
    await Future.delayed(Duration.zero);
    expect(monitor.isOn, isTrue);
    expect(notifications, 2);

    await controller.close();
    monitor.dispose();
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ble_adapter_monitor_test.dart`
Expected: FAIL — `BleAdapterMonitor` not found.

- [ ] **Step 3: Implement the monitor**

```dart
// lib/services/ble_adapter_monitor.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Watches the BLE adapter state for the whole app lifetime so the UI can show
/// a persistent "Bluetooth is off" banner. The [stream] seam keeps it testable
/// without the platform channel.
class BleAdapterMonitor extends ChangeNotifier {
  BluetoothAdapterState _state = BluetoothAdapterState.unknown;
  StreamSubscription<BluetoothAdapterState>? _sub;

  BleAdapterMonitor({Stream<BluetoothAdapterState>? stream}) {
    _sub = (stream ?? FlutterBluePlus.adapterState).listen((s) {
      _state = s;
      notifyListeners();
    });
  }

  BluetoothAdapterState get state => _state;
  bool get isOn => _state == BluetoothAdapterState.on;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ble_adapter_monitor_test.dart`
Expected: PASS.

- [ ] **Step 5: Clean up ble.dart to reuse the helper**

In `lib/services/ble.dart` add the import:

```dart
import 'package:rcj_scoreboard/services/error_messages.dart';
```

Replace the adapter-state branch in `initCheck()` (`ble.dart:24-33`):

```dart
    if (state == BluetoothAdapterState.on) {
      status = 'OK';
    } else {
      status = describeAdapterState(state).message;
    }
```

Replace the swallowing catch in `enableBLE()` (`ble.dart:69-72`) so the failure is at least logged with the error (still returns false; callers handle it):

```dart
      } catch (e) {
        debugPrint('Enable BLE error: $e');
        return false;
      }
```

Note: the later `if (status == 'Bluetooth is disabled')` check (`ble.dart:48`) keys off the old literal. Replace that literal with the helper's wording: `if (status == describeAdapterState(BluetoothAdapterState.off).message)`.

- [ ] **Step 6: Hold the monitor on Game**

In `lib/models/game.dart`, near `BleBridgeService bleBridgeService = BleBridgeService();` (`game.dart:54`), add:

```dart
import 'package:rcj_scoreboard/services/ble_adapter_monitor.dart';
```
```dart
  final BleAdapterMonitor bleAdapterMonitor = BleAdapterMonitor();
```

- [ ] **Step 7: Register the provider (additive only)**

In `lib/main.dart`, add one line to the providers list right after the bridge registration (`main.dart:32`):

```dart
        ChangeNotifierProvider.value(value: game.bleAdapterMonitor),
```

Do not touch the existing registrations.

- [ ] **Step 8: Verify**

Run: `flutter test test/ble_adapter_monitor_test.dart && flutter analyze lib/services/ble.dart lib/services/ble_adapter_monitor.dart lib/models/game.dart lib/main.dart`
Expected: PASS; no new analyze issues.

- [ ] **Step 9: Commit**

```bash
git add lib/services/ble_adapter_monitor.dart lib/services/ble.dart lib/models/game.dart lib/main.dart test/ble_adapter_monitor_test.dart
git commit -F - <<'EOF'
feat(ble): add app-wide adapter-state monitor

Bluetooth-off was only discoverable by trying to connect. This adds a
BleAdapterMonitor (ChangeNotifier over FlutterBluePlus.adapterState, with
a stream seam for tests) held on Game and registered as a provider, to
drive a persistent Home banner. initCheck/enableBLE in ble.dart now reuse
describeAdapterState and stop swallowing the enable error.
EOF
```

---

### Task 7: Home Bluetooth banner

**Files:**
- Create: `lib/screens/widgets/bluetooth_banner.dart`
- Modify: `lib/screens/home.dart` — render the banner at the top of the body
- Test: `test/bluetooth_banner_test.dart` (create)

**Interfaces:**
- Consumes: `describeAdapterState` (Task 1), `BleAdapterMonitor` (Task 6).
- Produces: `class BluetoothBanner extends StatelessWidget { const BluetoothBanner({required this.state, this.onOpenSettings, super.key}); final BluetoothAdapterState state; final VoidCallback? onOpenSettings; }` — renders nothing when `state == on`.

- [ ] **Step 1: Write the failing test**

```dart
// test/bluetooth_banner_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/screens/widgets/bluetooth_banner.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('shows a descriptive banner when Bluetooth is off',
      (tester) async {
    await tester.pumpWidget(
        wrap(const BluetoothBanner(state: BluetoothAdapterState.off)));
    expect(find.text('Bluetooth is off'), findsOneWidget);
    expect(find.text('Turn it on to connect robots'), findsOneWidget);
  });

  testWidgets('renders nothing when Bluetooth is on', (tester) async {
    await tester.pumpWidget(
        wrap(const BluetoothBanner(state: BluetoothAdapterState.on)));
    expect(find.text('Bluetooth is off'), findsNothing);
    expect(find.byType(MaterialBanner), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/bluetooth_banner_test.dart`
Expected: FAIL — `BluetoothBanner` not found.

- [ ] **Step 3: Implement the banner widget**

```dart
// lib/screens/widgets/bluetooth_banner.dart
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';

/// A persistent MaterialBanner shown on Home when the BLE adapter is not on.
/// Renders an empty box when Bluetooth is on, so it can sit unconditionally in
/// the widget tree.
class BluetoothBanner extends StatelessWidget {
  const BluetoothBanner({required this.state, this.onOpenSettings, super.key});

  final BluetoothAdapterState state;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    if (state == BluetoothAdapterState.on) {
      return const SizedBox.shrink();
    }
    final info = describeAdapterState(state);
    return MaterialBanner(
      backgroundColor: Colors.red.shade900,
      leading: const Icon(Icons.bluetooth_disabled, color: Colors.white),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(info.message,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
          if (info.hint != null)
            Text(info.hint!, style: const TextStyle(color: Colors.white70)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: onOpenSettings,
          child: const Text('Open settings',
              style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/bluetooth_banner_test.dart`
Expected: PASS.

- [ ] **Step 5: Mount the banner on Home**

In `lib/screens/home.dart` add the imports:

```dart
import 'package:provider/provider.dart';
import 'package:rcj_scoreboard/services/ble_adapter_monitor.dart';
import 'package:rcj_scoreboard/screens/widgets/bluetooth_banner.dart';
```

(Provider is likely already imported — do not duplicate.) The body of the `Scaffold` (around `home.dart:50` onward) currently starts with a layout widget. Wrap that body so the banner sits above it, watching the monitor:

```dart
        body: Column(
          children: [
            Consumer<BleAdapterMonitor>(
              builder: (context, monitor, _) => BluetoothBanner(
                state: monitor.state,
                onOpenSettings: () => FlutterBluePlus.turnOn(),
              ),
            ),
            Expanded(child: /* existing body widget here */),
          ],
        ),
```

Add `import 'package:flutter_blue_plus/flutter_blue_plus.dart';` for `FlutterBluePlus.turnOn()`. On iOS `turnOn()` is a no-op/throws — wrap the call: `onOpenSettings: () { try { FlutterBluePlus.turnOn(); } catch (_) {} }`. Preserve the existing body widget exactly inside the `Expanded`.

- [ ] **Step 6: Verify the app still builds and analyzes**

Run: `flutter test && flutter analyze lib/screens/home.dart lib/screens/widgets/bluetooth_banner.dart`
Expected: all tests PASS; no new analyze issues.

- [ ] **Step 7: Commit**

```bash
git add lib/screens/widgets/bluetooth_banner.dart lib/screens/home.dart test/bluetooth_banner_test.dart
git commit -F - <<'EOF'
feat(home): persistent Bluetooth-off banner

The headline complaint: Bluetooth off was hard to diagnose. Home now
shows a red MaterialBanner driven by BleAdapterMonitor whenever the
adapter is off/unauthorized/unavailable, with the descriptive wording
from describeAdapterState and an "Open settings" action. The banner
clears automatically when Bluetooth comes back on.
EOF
```

---

### Task 8: Manual verification pass

**Files:** none (verification only).

- [ ] **Step 1: Full test + analyze**

Run: `flutter test && flutter analyze`
Expected: all tests PASS; analyze shows only the pre-existing upstream KGP warnings noted in CLAUDE.md (no new issues from this work).

- [ ] **Step 2: On-device smoke (per CLAUDE.md surfaces)**

- Toggle Bluetooth off → red banner appears on Home; toggle on → banner disappears.
- Tap a module, connect to an absent/wrong device → status shows "Couldn't find robot service" or "Bluetooth connection failed" (not a bare revert to "Disconnected").
- Point match-data URL at a 404 in settings, load → schedule status reads "Server returned 404".
- Set a wrong MQTT password → settings still shows "Auth failed: Bad username/password" (confirms no regression).
- Start/stop robots → confirm latency is unchanged (no awaits added to the all-paths).

- [ ] **Step 3: No commit** (verification only). If any check fails, fix in the owning task and re-run.

---

## Self-Review

**Spec coverage:**
- Shared helper `error_messages.dart` → Task 1. ✓
- MQTT relocation (single source of truth) → Task 2. ✓
- BLE module descriptive + non-silent → Task 4. ✓
- BLE bridge `lastErrorMessage` + discovery reasons → Task 5. ✓
- Match-data HTTP/status → Task 3. ✓
- `ble.dart` stop swallowing + reuse helper → Task 6. ✓
- Adapter monitor + Home `MaterialBanner` → Tasks 6 & 7. ✓
- SnackBar/Dialog rewording: covered by descriptive strings flowing into existing surfaces; no dedicated task needed (the existing iOS QR dialog and BT warning dialog already read clearly — left as-is per YAGNI). ✓
- Testing (pure-function unit tests + banner widget test + monitor test) → Tasks 1, 6, 7; manual smoke → Task 8. ✓
- Invariants (START/STOP, double-tap, provider additive, portrait) → Global Constraints + called out in Tasks 4, 6. ✓

**Placeholder scan:** no TBD/TODO; every code step shows real code; the one "existing body widget here" marker in Task 7 is an explicit instruction to preserve current code, not a placeholder for new code.

**Type consistency:** `ErrorInfo`, `HttpStatusException`, `describeError`, `describeAdapterState`, `describeMqttReturnCode`, `BleAdapterMonitor`, `BluetoothBanner`, `bleDisconnect({String? reason})`, `_setErrorAndDisconnect({String? message})`, `lastErrorMessage` — names used consistently across consuming tasks.
