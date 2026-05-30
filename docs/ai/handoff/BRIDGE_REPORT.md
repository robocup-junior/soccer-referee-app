## BRIDGE-01 — Create bridge_message.dart (topic/value framing)

**Summary**: Added the MQTT-over-BLE topic/value frame model and NUS UUID constants for the BLE bridge.

**Files changed/created**:
- `lib/models/bridge_message.dart` — new `BridgeMessage`, separator constant, NUS UUID constants, and iteration-1 bridge topic names.

**Deviations**: none.

**Verification results**:
```text
$ flutter analyze lib/models/bridge_message.dart
Analyzing bridge_message.dart...
No issues found! (ran in 0.0s)
```

**Manual test status**: No hardware/manual test required for this task.

**Open questions / risks**: none.

## BRIDGE-02a — BleBridgeService skeleton (state + settings, NO BLE yet)

**Summary**: Added `BleBridgeService` with connection and queue-depth notifiers, persisted bridge settings, and public method stubs.

**Files changed/created**:
- `lib/services/ble_bridge_service.dart` — new `ChangeNotifier` service with bridge state, settings persistence, and Milestone A/B API surface.

**Deviations**: Added the private `_processQueue()` stub in this task file so BRIDGE-02b can call it as specified.

**Verification results**:
```text
$ flutter analyze lib/services/ble_bridge_service.dart
Analyzing ble_bridge_service.dart...
No issues found! (ran in 0.1s)

$ grep -n "bridge_enabled\|bridge_mac_address\|bridge_auto_connect\|BridgeConnectionState" lib/services/ble_bridge_service.dart
8:enum BridgeConnectionState {
26:  final ValueNotifier<BridgeConnectionState> connectionStateNotifier =
27:      ValueNotifier(BridgeConnectionState.disconnected);
36:    _isEnabled = prefs.getBool('bridge_enabled') ?? false;
37:    _bridgeMacAddress = prefs.getString('bridge_mac_address') ?? '';
38:    _autoConnect = prefs.getBool('bridge_auto_connect') ?? false;
47:      connectionStateNotifier.value == BridgeConnectionState.connected &&
52:    prefs.setBool('bridge_enabled', value);
58:    prefs.setString('bridge_mac_address', value);
64:    prefs.setBool('bridge_auto_connect', value);
70:        connectionStateNotifier.value == BridgeConnectionState.connecting ||
75:    connectionStateNotifier.value = BridgeConnectionState.connecting;
99:    connectionStateNotifier.value = BridgeConnectionState.disconnected;
113:        connectionStateNotifier.value = BridgeConnectionState.disconnected;
135:      connectionStateNotifier.value = BridgeConnectionState.connected;
155:    connectionStateNotifier.value = BridgeConnectionState.error;
```

**Manual test status**: SharedPreferences persistence was not manually tested on a device/emulator.

**Open questions / risks**: The settings persistence follows the existing async service pattern; Gate A should verify persistence across app restart.

## BRIDGE-02b — Add BLE connect/disconnect/discover/MTU to BleBridgeService

**Summary**: Implemented bridge BLE connect/disconnect, connection-state subscription, MTU request, NUS service discovery, TX characteristic lookup, and error isolation.

**Files changed/created**:
- `lib/services/ble_bridge_service.dart` — added BLE device fields and connect/disconnect/discovery behavior.

**Deviations**: `connect()` also guards duplicate connecting attempts and catches setup errors around `BluetoothDevice.fromId`. `isConnected` requires the TX characteristic to be discovered, so callers only see connected after service discovery succeeds. Discovery/init errors disconnect the bridge device while preserving `Error` status.

**Verification results**:
```text
$ flutter analyze lib/services/ble_bridge_service.dart
Analyzing ble_bridge_service.dart...
No issues found! (ran in 0.1s)

$ grep -n "requestMtu\|kBridgeServiceUUID\|kBridgeTxCharUUID\|connectionState" lib/services/ble_bridge_service.dart
26:  final ValueNotifier<BridgeConnectionState> connectionStateNotifier =
39:    connectionStateNotifier.notifyListeners();
47:      connectionStateNotifier.value == BridgeConnectionState.connected &&
70:        connectionStateNotifier.value == BridgeConnectionState.connecting ||
75:    connectionStateNotifier.value = BridgeConnectionState.connecting;
99:    connectionStateNotifier.value = BridgeConnectionState.disconnected;
108:        device.connectionState.listen((BluetoothConnectionState state) async {
113:        connectionStateNotifier.value = BridgeConnectionState.disconnected;
124:        await _device?.requestMtu(247);
135:      connectionStateNotifier.value = BridgeConnectionState.connected;
155:    connectionStateNotifier.value = BridgeConnectionState.error;
164:      (element) => element.uuid == Guid.fromString(kBridgeServiceUUID),
172:      (element) => element.uuid == Guid.fromString(kBridgeTxCharUUID),
181:      serviceUuid: Guid.fromString(kBridgeServiceUUID),
182:      characteristicUuid: Guid.fromString(kBridgeTxCharUUID),
191:    connectionStateNotifier.dispose();
```

**Manual test status**: Not run; requires Pixel 10 and physical bridge hardware for Gate A.

**Open questions / risks**: Actual BLE connection behavior still needs Gate A hardware validation.

## BRIDGE-05 — Register BleBridgeService in the Provider tree

**Summary**: Added `BleBridgeService` to `Game` and registered it in the app `MultiProvider`.

**Files changed/created**:
- `lib/models/game.dart` — added the `bleBridgeService` field.
- `lib/main.dart` — registered the bridge service after the existing `Game` provider.

**Deviations**: none.

**Verification results**:
```text
$ grep -n "bleBridgeService" lib/main.dart lib/models/game.dart
lib/main.dart:47:        ChangeNotifierProvider.value(value: game.bleBridgeService),
lib/models/game.dart:40:  BleBridgeService bleBridgeService = BleBridgeService();

$ flutter analyze
Analyzing rcj_scoreboard...
154 issues found. (ran in 1.1s)
```

`flutter analyze` exits non-zero on existing project-wide lint/info/warning output. The new bridge model and bridge service both analyze cleanly with targeted analyzer commands.

**Manual test status**: Not run; provider registration was not tested in a running app.

**Open questions / risks**: Full project analyzer remains noisy from pre-existing issues outside this milestone.

## BRIDGE-06 — Add "BLE Bridge" settings section (MAC + QR + connect)

**Summary**: Added the BLE Bridge settings section between Current Game and MQTT with enable toggle, status, MAC input, QR scan, auto-connect toggle, and connect/disconnect action.

**Files changed/created**:
- `lib/screens/settings.dart` — added bridge settings UI and reused `BarcodeScannerSimple` for MAC QR scanning.

**Deviations**: none.

**Verification results**:
```text
$ grep -n "BLE Bridge\|bleBridgeService\|BarcodeScannerSimple" lib/screens/settings.dart
175:                                .game.bleBridgeService.connectionStateNotifier,
178:                                title: 'BLE Bridge',
180:                                enabled: widget.game.bleBridgeService.isEnabled,
183:                                    widget.game.bleBridgeService.isEnabled =
204:                                        .game.bleBridgeService.bridgeMacAddress,
206:                                      widget.game.bleBridgeService
218:                                              const BarcodeScannerSimple(),
224:                                          widget.game.bleBridgeService
233:                                        .game.bleBridgeService.autoConnect,
236:                                        widget.game.bleBridgeService
250:                                        await widget.game.bleBridgeService
253:                                        await widget.game.bleBridgeService

$ flutter analyze
Analyzing rcj_scoreboard...
154 issues found. (ran in 1.1s)
```

`flutter analyze` exits non-zero on existing project-wide lint/info/warning output. The bridge-specific files analyze cleanly.

**Manual test status**: Not run; requires running the app and Gate A device/hardware checks.

**Open questions / risks**: Gate A must verify Settings UI placement, QR/manual MAC entry, connect/disconnect status transitions, and persisted auto-connect/MAC values.

---

## Milestone A review + Gate A result (Claude Code, 2026-05-31)

**Reviewer**: Claude Code. **Verdict: PASS.** All of BRIDGE-01/02a/02b/05/06
match the specs. Robot/module control path untouched (only `main.dart`,
`game.dart`, `settings.dart` modified; `module.dart`/`home.dart`/`mqtt.dart`/
`ble.dart` clean). `game.dart` holds the `bleBridgeService` field only — no
publish path (correct; that is Milestone B). `publishTopic`/`_processQueue`
left as stubs. Both new files analyze clean; full debug APK builds.

**Gate A run on Pixel 10 (owner)**: PASS. Log showed connect → `requestMtu` →
MTU 256 → `discoverServices` (count 3) → TX char → status Connected. MAC
persisted across app kill/restart. (After a bridge/module reset the link
returned after ~20 s — that is the known firmware supervision-timeout issue
tracked separately in `docs/ai/08`, NOT a bridge-app bug.)

**Post-Gate-A change — phone-side auto-connect REMOVED.** Owner decided launch
auto-connect is undesirable (referees swap phones between games; a freshly
opened app must not auto-grab a bridge another phone is driving). Connect is
now always manual. Removed from `ble_bridge_service.dart`: the `_autoConnect`
field, `autoConnect` getter/setter, and the `bridge_auto_connect` pref load.
Removed from `settings.dart`: the "Auto-connect" `SettingSwitch`. GATT-level
`autoConnect: true` inside `connect()` (link self-recovery) is unchanged.
Spec updated to match: BRIDGE-02a/06 notes, and **BRIDGE-07 cancelled** (it was
the launch auto-connect task). Re-verified: both bridge files + settings.dart
analyze with no new issues; debug APK rebuilds.
