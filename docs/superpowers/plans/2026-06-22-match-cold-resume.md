# Match Cold-Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a cold kill/crash mid-match, relaunching the app detects the in-progress match and offers Resume (restore full state, freeze the clock, robots stay STOPPED) or Discard (fresh start).

**Architecture:** A new `MatchStateStore` serializes one versioned `MatchSnapshot` to a single `SharedPreferences` key with serialized+coalesced writes and a tombstone-generation guard. `Game` marks state dirty off the robot-command hot path and flushes via a ~5 s heartbeat + discrete events. On cold launch `Game._loadPrefs()` loads the snapshot **before** the bootstrap `gameInit()` and, if a match is in progress, fires a draining `onRequestResumeMatch` callback that `home.dart` renders as a non-dismissible dialog.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `provider`, `shared_preferences` (no new packages).

## Global Constraints (verbatim from spec + CLAUDE.md)

- **START/STOP latency invariant:** never add awaits/blocking/queues on `bleSendPlayAll()`/`bleSendStopAll()` or the `playAll`/`stopAll` fan-out. Snapshot build + `jsonEncode` must be OFF those paths.
- **Double-tap safety:** the resume prompt is a non-destructive dialog; Discard requires a deliberate confirm (second dialog), never one stray tap. Resuming play still requires the existing double-tap START.
- **Provider tree:** no new providers. `MatchStateStore` is a plain dependency of `Game`.
- **Portrait-only**, **no new packages**.
- **Never auto-PLAY on cold resume.** Robots stay STOPPED until referee double-taps START.
- **v1 scope:** NO web-binding fields (`loadedFromWeb`/`scoreboardMatchId`) and NO clock-anchor fields (`runClockStartedAtMs`/`runClockStartRemainingTime`). Both deferred. Snapshot `version = 1`.
- **Dart privacy is per-file:** `Module` cannot call `Game._markDirty()`. Use a **public** `Game.markMatchStateDirty()`.

---

## Current-code grounding (dev @ 178c672)

- `game.dart`: `gameInit()` calls `stopTimer()` (`game.dart:117`). Constructor calls `gameInit()` then `unawaited(_loadPrefs())` (`:88-89`). `_loadPrefs()` re-runs `gameInit()` when `!inGame` (`:100-102`). `_tickTimer` decrement branch is `if (_remainingTime > 0)` (`:180`); stage transitions in the `<= 0` block (`:187-221`), secondHalf→fullTime at `:210-215`. `toggleTimer` GAME-OVER branch calls `gameInit()` (`:278`). `toggleAllModules` start uses `playAll(true)` (`:309`). `loadMatchData()` sets `teams[0].name =` directly (`:712`). Team-name edit is in `_TeamSettingsWidgetState` (`home.dart:524-526` → `team.name = value; game.notifyMQTT();`). Dialog callbacks registered in `setupGameCallbacks` (`home.dart:698`), called from `Home.build` (`home.dart:80`).
- `module.dart`: `bleNotify()` sends `bleSendPlay()` when `_state==play` (`:86-89`). `Module.stop()` switches on `_lastState`, default→`debugPrint('Wrong last ModuleState')` no-op (`:431-441`). `applyPresetConfig(String macAddress, String label)` (`:581`) → `setLabel`, `setBleDevice(BluetoothDevice.fromId)`, `bleConnect()` if enabled. `bleInitModule()`→`bleSendCurrentState()`→`bleNotify()` runs on the connected event, **seconds after** restore returns (`:189-195`, `:546`).

---

### Task 1: `MatchStateStore` + snapshot models

**Files:**
- Create: `lib/services/match_state_store.dart`
- Test: `test/match_state_store_test.dart`

**Interfaces produced:**
- `const int kMatchSnapshotVersion = 1;`
- `class TeamSnapshot { final String id; final String name; final int score; ... toJson()/fromJson() }`
- `class ModuleSnapshot { final int moduleId; final bool isEnabled; final String macAddress; final String? customLabel; final String state; final String lastState; final int penaltyTime; ... }`
- `class MatchSnapshot { final int version; final String stage; final int remainingTime; final bool isTimeRunning; final bool inGame; final String timerButtonText; final List<TeamSnapshot> teams; final List<ModuleSnapshot> modules; final int savedAtMs; ... }`
- `class MatchStateStore { MatchStateStore(SharedPreferences prefs); Future<void> save(MatchSnapshot s); MatchSnapshot? load(); Future<void> clear(); }`

**Design:** single serialized op stream + coalescing (latest-wins pending slot) + monotonic `generation`. `clear()` bumps generation, persists a tombstone key, drops pending save. `save` stamps the snapshot with the current generation. `load()` returns null on missing/parse-fail/version-mismatch, and rejects any snapshot whose `generation < tombstone`.

- [ ] **Step 1: Write failing tests** (`test/match_state_store_test.dart`): round-trip save/load (incl. per-module macAddress/customLabel/penaltyTime/state/lastState); `load()` null on missing key, corrupt JSON, version mismatch; `clear()` removes; a stale older `save` completing after a `clear()` does NOT resurrect (generation/tombstone); a `save` after `clear()` IS loadable.
- [ ] **Step 2:** Implement the store + models (see code in repo; mirrors Interfaces above).
- [ ] **Step 3:** `flutter test test/match_state_store_test.dart` (run in CI).
- [ ] **Step 4: Commit** `feat(recovery): add MatchStateStore versioned snapshot with coalesced writes`.

### Task 2: `Module` snapshot + restore

**Files:** Modify `lib/models/module.dart`; tests folded into `test/game_recovery_test.dart` (Task 4).

**Interfaces produced:**
- `ModuleSnapshot toSnapshot()` — captures moduleId, isEnabled, macAddress, customLabel (`_label`), `_state.name`, `_lastState.name`, `_penaltyTime`.
- `void restoreFromSnapshot(ModuleSnapshot s)` — order: (1) apply `isEnabled` (`enable()`/`disable()`); (2) set `_label`, `_penaltyTime`, **normalized** `_state`/`_lastState` (map `play`/`halfTime`/`fullTime`→`stop` for BOTH; preserve `damage`/`stop`); set `_suppressNextRestoreNotify = true`; (3) re-establish device via `applyPresetConfig(s.macAddress, s.customLabel ?? '')` (which reconnects enabled+non-empty-MAC).
- per-module `bool _suppressNextRestoreNotify` consumed (clear-on-consume in `finally`) by the **first** post-restore `bleNotify()`, which then sends at most STOP (+ name/score via `bleSendCurrentState`), never play/damage.

- [ ] **Step 1:** Add `toSnapshot()`/`restoreFromSnapshot()` + a private normalizer + `_suppressNextRestoreNotify` flag; guard `bleNotify()` to consume it.
- [ ] **Step 2: Commit** `feat(recovery): add Module snapshot/restore with restore-notify one-shot`.

### Task 3: `Game` persistence wiring

**Files:** Modify `lib/models/game.dart`; `lib/screens/home.dart` (team-name route).

**Interfaces produced:** `void markMatchStateDirty()`; `Future<void> setTeamName(Team team, String value)`; private `_persistMatchState()`, `_clearMatchState()`, `_buildSnapshot()`, `bool _suppressPersist`, `bool _dirty`, `MatchStateStore? _stateStore`.

- [ ] Hold `MatchStateStore? _stateStore`, construct in `_loadPrefs()` after `_prefs` is set.
- [ ] `markMatchStateDirty()` = `_dirty = true` (trivial, hot-path-safe). `_persistMatchState()` = no-op unless `_dirty && _stateStore != null && !_suppressPersist`; builds snapshot and `_stateStore!.save(...)`, scheduled via `scheduleMicrotask` after fan-outs.
- [ ] Discrete dirty sources: `startTimer`, `stopTimer`, `toggleTimer` SKIP branch, `_tickTimer` stage transitions, `notifyModulesScore`, `toggleTeamOrder`, `loadMatchData`, `setTeamName`; Module mutations call `markMatchStateDirty()`.
- [ ] Heartbeat: in `_tickTimer` decrement branch (`_remainingTime > 0`), when `!_replaying && _remainingTime % 5 == 0` → `markMatchStateDirty(); _persistMatchState()`. One post-catch-up flush after the `resumed` replay loop.
- [ ] `_suppressPersist` scope around bootstrap `gameInit()` in `_loadPrefs()` (wrap so the bootstrap `stopTimer()` can't overwrite the snapshot).
- [ ] `_clearMatchState()` (enqueues tombstone) at: secondHalf→fullTime in `_tickTimer`, GAME-OVER branch of `toggleTimer`, and `discardPendingMatch` (Task 4). NOT in `gameInit()`.
- [ ] **Penalty-preserve fix:** `toggleAllModules` start `playAll(true)` → `playAll(false)`. STOP path unchanged.
- [ ] `setTeamName(team, value)` sets name + `notifyMQTT()` + dirty; route `home.dart:524-526` and `loadMatchData` through it.
- [ ] **Commit** `feat(recovery): wire Game persistence + penalty-preserve fix`.

### Task 4: Cold-resume flow + dialog

**Files:** Modify `lib/models/game.dart`, `lib/screens/home.dart`; Create `test/game_recovery_test.dart`.

**Interfaces produced:** `void Function()? onRequestResumeMatch` (draining setter); `MatchSnapshot? get pendingResume`; `void resumePendingMatch()`; `void discardPendingMatch()`; `bool _resumePrompted`, `MatchSnapshot? _pendingResume`.

- [ ] `_loadPrefs()`: load snapshot into a local **before** the `if (!inGame) gameInit()` bootstrap (suppress-wrapped). If `inGame == true && stage != fullTime`, stash `_pendingResume`, call drain.
- [ ] `onRequestResumeMatch` as a draining setter: on assign, if `_pendingResume != null && !_resumePrompted`, invoke immediately; guard `_resumePrompted` so it fires once.
- [ ] `resumePendingMatch()` under `_suppressPersist = true`: restore stage/scores/inGame/`_remainingTime`=freeze point; restore team order by `id` (reverse live list if `teams[0].id=='B'`, then assign by id); per-module `restoreFromSnapshot`; for firstHalf/secondHalf freeze (`isTimeRunning=false`, `_isGameRunning=false`, `_runClockStartedAt=null`, `timerButtonText='START'`); for halfTime resume the break running (`startTimer()` for halfTime stage, `timerButtonText='SKIP'`); `_broadcastFullState()`; close suppress scope; `markMatchStateDirty(); _persistMatchState()` once; `notifyListeners()`.
- [ ] `discardPendingMatch()` → `gameInit()` + `_clearMatchState()`.
- [ ] `home.dart`: register `game.onRequestResumeMatch` in `setupGameCallbacks` → non-dismissible `AlertDialog` (`barrierDismissible:false` + `PopScope` blocking back). Resume = prominent default → `game.resumePendingMatch()`. Discard opens a second non-dismissible "Discard match?" confirm → `game.discardPendingMatch()`.
- [ ] Write `test/game_recovery_test.dart` covering the spec's Testing section (freeze, normalize-both-states, suppress-notify on late reconnect, restore-by-id, bootstrap-doesn't-wipe, clear-on-fullTime, callback drain, penalty-preserve, half-time continues).
- [ ] **Commit** `feat(recovery): cold-resume flow + resume/discard dialog`.

### Task 5: Verify + PR + review-anvil

- [ ] Push `mrshu/match-recovery`, open PR vs `dev` (CI runs `flutter analyze` + `flutter test`).
- [ ] Run `/review-anvil`.

## Self-review notes

- Spec coverage: all Files-touched rows mapped (store=T1, module=T2, game persist=T3, game cold-resume + home + tests=T4). Web-binding row intentionally omitted (deferred per issue #45).
- The `_markDirty` privacy fix and the dropped anchor/web fields are the only deviations from the 2026-06-20 spec; both documented under Global Constraints.
