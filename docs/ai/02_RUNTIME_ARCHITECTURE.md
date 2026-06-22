# Runtime Architecture

## State management overview

All state lives in a tree of `ChangeNotifier` objects registered in `MultiProvider` at app start:
```
MultiProvider
  ├── Game (root state)
  ├── Team (teams[0])
  ├── Team (teams[1])
  ├── Module × 5 (teams[0].modules)
  └── Module × 5 (teams[1].modules)
```

`Consumer<Game>`, `Consumer<Team>`, and `Consumer<Module>` widgets rebuild selectively. Widgets call `notifyListeners()` to trigger UI updates.

No dependency injection framework. `Game` directly instantiates `MqttService` and `MatchDataService` in its constructor. `BLEServices` is instantiated per-screen in `ModuleSettingsScreen`.

## UI flow

```
App start
  → main() creates Game
  → Game constructor creates 2 Teams × 5 Modules + MqttService + MatchDataService
  → MultiProvider wraps MaterialApp
  → Home screen shown

Home screen (portrait, double-tap to prevent accidents)
  → AppBar → Settings icon → navigates to SettingsScreen
  → Team container (long-press → TeamSettingsWidget bottom sheet)
  → Module buttons (double-tap → play/stop/penalty; long-press → ModuleSettingsScreen)
  → Timer area (double-tap → toggleTimer)
  → "START/STOP ALL ROBOTS" button (double-tap → toggleAllModules)

ModuleSettingsScreen (per robot)
  → Shows BLE status
  → MAC address text field (masked)
  → Connect/Disconnect button (calls module.setBleDevice + module.bleConnect)
  → Scan BLE button (calls FlutterBluePlus.startScan)
  → Scan QR button → navigates to BarcodeScannerSimple → returns MAC string

SettingsScreen
  → Match Data section (URL, match ID, Load button)
  → Current Game section (switch order, reset, disconnect all)
  → MQTT section (server, port, user, pass, secure, field, connect/disconnect)
  → Game section (duration, halftime duration — locked during game)
  → Player section (number of players, penalty time — locked during game)
```

## BLE architecture

### Connection model
Each `Module` owns its own BLE connection. There is no central BLE manager. Up to 10 modules can be connected simultaneously (limited by Android OS BLE connection count).

BLE connection lifecycle per module:
```
1. User enters MAC (typed or via scan/QR) in ModuleSettingsScreen
2. module.setBleDevice(BluetoothDevice.fromId(mac)) — creates device from MAC
3. module.bleConnect()
   ├── 100ms delay (comment: fixes >5 simultaneous connections)
   ├── _registerBleSubscriber(device) — subscribes to connectionState stream
   └── device.connect(autoConnect:true, mtu:null)
4. On connected event:
   ├── _isConnected = true
   └── bleInitModule()
       ├── bleCheckServicesAndGetCharacteristics() — discovers NUS service, sets bleTX/bleRX
       ├── enableRXNotifications() — listens for incoming data on RX characteristic
       └── bleSendCurrentState() → bleSendName() + bleSendScore() + bleNotify()
5. On disconnected event:
   ├── _isConnected = false
   ├── bleStatus = _connectIntent ? 'Connecting...' : 'Disconnected'
   └── auto-reconnect (see "Auto-reconnect policy" below)
```

### Auto-reconnect policy (match-aware) — issues #34/#38

When a connection drops *while we still intend to be connected* (`_connectIntent`
is true — i.e. the user did not disconnect), the module schedules a reconnect
after 2 s. The number of attempts is bounded **by match state, not a fixed
count**:

- **During a match** (`_game.currentStage` is `firstHalf` / `halfTime` /
  `secondHalf`, and pre-match setup): reconnection is **unbounded** — it retries
  forever until the module returns. This is essential: a penalised robot is
  powered off for ~1 min and the halftime break is ~5 min, and the module must
  reconnect the instant it comes back with no referee action. A module that is
  genuinely dead mid-match is dismissed via the manual **Cancel** button, not by
  auto-giving-up.
- **After the match is over** (`MatchStage.fullTime`): the `_maxReconnectAttempts`
  (5) cap applies. `_reconnectAttempts` is only incremented post-match, so
  full-time starts with a fresh budget; once spent, the module calls
  `bleDisconnect()` (tears down the OS autoConnect, clears intent, shows
  "Disconnected"). This stops modules powered down for good after the match from
  looping forever.

> History: PR #42 (issue #38) first added a *fixed* 5-attempt cap that applied
> always. That broke live use (it abandoned penalised/halftime modules after
> ~10 s), so the cap was made match-aware — unbounded in-match, bounded only at
> full time. The robot-stop safety guarantee does **not** depend on this; it
> lives in the module firmware's BLE supervision timeout (link-layer).

Implementation: `Module._registerBleSubscriber` in `lib/models/module.dart`.

### START/STOP command flow (LATENCY-CRITICAL)

**Play all modules (game start or post-penalty):**
```
User double-taps "START ALL ROBOTS" or timer START button
  → game.toggleAllModules() or game.toggleTimer()
  → game.playAll(removeDamage)
  → for each enabled module (NOT awaited):
      module.playAll() [async, NOT awaited]
        → state = play
        → for i in 0..2: bleSendPlayAll() + 100ms delay [NOT awaited]
        → bleSendPlay() [confirmed, NOT awaited]
```

**Stop all modules:**
```
User double-taps "STOP ALL ROBOTS" or timer STOP button
  → game.stopAll(removePenalty)
  → for each enabled module (NOT awaited):
      module.stopAll() [async, NOT awaited]
        → for i in 0..2: bleSendStopAll() + 100ms delay [NOT awaited]
```

**Key property**: All module send sequences are launched as concurrent unawaited Futures. BLE writes to different devices execute in parallel at the OS level. This is the designed approach for near-simultaneous delivery.

**Write semantics**:
- `bleSendPlayAll()` / `bleSendStopAll()`: `write(..., timeout:0)` — write-without-response (no ACK)
- `bleSendPlay()` / `bleSendStop()`: `write(...)` default timeout — write-with-response (ACK from BLE stack, not from robot)

### Incoming BLE data
Only one incoming message is handled:
- `bleMsgAskForPenalty` (ID=10) → `_askForPenalty()` → `penalty(game.penaltyTime)` if game is running and module is playing

### BLE scan
`FlutterBluePlus.startScan(withKeywords: ['RCJ', 'soccer', 'module'], timeout: 3s)`
Results collected in `ModuleSettingsScreen.devices` list.

### QR code flow
`BarcodeScannerSimple` uses `mobile_scanner` to read QR codes. Validates that scanned value matches MAC address regex (`^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$`). Returns MAC string via `Navigator.pop`. Caller sets `_controller.text = result` — user still presses Connect manually.

## Match timer and score flow

```
Timer tick (every 1 second, via Timer.periodic):
  _remainingTime--
  notifyAllModulesTimer() → for each damage-state module:
      module.notifyTimer()
        → _penaltyTime--
        → if penaltyTime == 0: module.play() [re-sends BLE PLAY]
        → if penaltyTime % 10 == 0: bleSendDamage(penaltyTime) [update timer on robot]
  mqttService.publishTime(_remainingTime)
  if _remainingTime <= 0: stage transition

Stage transitions:
  firstHalf → halfTime: halfTimeAll(), startTimer() (half-time timer), dialog shown
  halfTime → secondHalf: stopAll(true, force:true), reset timer
  secondHalf → fullTime: stopAll(true), gameOverAll()
```

**Score flow:**
```
User double-taps team container
  → team.addScore(1)
  → game.stopAll(true) [stops all robots]
  → game.notifyModulesScore()
      → for each connected module: module.bleSendScore() [200ms delay then BLE write]
      → mqttService.publishScore(teams)
```

Score adjustment (long-press → bottom sheet → +/- buttons):
```
  → team.addScore(±1)
  → game.notifyModulesScore()
```

## MQTT publishing flow

`MqttService.publishCMMessage(message, topic)` builds full topic as:
`rcj_soccer/[field_N]/[subtopic]` (or `rcj_soccer/[subtopic]` if no field set)

Published events:
| Trigger | Topics published |
|---|---|
| gameInit | game_stage, time, team1_name, team2_name, team1_id, team2_id, team1_score, team2_score |
| Timer tick | time |
| Stage transition | game_stage, time |
| Score change | team1_score, team2_score |
| Match data load | team1_name, team2_name, team1_id, team2_id |
| Team order toggle | team1_name, team2_name, team1_id, team2_id, team1_score, team2_score |

MQTT publish is fire-and-forget. If not connected, messages are silently dropped. No queue.

MQTT reconnect: on unintentional disconnect, waits 5 seconds then loops calling `connect()` until success.

## Settings architecture

Settings are stored in `SharedPreferences` and directly mutated via setters on `MqttService` and `MatchDataService`. No separate settings model. Changes are persisted immediately on setter call.

Game parameters (`periodTime`, `halfTimeDuration`, `numberOfPLayers`, `penaltyTime`) are stored only in the `Game` object in memory — not persisted to disk. They reset to defaults when the app restarts.

## UI safety interactions

All critical actions on the home screen use `GestureDetector.onDoubleTap`:
- Timer toggle: `GestureDetector(onDoubleTap: game.toggleTimer)`
- All modules toggle: `GestureDetector(onDoubleTap: game.toggleAllModules)`
- Score a goal: `GestureDetector(onDoubleTap: team.addScore(1) + game.stopAll)`
- Individual module play/stop/penalty: `GestureDetector(onDoubleTap: ...)`

Long-press opens settings:
- Team long-press → bottom sheet with name edit + score adjust
- Module long-press → `ModuleSettingsScreen`

Back button: intercepted by `PopScope(canPop: false)` → exit confirmation dialog.

## Critical invariants

1. Robot START/STOP sends are non-awaited unawaited async calls — they fire in parallel.
2. `timeout:0` on play/stop writes means write-without-response — no ACK, lowest latency.
3. The 100ms delay between 3 retries is within each module's own send loop, not between modules.
4. `Game.playAll()` and `Game.stopAll()` iterate synchronously but do NOT await module calls.
5. MQTT and score notifications must never be inserted into the robot command path.
6. `bleSendScore()` has an intentional 200ms delay (line 228 of module.dart) — this is by design to avoid BLE write conflicts during reconnect initialization.
7. Half-time and game-over commands have a 1-second delay (`Future.delayed(1s)`) after the stop commands — this is intentional to ensure stop is delivered before the special command.
