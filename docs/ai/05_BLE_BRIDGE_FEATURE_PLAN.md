# BLE Bridge Feature Plan

> ## ✅ STATUS (2026-06-01): ITERATION 1 SHIPPED
> Iteration 1 is **built, tested, and shipped in Play release 0.9.8** (versionCode
> 10, tag `v0.9.8`). Milestones A/B/C complete (Codex built A/B, Claude Code
> reviewed + fixed; BRIDGE-07 auto-connect cancelled). Gates A/B + robot-latency
> check all passed on Pixel 10; verified on Galaxy A52s. As-built details +
> review notes are in `handoff/BRIDGE_REPORT.md`. Source: `ble_bridge_service.dart`,
> `bridge_message.dart`, tests in `test/bridge_message_test.dart`. The firmware
> (WS2812B scoreboard + RS485 forwarder) lives in a **separate FW repo** written by
> the owner. The "CONFIRMED ARCHITECTURE" box below is the design that shipped; the
> proposal sections beneath it are historical.



> ## ⚠️ CONFIRMED ARCHITECTURE (2026-05-30) — READ THIS FIRST
>
> The sections below this box were the original PROPOSAL and used a **binary
> typed protocol**. After design discussion with the project owner, the approach
> changed. Where the older sections conflict with this box, **this box wins.**
> The BRIDGE-0x tasks in `06_CODEX_TASKS.md` are being rewritten to match.
>
> ### What the first device actually is
> The first BLE bridge device is **also a physical scoreboard**: a 7-segment
> display built from WS2812B (addressable RGB) LEDs, placed near the field. It
> shows each team's current score, with the digits colored in that team's app
> color (team A = neon green `0x77FF00`, team B = neon magenta `0xFF00FF`).
>
> ### The device has TWO roles
> 1. **Scoreboard (standalone):** parses the few topics it cares about
>    (`team1_score`, `team2_score`, team colors) and drives its LEDs. Must work
>    **from the phone alone**, with no RPi and no internet.
> 2. **Forwarder (optional uplink):** blindly retransmits **every** received
>    `topic/value` pair out an RS485 cable to a Raspberry Pi. The RPi republishes
>    them verbatim to the MQTT broker for livestream overlay + statistics. The
>    bridge does NOT interpret most topics — it just passes them through.
>
> The RPi/MQTT uplink is an **optional bonus layer**. The scoreboard never depends
> on it.
>
> ### Why BLE bridge in addition to MQTT
> MQTT (existing) is the path when the phone has good internet. For harsh-
> environment fields with poor connectivity, the BLE bridge is the reliable local
> path: phone → BLE → bridge → RS485 → RPi → MQTT. Both interfaces coexist; the
> phone publishes the same data to both.
>
> ### Protocol: "MQTT-over-BLE" (topic/value strings), NOT binary typed messages
> Each BLE message is the **same `(topic, value)` pair the MQTT service already
> builds**, framed as bytes: `topic + 0x00 + value` (UTF-8). Examples mirror the
> existing MQTT topics (see `lib/services/mqtt.dart` `publishCMMessage` calls):
> ```
> team1_score \x00 3
> team2_score \x00 1
> team1_color \x00 77FF00          (RGB hex — color lives ONLY in the app)
> team2_color \x00 FF00FF
> team1_name  \x00 Robots United
> team1_id    \x00 A
> game_stage  \x00 1. Half
> ```
> **Rationale:** the RPi becomes a dumb forwarder (`mqtt.publish(topic, value)`
> verbatim — no per-message-type parsing). New data types (damage time, goal
> timestamps, future stats) need **app changes only**; bridge + RPi keep
> forwarding blindly. All intelligence lives in the phone.
>
> ### Color: sent as explicit RGB, held only in the app
> The phone sends each team's exact color as a value (e.g. `team1_color`→`77FF00`).
> The scoreboard is a dumb display — it renders whatever color it is told. If a
> team is ever recolored, **zero firmware changes**. Confirmed by owner.
>
> ### The two performance disciplines that protect robot play/stop latency
> There is ONE shared BLE radio on Android; the bridge is an extra connection.
> The robot START/STOP path must never be delayed (CLAUDE.md invariant). Phone
> CPU cost of building messages is negligible — the only real risk is **radio
> airtime contention**. Therefore:
>
> 1. **Change-only sends.** Score on goals, state on transitions. Never stream/poll.
> 2. **Timer is SYNC, not per-second.** Do NOT send the time string every second
>    over BLE (that would constantly contend with the module path). Instead the
>    phone sends `timer_start`(+remaining), `timer_stop`/`timer_pause`, and a
>    resync every ~10–30 s. **The bridge counts down locally** and updates its
>    LEDs every second itself. The RPi can likewise regenerate the per-second
>    `time` MQTT topic at the edge, so the livestream still gets smooth 1 Hz time
>    without it ever crossing BLE once per second. (Iteration 2 — see scope below.)
> 3. **Single message in flight** (queue depth-1) + **bridge writes never awaited
>    by `Game`** (already invariants). The bridge physically cannot flood the radio.
> 4. **Verify:** after wiring the bridge, re-run a 10-module play/stop latency
>    test with the bridge connected AND actively sending; confirm no regression.
>
> ### MTU
> Default BLE MTU ≈ 23 bytes (~20 usable). Scores/colors fit. Team names (≤20
> chars) + topic string can overflow → **request a larger MTU (~247) at connect**
> so longer values work without fragmentation. (flutter_blue_plus: pass an mtu on
> connect, or `requestMtu` after.)
>
> ### Iteration scope
> - **Iteration 1 (now):** topic/value framing (future-proof), but only actually
>   send + display **scores + team colors**. Settings section with manual MAC
>   entry AND QR scan (reuse `BarcodeScannerSimple` from module screens).
>   Write-with-response for delivery. Scoreboard parses score/color locally.
> - **Iteration 2 (later):** timer sync protocol, game stage, team names, field
>   number, events (goal/damage/penalty), and the full MQTT-topic mirror so the
>   RPi uplink carries everything the MQTT path does.
>
> ---

## Feature requirements

A second BLE device type — the **BLE Bridge** — must be added to the app. The bridge is distinct from robot modules:

| Property | Robot Module | BLE Bridge |
|---|---|---|
| Purpose | Activate/deactivate robot on field | Forward match data to internet |
| Number | Up to 10 simultaneously | 1 (one bridge per phone) |
| Discovery | BLE scan or QR code (existing flow) | Configured via settings |
| Messages | PLAY, STOP, DAMAGE, HALF-TIME, GAME-OVER | Score, game state, period, time, events |
| Delivery | Fire-and-forget, latency-critical | Reliable, acknowledged, queued |
| Protocol | Simple byte-array commands | Structured JSON or binary with sequence numbers and ACK |
| Priority | HIGHEST — must never be delayed | Lower — runs in background queue |
| Connection count impact | Uses 1–10 of the Android BLE connection slots | Uses 1 additional connection slot |

**Critical safety invariant**: Bridge communication must NEVER block, delay, or affect the robot START/STOP command path.

---

## Current relevant architecture

### What exists today
- `Module` (model): owns BLE connection, handles NUS service, fire-and-forget writes
- `BLEServices` (service): adapter init/enable only, very thin
- `MqttService` (service): reliable async publish with reconnect — this is the best analog for bridge reliability
- `MatchDataService` (service): simple HTTP fetch
- Settings persistence: `SharedPreferences` via direct setters on service classes
- Settings UI: `SettingsSection` widget with `SettingInputField`, `SettingButton`, `SettingSwitch`, `SettingStatus`

### What does NOT exist
- No central BLE connection manager
- No message queue
- No sequence number / ACK infrastructure
- No second BLE device type

---

## Proposed architecture

### New files to create

```
lib/
├── models/
│   └── ble_bridge.dart          # BleBridge model (ChangeNotifier, connection state)
├── services/
│   └── ble_bridge_service.dart  # BleBridgeService (queue, ACK, retry, reconnect)
└── models/
    └── bridge_message.dart      # BridgeMessage data class + protocol constants
```

### Where NOT to touch
- `lib/models/module.dart` — robot module BLE logic stays isolated
- `lib/models/game.dart` — bridge service is injected, not embedded; Game calls bridge publish as a side effect, not blocking call
- `lib/screens/home.dart` — no bridge UI on main control screen

---

## BleBridgeService — design

### Responsibilities
1. Connect/disconnect to a single BLE bridge device (configured by MAC or name)
2. Maintain a message queue of `BridgeMessage` objects
3. Send messages using **write-with-response** (ATT Write Request) — the BLE ATT layer returns a Write Response confirming delivery; no separate application-level ACK needed
4. Retry on write exception or timeout (configurable, default: 3 retries)
5. Reconnect automatically if connection drops
6. Expose connection state and queue depth as `ValueNotifier`s for settings UI
7. Never block the calling code — all operations are async, non-blocking from caller's perspective

### Why write-with-response is sufficient
BLE ATT Write With Response means the remote stack ACKs at the transport layer — when `bleTX.write(bytes)` returns without throwing, delivery to the bridge is guaranteed. A separate RX-channel ACK would only be needed if you required confirmation that the bridge *forwarded* data to the internet, or for protocol-level error codes. For score/state delivery, transport ACK is enough. The RX characteristic is still enabled for notifications (for future bridge→phone messages) but is **not** the ACK channel.

### Class sketch (PROPOSED)

```dart
class BleBridgeService extends ChangeNotifier {
  // Settings (persisted to SharedPreferences)
  String bridgeMacAddress = '';
  bool autoConnect = false;
  bool isEnabled = false;

  // State
  ValueNotifier<BridgeConnectionState> connectionState;
  ValueNotifier<int> queueDepth;
  
  // Internal
  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar;  // write-with-response
  BluetoothCharacteristic? _rxChar;  // notifications (future use, not ACK)
  Queue<BridgeMessage> _queue;
  bool _sendInProgress = false;

  // Public API (fire-and-forget from caller's perspective)
  void publishScore(int scoreA, int scoreB);
  void publishGameState(int stageIndex, int remainingSeconds);
  void publishMatchInfo({String? matchId, String? team1, String? team2});
  void publishEvent(BridgeEventType type);

  // Internal queue processing
  Future<void> _processQueue();
  Future<bool> _sendWithRetry(BridgeMessage msg, {int maxRetries = 3});
  // No _waitForAck needed — write-with-response provides ATT-layer delivery confirmation
}
```

### Message queue behavior (PROPOSED)
- Queue is a FIFO `Queue<BridgeMessage>`
- `_processQueue()` runs a loop: dequeue → `bleTX.write(msg.toBytes())` → on success dequeue next; on exception retry up to `maxRetries`
- Only one message is in-flight at a time
- If bridge disconnects mid-queue: pause, reconnect, resume from the failed message
- Score updates: if a newer score update arrives while an older one is queued and not yet sent, replace the older one (idempotency — latest wins for score/state)
- Events (goal scored, penalty): append, do not replace — order matters

### Message priority (PROPOSED)
Score/state snapshots: deduplicated (latest replaces)
Events (goal, penalty): ordered queue, preserved

---

## Protocol proposal (PROPOSED — not yet confirmed with bridge hardware)

> All assumptions below are PROPOSED. They must be confirmed with the BLE bridge hardware designer.

### BLE service UUIDs
Same Nordic UART Service (NUS) UUIDs as robot modules — confirmed by project owner:
```
Service UUID:    6E400001-B5A3-F393-E0A9-E50E24DCCA9E
TX Char UUID:    6E400002-B5A3-F393-E0A9-E50E24DCCA9E  (phone writes here)
RX Char UUID:    6E400003-B5A3-F393-E0A9-E50E24DCCA9E  (phone listens for ACK here)
```
The bridge is distinguished from robot modules **solely by its MAC address**, which is configured in settings.
No service-UUID-based distinction is needed or used.

### Message frame format (PROPOSED)
```
Byte 0:    Protocol version (0x01)
Byte 1:    Message type (see table)
Byte 2:    Sequence number (0-255, wraps)  — useful for bridge-side logging/dedup; not needed for ACK
Byte 3-N:  Payload (type-dependent, binary)
```

### Message types (PROPOSED)
| Type | ID | Payload | Direction |
|---|---|---|---|
| SCORE_UPDATE | 0x10 | scoreA (1 byte), scoreB (1 byte) | phone → bridge |
| GAME_STATE | 0x11 | stage (1 byte), remainingTime (2 bytes, seconds, big-endian) | phone → bridge |
| MATCH_INFO | 0x12 | matchId (4 bytes), team1_name (up to 20 UTF-8 bytes), 0x00, team2_name (up to 20 UTF-8 bytes) | phone → bridge |
| FULL_SNAPSHOT | 0x13 | All current state (binary, BLE MTU limited) | phone → bridge |
| EVENT | 0x14 | eventType (1 byte), teamId (1 byte), value (1 byte) | phone → bridge |

No ACK/NACK message types needed — delivery confirmation is handled by the BLE ATT Write Response at the transport layer. The RX characteristic is reserved for future bridge→phone notifications (e.g. bridge status, internet connectivity).

### Event types (PROPOSED)
| Event | ID |
|---|---|
| GOAL_SCORED | 0x01 |
| PENALTY_STARTED | 0x02 |
| PENALTY_ENDED | 0x03 |
| HALF_TIME_START | 0x04 |
| GAME_OVER | 0x05 |

### Sequence numbers (PROPOSED)
- 8-bit (0-255), wrapping
- Useful for bridge-side deduplication and logging
- Retransmissions use the same sequence number so the bridge can detect duplicates

### Retry policy (PROPOSED)
- Delivery confirmed by ATT Write Response (write-with-response, default flutter_blue_plus behavior)
- On write exception or timeout: retry up to 3 times
- After 3 failures: log error, skip message, continue with next in queue
- Write timeout: flutter_blue_plus default (~15s) — reduce to ~3s if configurable

### Fragmentation (PROPOSED)
- BLE MTU is typically 23-247 bytes (negotiated during connection)
- For `FULL_SNAPSHOT` with JSON: fragment into MTU-sized chunks with a fragment header
- Or: use GATT Long Write (Write Long Characteristic) — simplest approach
- Decision: defer fragmentation design until actual MTU and payload sizes are known

---

## Connection management (PROPOSED)

### Bridge discovery
- OPTION A: Manual MAC entry in settings (same as robot module today)
- OPTION B: BLE scan filtered by bridge service UUID or device name prefix
- OPTION C: QR code (reuse existing `BarcodeScannerSimple`)
- **Recommendation**: OPTION A for first version (settings-based MAC), OPTION C (QR) as enhancement

### Auto-connect
- If `autoConnect = true` and `bridgeMacAddress` is set: attempt connection on app start and after each disconnect
- Use exponential backoff: 2s, 4s, 8s, max 30s between retries
- Stop retrying after 10 failures; expose error state in settings UI

### Connection state display
New `BridgeConnectionState` enum:
```dart
enum BridgeConnectionState { disabled, disconnected, connecting, connected, error }
```
Exposed via `connectionStateNotifier` (ValueNotifier) — same pattern as MqttService.

---

## Integration with Game class (PROPOSED)

`Game` gains a reference to `BleBridgeService` (constructed in Game constructor, same pattern as `MqttService`):

```dart
BleBridgeService bleBridgeService = BleBridgeService();
```

Bridge publish calls are added as side effects in existing methods — always non-blocking:

```dart
// In notifyModulesScore():
bleBridgeService.publishScore(teams[0].score, teams[1].score);

// In startTimer() timer callback:
bleBridgeService.publishGameState(currentStage, _remainingTime);

// In gameInit():
bleBridgeService.publishMatchInfo(team1: teams[0].name, team2: teams[1].name);
```

**These calls are synchronous from the caller's perspective** — they enqueue a message and return immediately. The actual BLE transmission happens asynchronously on the bridge service's internal queue.

---

## Settings UI integration (PROPOSED)

Add a new `SettingsSection` in `SettingsScreen` between "Current Game" and "MQTT":

```
BLE Bridge
  Status: [Connected / Disconnected / Error: ...]
  Bridge MAC: [input field]
  [Scan QR] [Scan BLE]
  Auto-connect: [switch]
  [Connect / Disconnect button]
  Queue depth: [N messages pending]
```

The bridge section follows the same `SettingStatus`, `SettingInputField`, `SettingSwitch`, `SettingButton` pattern already used for MQTT.

Bridge settings persisted to SharedPreferences:
| Key | Type |
|---|---|
| `bridge_enabled` | bool |
| `bridge_mac_address` | String |
| `bridge_auto_connect` | bool |

---

## BLE connection limit considerations

Android supports approximately 7-10 simultaneous BLE connections (hardware/OS dependent). With 10 robot modules + 1 bridge:
- 11 connections total — may exceed hardware limits on some devices
- Mitigation: document that bridge connection may require reducing robot module count to 9 on constrained hardware
- Future: if connection limit is a hard constraint, investigate BLE connection sharing (not recommended — complex and risky)

---

## Data schema versioning (PROPOSED)

Protocol version byte in every message allows future schema changes:
- Version 0x01: score + game state (first implementation)
- Version 0x02: add match ID, team IDs
- Version 0x03: add events, timestamps

Bridge firmware should respond with NACK (error code 0x01 = VERSION_NOT_SUPPORTED) if it receives an unknown version.

---

## Failure modes and UI

| Failure | User-facing behavior |
|---|---|
| Bridge not configured | Settings shows "Disconnected", no error |
| Bridge unreachable | Settings shows "Error: Connection failed" |
| ACK timeout after retries | Settings shows "Error: Send failed (N msgs)", queue continues |
| Bridge disconnects mid-match | Settings shows "Disconnected", queue pauses, auto-reconnect attempts |
| BLE limit reached (>10 connections) | Bridge connection fails; module connections unaffected |

**No error appears on the Home screen** — bridge errors are only shown in settings. Robot control is never disrupted.

---

## Test strategy

### Unit tests (new)
- `BleBridgeService` queue ordering and deduplication logic (no BLE hardware needed — mock `bleTX`)
- `BridgeMessage` serialization/deserialization
- Sequence number wrapping (0→255→0)
- Retry counter exhaustion

### Integration tests (manual, requires hardware)
- Send score update: verify bridge forwards to internet endpoint
- Disconnect bridge mid-match: verify robot control unaffected
- Reconnect bridge: verify queued messages delivered after reconnect
- Full match simulation: verify all expected messages arrive at bridge

### Regression tests
- After adding bridge: run 10-robot START/STOP latency test — should be unchanged
- After adding bridge settings: verify existing MQTT and match-data settings still save/load correctly

---

## Risks and open questions

1. **Bridge BLE service UUIDs**: Not yet defined. This plan assumes a new service UUID distinct from robot module NUS. OPEN.
2. **Bridge ACK format**: Not yet confirmed with hardware team. This plan proposes a simple 1-byte seq ACK. OPEN.
3. **Fragmentation**: If JSON payloads exceed MTU, fragmentation is needed. Complexity depends on actual payload sizes. OPEN.
4. **10-connection limit**: Real-world limit on competition hardware is unknown. OPEN.
5. **Bridge firmware**: The bridge firmware protocol must be co-designed. This plan proposes the phone-side protocol; bridge side is OPEN.
6. **Timestamp source**: Should the phone timestamp events? Clock drift vs. bridge clock. OPEN.

---

## Acceptance criteria

- [ ] Bridge connects to a configured MAC address from settings
- [ ] Bridge connection state is visible in settings screen
- [ ] Bridge settings (MAC, auto-connect) persist across app restarts
- [ ] Score updates are sent to bridge after every goal (latency: <500ms from goal to bridge receipt)
- [ ] Game state (stage, time) sent at each stage transition
- [ ] Bridge ACK timeout does not block or delay robot START/STOP
- [ ] With 10 robot modules connected, bridge can still connect (or failure is reported clearly)
- [ ] Disconnecting bridge does not affect robot module connections
- [ ] All existing `flutter analyze` checks pass
- [ ] No regression in existing MQTT or match-data settings
