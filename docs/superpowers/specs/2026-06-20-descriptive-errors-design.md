# Descriptive Errors — Design Spec

**Issue:** [#3 — Make errors significantly more descriptive](https://github.com/robocup-junior/soccer-referee-app/issues/3) ("Currently it mostly says just error if for instance Bluetooth is turned off and it takes a while to figure out").

**Date:** 2026-06-20
**Status:** Approved design, pre-implementation.

## Problem

Errors across the app are either **generic** ("Connection error", "Error",
"Error loading matches") or **silently swallowed** (`debugPrint` only, no
user-facing signal). A referee hitting a problem during a match — Bluetooth
off, a robot out of range, a bad match-data URL — gets no actionable
information and has to guess. The headline example: when Bluetooth is off the
app does not clearly say so.

The MQTT service (`lib/services/mqtt.dart`) is the existing **gold standard**:
it classifies exceptions and broker return codes into specific messages
(`"Auth failed: Bad username/password"`) and surfaces them via a
`lastErrorMessage` that Settings renders. This spec brings every other
subsystem up to that bar.

## Goals

- Replace generic/silent failures with **"what happened — what to do"**
  messages across BLE modules, BLE bridge, match-data/HTTP, and the global
  Bluetooth-off condition.
- Make the **Bluetooth-off / unauthorized** condition immediately visible on
  the Home screen.
- Keep it **lean**: one small mapping helper + standard Material widgets. No
  new packages, no functional/`Either` error stack, no app-wide notification
  framework.

## Non-goals

- No change to robot START/STOP latency paths
  (`bleSendPlayAll`/`bleSendStopAll` stay fire-and-forget — see CLAUDE.md
  invariant 1). Error surfacing must never add awaits or synchronization to
  those calls.
- No change to double-tap safety, provider tree, or portrait-only invariants.
- No retry/auto-recovery logic beyond what already exists.
- No logging/telemetry backend.

## Architecture

Three pieces, each small and independently testable.

### 1. Shared error helper — `lib/services/error_messages.dart` (new)

A pure mapping layer, no state, no I/O:

```dart
class ErrorInfo {
  final String message; // what happened, one line
  final String? hint;   // what to do, optional
  const ErrorInfo(this.message, {this.hint});
}

/// Classify a caught error/exception into a user-facing ErrorInfo.
/// `context` lets callers prefix (e.g. "Module 3", "Bridge").
ErrorInfo describeError(Object error, {String? context});

/// BLE adapter state → ErrorInfo (off / unauthorized / unavailable / ...).
ErrorInfo describeAdapterState(BluetoothAdapterState state);
```

`describeError` classifies by **type/category**, not brittle string matching:

| Caught | Message | Hint |
|---|---|---|
| `BluetoothAdapterState != on` | "Bluetooth is off" / "Bluetooth permission denied" / "Bluetooth unavailable on this device" | "Turn it on to connect robots" / "Allow Bluetooth in app settings" |
| GATT service/characteristic not found | "Couldn't find robot service" | "Wrong device, or robot firmware not running" |
| `TimeoutException` / connect timeout | "Connection timed out" | "Move closer or check the robot is powered" |
| Permission denied (`FlutterBluePlusException` perm codes) | "Bluetooth permission denied" | "Allow Bluetooth in app settings" |
| `SocketException` / `NoConnectionException` | "Network error: unable to connect" | "Check Wi-Fi / network" |
| HTTP non-200 | "Server returned <code>" | "Check the match-data URL in settings" |
| `FormatException` / JSON parse | "Unexpected response format" | "Check the match-data URL in settings" |
| MQTT return codes | (the existing MQTT strings, moved here) | — |
| fallback | "Something went wrong: <short>" | — |

The existing MQTT mapping moves into this helper so it is the single source of
truth; `mqtt.dart` calls `describeError`/the MQTT mapper instead of inlining
the if-chain. Behavior-equivalent for MQTT (same strings), just relocated.

### 2. Per-subsystem error state (mirror MQTT's `lastErrorMessage`)

Each service exposes the descriptive message the way MQTT already does, so the
UI can render it. Concretely:

- **`lib/models/module.dart`** — `bleConnect()` (currently sets
  `bleStatus = 'Connection error'`, `module.dart:129`) sets `bleStatus` from
  `describeError(e, context: 'Module N')`. `bleCheckServicesAndGetCharacteristics()`
  (`:141`, `:150` — currently silent before `bleDisconnect()`) sets a
  descriptive `bleStatus` ("Couldn't find robot service") before
  disconnecting, so the user sees *why* it dropped instead of a bare revert.
  `enableRXNotifications()` (`:167`, silent) sets a non-fatal status.
- **`lib/services/ble_bridge_service.dart`** — add a `lastErrorMessage`
  (parity with MQTT). `_setErrorAndDisconnect()` (`:188`) takes an
  `ErrorInfo`/message; `connect()` catch (`:81`), `_onConnected` catch (`:182`),
  and `_discoverBridgeCharacteristic()` failures (`:213`, `:221`) populate it
  so the bridge status shows a cause instead of bare "Error".
- **`lib/services/match_data.dart`** — `fetchMatches()` throws a typed/contextful
  error including the HTTP status (`:67`); `loadMatch()` (`:118`) sets
  `stateNotifier.value` from `describeError(e)` instead of the generic
  "Error loading matches". "Match not found" stays (it is already specific).
- **`lib/services/ble.dart`** — `enableBLE()` (`:70`, silent catch) no longer
  swallows; `initCheck()` reuses `describeAdapterState`. Used by the banner below.

### 3. UI surfacing — standard Material widgets

| Error nature | Widget | Location |
|---|---|---|
| Persistent global (Bluetooth off/unauthorized/unavailable) | **`MaterialBanner`** via `ScaffoldMessenger.showMaterialBanner()` | Home (`lib/screens/home.dart`) |
| Transient action failure (send failed, scan empty) | **`SnackBar`** (already used) | module_settings / settings |
| Persistent per-item status (module/bridge/match-data) | **inline colored status text** (already the pattern) | module_settings / settings |
| Needs acknowledgement (existing BT warning, iOS QR mismatch) | **`Dialog`** (already used) | settings / module_settings — reword only |

**The Bluetooth banner (the headline fix):**

A long-lived subscription to `FlutterBluePlus.adapterState` drives a notifier
(`ValueNotifier<BluetoothAdapterState>`), owned by a small holder reachable
from `Game` (e.g. on `BLEServices` or a thin `BleAdapterMonitor`). Home watches
it; when state `!= on`, it shows a `MaterialBanner`:

> ⚠️ **Bluetooth is off** — Turn it on to connect robots. **[Open settings]**

The banner appears/clears automatically as the user toggles Bluetooth (stream
is event-driven), and the action opens Bluetooth settings (Android:
`FlutterBluePlus.turnOn()` where available, else app/BT settings; iOS:
guidance only). The subscription is created once and cancelled on dispose to
avoid duplicate listeners (per flutter_blue_plus guidance).

**Consistent visual treatment:** every surface shows ⚠️ icon + one-line
message + optional hint, with an action button only where the user can act
("Open settings", "Retry"). Messages follow "what happened — what to do".

## Data flow

```
raw exception / adapter state
        │
        ▼
describeError() / describeAdapterState()  ← single source of truth
        │  ErrorInfo(message, hint)
        ▼
service state (bleStatus / lastErrorMessage / stateNotifier / adapterState notifier)
        │
        ▼
UI widget (MaterialBanner | SnackBar | inline text | Dialog)
```

## Testing

- **Unit tests** for `describeError`/`describeAdapterState` (pure functions):
  one assertion per category in the table above, including the fallback and the
  preserved MQTT strings. This is the bulk of the test value.
- **MQTT regression:** assert the relocated mapper returns the exact strings
  `mqtt.dart` produced before (no behavior change).
- **Widget test** for the Home Bluetooth banner: pump with adapter state `off`
  → banner present with expected text; `on` → banner absent.
- Manual smoke per CLAUDE.md surfaces: toggle Bluetooth (banner), connect to a
  wrong/absent device (module status), point match-data URL at a 404 (schedule
  status), wrong MQTT password (unchanged, confirms parity).

## Invariants preserved

- START/STOP fire-and-forget paths untouched (no awaits added).
- All destructive UI actions remain `onDoubleTap`.
- Provider tree and portrait-only unchanged.
- No new dependencies; only `flutter_blue_plus` (already present) + Material.

## Files touched

- **new:** `lib/services/error_messages.dart`, plus its test.
- **edit:** `lib/models/module.dart`, `lib/services/ble_bridge_service.dart`,
  `lib/services/match_data.dart`, `lib/services/ble.dart`,
  `lib/services/mqtt.dart` (relocate mapping), `lib/screens/home.dart` (banner),
  and minor wording in `lib/screens/settings.dart` /
  `lib/screens/module_settings.dart` dialogs.
- A holder for the adapter-state notifier (on `BLEServices` or a small monitor,
  reachable from `Game`).
