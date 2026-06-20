# Match-state recovery (local) — design

Issue: #4 (Redundant score persistence), parts 1 & 2.
Date: 2026-06-20
Status: draft — incorporates @mato157's warm/cold analysis; full-state restore decided

## Problem

If the referee phone background-kills the app or crashes mid-match, the live
match state is lost. The timer's wall-clock anchor (`_runClockStartedAt`) and
the running score live only in memory.

Two cases, with **opposite** correct clock behavior (per @mato157):

- **Warm resume** — app *backgrounded*, process still alive. BLE links stay up,
  robots keep playing. The clock should *advance* by the elapsed wall-clock
  time. **Already handled** by `didChangeAppLifecycleState` (`paused`→`resumed`
  replays missed ticks from `_runClockStartedAt`). No change here.
- **Cold resume** — process *killed* (OOM / swipe-away / crash). BLE links drop
  and each module stops via firmware supervision (~4 s). No play happened during
  the downtime, so subtracting the dead interval would **steal match time**
  (killed at 5:00, relaunched 4 min later → naive subtraction shows ~1:00). A
  mid-match kill is effectively a **stoppage**: the clock must **freeze where it
  died and give the dead time back**. This is the real target of this work.

Part 3 of the issue (push timestamp+score to a server for cross-device recovery)
is **out of scope**: there is no server API for live mid-match state yet; the
final-result path is handled separately in PR #15. Parked as future work.

## Goal

After a cold kill/crash, relaunching the app detects an in-progress match and
offers the referee a choice:

- **Resume** — restore the **whole match state**: score, stage, team
  order/names, and **full per-module state** (enabled, label, `state`,
  `lastState`, and remaining `penaltyTime`/damage); **freeze the clock at the
  persisted freeze point** (no dead-time subtraction); keep robots **STOPPED**;
  auto-reconnect modules. The referee resumes play manually (double-tap START),
  exactly like returning from any stoppage. The referee-started second-half gate
  is preserved — never auto-PLAY.
- **Discard** — start fresh (`gameInit()`), clearing the snapshot.

## Non-goals / invariants preserved

- **START/STOP latency:** persistence touches only timer/score/state
  bookkeeping. `bleSendPlayAll()`/`bleSendStopAll()` and the `playAll`/`stopAll`
  fan-out paths are untouched — no awaits/blocking/synchronization added to robot
  command paths. Writes are cheap synchronous `SharedPreferences` setters off the
  hot path; the ~5 s heartbeat is a low-frequency timer callback, not on any
  command path. **Cold resume never auto-PLAYs** — robots stay stopped until the
  referee acts.
- **Double-tap safety:** the resume prompt is a non-destructive dialog. Discard
  maps to the existing `gameInit()` reset and is an explicit dialog choice, not a
  new tap gesture on the main UI. Resuming play still requires the existing
  double-tap START.
- **Provider tree:** no new providers. `MatchStateStore` is a plain dependency of
  `Game`, constructed like the other services.
- **Portrait-only:** unchanged. No new packages (uses existing
  `shared_preferences`).

## Architecture

### New: `lib/services/match_state_store.dart`

A thin wrapper over `SharedPreferences` that serializes one **versioned** match
snapshot to a single JSON string under key `match_state_snapshot`.

```dart
class MatchSnapshot {
  final int version;             // schema version; mismatched version => ignored
  final String stage;            // MatchStage.name
  final int remainingTime;       // the freeze point (heartbeat-maintained)
  final bool isTimeRunning;      // whether the clock was running at save time
  final bool inGame;
  final String timerButtonText;
  final List<TeamSnapshot> teams;     // order preserved (captures team swap)
  final List<ModuleSnapshot> modules; // per-module recovery (penalties etc.)
  final int savedAtMs;           // epoch ms, for staleness display
}

class TeamSnapshot { final String id; final String name; final int score; }

class ModuleSnapshot {
  final int moduleId;            // stable index 0..9
  final bool isEnabled;
  final String? customLabel;     // null if default (_label)
  final String state;            // ModuleState.name (_state)
  final String lastState;        // ModuleState.name (_lastState) — drives transitions
  final int penaltyTime;         // remaining penalty/damage seconds
}

class MatchStateStore {
  Future<void> save(MatchSnapshot s);   // jsonEncode -> setString
  MatchSnapshot? load();                 // null on absent / parse-fail / version mismatch
  Future<void> clear();
}
```

- `load()` returns `null` on a missing, unparseable, or version-mismatched value
  (defensive: a corrupt/old snapshot must never crash startup — treated as "no
  match").
- The store reuses the `SharedPreferences` instance `Game` already loads in
  `_loadPrefs`.

> **Note on the freeze point:** `remainingTime` is maintained both on discrete
> events *and* by a ~5 s heartbeat while the clock runs, because the last
> goal/penalty event can be stale. Worst-case recovery error ≈ 5 s heartbeat +
> ~4 s firmware stop latency, and it always errs toward *returning* time, never
> removing it.

### Changes in `lib/models/game.dart`

1. **Hold the store:** add `MatchStateStore? _stateStore;`, constructed in
   `_loadPrefs()` once `_prefs` is available.

2. **`_persistMatchState()`** — single private method that builds a
   `MatchSnapshot` from current fields and calls `_stateStore?.save(...)`.
   Called from the mutation chokepoints (discrete events):
   - `startTimer()` / `stopTimer()` / `toggleTimer()` SKIP branch
   - `_tickTimer()` on **stage transitions**
   - `notifyModulesScore()` (every score change passes through here)
   - `toggleTeamOrder()` (swapped order/names)
   - `loadMatch()` (applied team names)
   - penalty/module-state changes that matter for recovery (called from the
     module damage/penalty path — exact hook identified during implementation)
   - Guarded: no-op until `_stateStore` exists.

3. **Heartbeat:** while `isTimeRunning`, persist the current `remainingTime`
   every ~5 s. Implemented by piggy-backing on the existing 1 Hz `_tickTimer`
   (persist when `_remainingTime % 5 == 0`) rather than adding a second `Timer`
   — no extra timer object, naturally stops when the clock stops, and skipped
   during `_replaying` catch-up bursts.

4. **Clear on reset:** `gameInit()` calls `_stateStore?.clear()` (covers fresh
   match and GAME OVER via `toggleTimer`'s `gameInit()`).

5. **Cold-resume flow** in `_loadPrefs()` (this runs only on a fresh process, so
   it *is* the cold path — warm resume goes through the lifecycle observer, not
   the constructor):
   - After loading params, call `_stateStore!.load()`.
   - If a snapshot exists with `inGame == true` and stage != `fullTime`, do NOT
     mutate game state yet. Stash it in `_pendingResume` and fire a new callback
     `onRequestResumeMatch` (mirrors `onRequestSwitchTeamOrderDialog`).
   - **Resume** → `resumePendingMatch()`:
     - Restore `currentStage`, scores, team order/names, `inGame`, and
       **`_remainingTime` = the snapshot's freeze point** (no wall-clock
       subtraction).
     - Restore **full per-module state** via a new
       `Module.restoreFromSnapshot(ModuleSnapshot)` that sets `_state`,
       `_lastState`, `_penaltyTime`, `_label`, and enabled/disabled — the model
       fields are private, so the setter lives on `Module` rather than poking
       fields from `Game`.
     - Set the clock **frozen**: `isTimeRunning = false`, `_isGameRunning =
       false`, `_runClockStartedAt = null`, `timerButtonText = 'START'` so the
       referee restarts play manually (or `'SKIP'` if stage is `halfTime`).
     - Robots are **not** played; modules auto-reconnect via the existing
       autoConnect. On reconnect each module pushes its restored damage/penalty
       and score (the existing `bleSendDamage`/`bleSendScore` paths), so a robot
       that comes back mid-penalty resumes its damage countdown.
     - `_broadcastFullState()` + `notifyListeners()`.
   - **Discard** → `discardPendingMatch()` → `gameInit()` (clears snapshot).

6. **No catch-up on cold resume.** The existing `didChangeAppLifecycleState`
   catch-up loop is unchanged and used **only** for warm resume. Cold resume
   deliberately does not advance the clock.

### UI: `lib/screens/home.dart`

- Register `game.onRequestResumeMatch = () => showDialog(...)` alongside the
  existing `onRequestSwitchTeamOrderDialog` registration.
- `AlertDialog`: title *"Resume match in progress?"*, body summarizing
  `"<teamA> <scoreA> – <scoreB> <teamB>, <stage>, saved <n> min ago"`, actions
  **Resume** → `game.resumePendingMatch()`, **Discard** →
  `game.discardPendingMatch()`.

## Data flow

```
score tap        -> team.addScore -> notifyModulesScore -> _persistMatchState -> save
timer start/stop -> startTimer/stopTimer -> _persistMatchState -> save
stage change     -> _tickTimer transition -> _persistMatchState -> save
running clock     -> _tickTimer (every ~5s) -> heartbeat save (freeze point)
warm resume      -> didChangeAppLifecycleState(resumed) -> catch-up (UNCHANGED)
cold relaunch    -> _loadPrefs -> store.load -> (inGame) onRequestResumeMatch
                    -> Resume  -> restore + FREEZE clock (no subtraction), robots STOPPED
                    -> Discard -> gameInit -> store.clear
```

## Error handling

- Corrupt / absent / version-mismatched snapshot → `load()` returns `null` →
  normal fresh start.
- `savedAt` shown in the dialog so the referee can judge staleness; freeze-and-
  give-back means an old snapshot never produces a wrong (too-low) clock.
- All `save` calls are best-effort; a failed write is logged and never throws
  into the caller.

## Testing

Unit tests (no Flutter toolchain on the dev box; rely on CI Quality Gate):

- `match_state_store_test.dart`: round-trip save/load; `load()` null on missing
  key, on corrupted JSON, and on version mismatch; `clear()` removes it.
- `game_recovery_test.dart`:
  - score change persists a snapshot with the right scores;
  - heartbeat updates `remainingTime` while the clock runs;
  - `startTimer`/`stopTimer` update the snapshot; `gameInit` clears it;
  - a snapshot with `inGame==true` (stage != fullTime) triggers
    `onRequestResumeMatch`; a `fullTime` snapshot does not;
  - **`resumePendingMatch` freezes the clock at the persisted freeze point** —
    `_remainingTime` equals the snapshot value regardless of how long ago
    `savedAt` was (no dead-time subtraction); `isTimeRunning == false`;
    scores/stage/team-order restored; second half not auto-started; robots not
    played.
  - **full per-module restore** — a snapshot with a module in `damage` state and
    `penaltyTime > 0`, plus a custom label and enabled flag, round-trips through
    `restoreFromSnapshot` to the exact `state`/`lastState`/`penaltyTime`/label.

## Files touched

| Path | Change |
|---|---|
| `lib/services/match_state_store.dart` | **new** — versioned snapshot model + SharedPreferences wrapper |
| `lib/models/game.dart` | store wiring, `_persistMatchState`, heartbeat, cold-resume flow |
| `lib/models/module.dart` | `toSnapshot()` / `restoreFromSnapshot()` for full per-module state |
| `lib/screens/home.dart` | register `onRequestResumeMatch`, resume/discard dialog |
| `test/match_state_store_test.dart` | **new** |
| `test/game_recovery_test.dart` | **new** |

## Scope decision

**Full-state restore, including penalties** (decided 2026-06-20). v1 restores the
entire match state — score, clock freeze point, stage, team order/names, and full
per-module state (enabled, label, `state`/`lastState`, `penaltyTime`). Penalties
are *not* reset on cold resume.

## Coordination notes

- **@f-wllr's fork** (issue #4 comment, 2026-06-08) claimed part 1 "already
   fixed" — this almost certainly refers to the **warm/background catch-up**,
   which already landed on `dev` independently (Copilot `946fdfe`, MaTo
   `0f6d9fa`/`32a3cf0`). The real open work — **cold resume + full snapshot** —
   is not on `dev` and is not what that fork described, so overlap risk is low.
- **@mato157 (MaTo)** is the active maintainer of the timer code on `dev`; this
   spec adopts their warm/cold + freeze-and-give-back analysis. Worth a short
   reply on #4 confirming full-state restore before/while implementing.

## Branch / PR

Branch `mrshu/match-recovery` off `dev`; one focused PR for parts 1 & 2 of #4.
Logging (#16) is a separate follow-up.
