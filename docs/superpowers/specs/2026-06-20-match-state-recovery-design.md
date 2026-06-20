# Match-state recovery (local) — design

Issue: #4 (Redundant score persistence), parts 1 & 2.
Date: 2026-06-20
Status: draft — @mato157's warm/cold analysis + full-state restore + codex & review-anvil R1–R3 hardening (converged)

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
  command paths. The `save` call is a small `jsonEncode` plus an **async**
  `SharedPreferences.setString` (it returns a `Future`; the platform write is not
  synchronous), launched off the hot path; the ~5 s heartbeat is a low-frequency
  timer callback, not on any command path. **Cold resume never auto-PLAYs** —
  robots stay stopped until the referee acts.
- **Save durability (be honest that writes are async):** because `setString` is
  async and saves are best-effort, a kill in the brief window after a score/stop/
  stage/penalty event but before the write lands loses *that* event. Mitigations:
  (1) the ~5 s heartbeat bounds clock loss regardless; (2) **serialize and
  coalesce** writes in `MatchStateStore` (a single in-flight write + a “latest
  pending” snapshot) so a slow older write can never overwrite a newer one; (3)
  for non-robot, non-hot-path events it is acceptable to `await` the save where
  convenient. We do **not** await on any robot-command path. Worst-case residual
  loss is one sub-5 s-old event — consistent with the freeze-and-give-back
  philosophy (err toward losing the least, never stealing match time).
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
  // Clock anchor — set when the clock is running (esp. on the paused snapshot);
  // null when stopped. Needed for the backgrounded-then-killed policy (item 7);
  // the freeze-default ignores them, but the schema MUST carry them or policy
  // (b)/(c) become impossible later.
  final int? runClockStartedAtMs;
  final int? runClockStartRemainingTime;
}

class TeamSnapshot { final String id; final String name; final int score; }

class ModuleSnapshot {
  final int moduleId;            // stable index 0..9
  final bool isEnabled;
  final String macAddress;       // REQUIRED for auto-reconnect after a cold kill
  final String? customLabel;     // null if default (_label)
  final String state;            // ModuleState.name (_state)
  final String lastState;        // ModuleState.name (_lastState) — drives transitions
  final int penaltyTime;         // remaining penalty/damage seconds
}

class MatchStateStore {
  Future<void> save(MatchSnapshot s);   // enqueue: jsonEncode -> setString
  MatchSnapshot? load();                 // null on absent / parse-fail / version mismatch
  Future<void> clear();                  // enqueue a tombstone in the SAME stream
}
```

- `load()` returns `null` on a missing, unparseable, or version-mismatched value
  (defensive: a corrupt/old snapshot must never crash startup — treated as "no
  match").
- **`save` and `clear` share one serialized op stream with a generation guard.**
  `save` is async (`setString` returns a `Future`); without ordering, a slow
  older `save` can land after a newer `save` — or after a `clear` — and resurrect
  a discarded/finished match. So the store keeps a single in-flight op + a
  "latest pending" slot (coalescing) and a monotonic `generation` counter:
  `clear()` is enqueued in the same stream (not a side API), bumps the
  generation, and drops any pending `save`; a `save` completion whose generation
  is stale is discarded.
  - **Honest scope:** this guarantees *eventual ordering while the process is
    alive* — it can NOT undo a `setString` already in flight to disk before the
    `clear` lands, so a kill in that narrow window could still leave a stale
    snapshot. For the destructive UI paths (Discard / GAME OVER) **await the
    `clear` completion** where feasible (these are not robot-command paths, so an
    await is fine). For crash-window safety, persist a **separate tombstone
    generation key**: `clear()` writes/bumps it, and `load()` **rejects any
    snapshot whose generation predates the tombstone** — so even a late stale
    save that beat the snapshot key to disk is ignored on next launch. Do not
    claim crash-proof durability from the in-memory guard alone.
- The store reuses the `SharedPreferences` instance `Game` already loads in
  `_loadPrefs`.
- `ModuleSnapshot`'s `moduleId`/`macAddress`/`customLabel` overlap
  `preset_service.dart`'s `ModuleConfig`. **Keep `ModuleSnapshot` self-contained
  (flat fields), not an embedded `ModuleConfig`.** `ModuleConfig.label` is a
  non-null `String` with "empty == default name" semantics while
  `customLabel` is nullable, so embedding needs `?? ''` glue anyway and would
  couple the recovery schema's stored shape to the preset schema (a preset change
  would silently rev the snapshot version). The minor duplication of two strings
  + an int is the cheaper trade; share a tiny serializer helper only if it stays
  decoupled.

> **Note on the freeze point:** `remainingTime` is maintained both on discrete
> events *and* by a ~5 s heartbeat while the clock runs, because the last
> goal/penalty event can be stale. Worst-case recovery error ≈ 5 s heartbeat +
> ~4 s firmware stop latency, and it always errs toward *returning* time, never
> removing it.

### Changes in `lib/models/game.dart`

1. **Hold the store:** add `MatchStateStore? _stateStore;`, constructed in
   `_loadPrefs()` once `_prefs` is available.

2. **`_markDirty()` / `_persistMatchState()` — persistence is OFF the robot
   command path (critical for the START/STOP latency invariant).** Several
   chokepoints (`startTimer`/`stopTimer`, and the module fan-outs `playAll`/
   `playOrDamageAll`/`stopAll`) sit immediately before/around the fire-and-forget
   `bleSendPlayAll()`/`bleSendStopAll()` sends. Building a `MatchSnapshot` and
   `jsonEncode`-ing it there would add synchronous work *before* those sends —
   forbidden. So splitting:
   - On any recoverable change, call `_markDirty()` — a trivial `bool` set, no
     snapshot construction, no JSON. Safe to call from anywhere, including the
     command paths.
   - A coalesced flush (`_persistMatchState()` → build snapshot →
     `_stateStore?.save`) runs **after** the fan-out is launched — scheduled via
     `scheduleMicrotask`/post-frame, or piggy-backed on the next heartbeat tick.
     It is a no-op unless `_dirty`, and a no-op until `_stateStore` exists / while
     `_suppressPersist == true` (item 4a). **Never** put snapshot build or
     `jsonEncode` on the `bleSendPlayAll`/`bleSendStopAll` path.
   - Discrete `_markDirty()` sources: `startTimer`, `stopTimer`, and the SKIP
     (halfTime) branch of `toggleTimer`; `_tickTimer` stage transitions;
     `notifyModulesScore` (every score change);
     `toggleTeamOrder`; `loadMatchData()` (**real method name**, `game.dart:683`,
     not `loadMatch`); manual team-name edits via a new `Game.setTeamName(team,
     value)` (replacing direct `team.name =` + `notifyMQTT()` in
     `TeamSettingsWidget`, `home.dart:464`, which otherwise bypasses every
     chokepoint).
   - **Module mutations** mark dirty via the existing `_game` back-reference
     (`Module` → `Game._markDirty()`) — but only a flag set, never a save, so it
     stays off the fan-out latency path. Given the ~5 s heartbeat already bounds
     loss, the per-mutation marks mainly tighten penalty/label freshness; keep
     the marker dead-simple so it cannot creep into `bleSendPlayAll/StopAll`.

3. **Heartbeat:** while `isTimeRunning`, flush at most every ~5 s by piggy-backing
   on the 1 Hz `_tickTimer` (flush when `_remainingTime % 5 == 0`) — no second
   `Timer`, stops with the clock, skipped during `_replaying` bursts. **Place the
   flush only in the normal decrement branch** (inside `if (_remainingTime > 0)`,
   *before* any stage-transition reset to `halfTimeDuration`/`periodTime`),
   otherwise the `% 5` test samples the freshly-reset value at a boundary and
   persists a misleading freeze point. After a warm-resume catch-up
   (`didChangeAppLifecycleState(resumed)`) finishes replaying, do **one** flush of
   the post-catch-up state — `_replaying` suppressed the per-tick flushes, so a
   crash right after resume would otherwise persist the stale pre-background
   freeze point and over-credit time on the next cold resume.

4a. **Suppress persistence during bootstrap/reset (critical).** `gameInit()`
   calls `stopTimer()` (`game.dart:115`), and `stopTimer()` is now a persistence
   chokepoint (item 2). So the bootstrap `gameInit()` in `_loadPrefs()` would
   fire `stopTimer()` → `_persistMatchState()` and **overwrite the on-disk
   snapshot with the default `inGame=false` state** — re-introducing the
   snapshot-wipe bug through an indirect path (the in-memory `_pendingResume` is
   already loaded so the prompt still appears, but a second kill before the
   referee chooses would lose the match). Wrap the bootstrap init (and any
   internal reset that is not a real referee action) in a
   `_suppressPersist = true … finally _suppressPersist = false` scope, or pass
   `gameInit(persist: false)`. `_persistMatchState()` is a no-op while
   suppressed. Real referee stop/reset actions persist normally.

4. **Clear on reset — NOT inside `gameInit()`.** `gameInit()` must *not* clear
   the snapshot. `_loadPrefs()` already calls `gameInit()` on every cold launch
   (it runs `gameInit()` whenever `inGame == false`, which is always true at
   startup); clearing there would erase the persisted match before the resume
   path ever reads it, so the prompt could never appear. Instead, clearing is
   explicit and happens only at genuine end-of-match / fresh-start points. These
   are **two distinct call sites** — do not conflate them (item 2 makes
   `_tickTimer` stage transitions a *persist* point, so without this the
   secondHalf→fullTime transition would save a stale `fullTime` snapshot instead
   of clearing):
   - `discardPendingMatch()` (referee chose Discard).
   - the **secondHalf→fullTime transition inside `_tickTimer`** (`game.dart:208-213`)
     — match just ended; clear here instead of persisting.
   - the **GAME OVER / REPEAT branch of `toggleTimer`** (`game.dart:276`, runs
     *after* fullTime) — clear when starting the brand-new match.
   These call a dedicated `_clearMatchState()` (which enqueues the store
   tombstone, item store-section) rather than relying on `gameInit()`.

5. **Cold-resume flow** in `_loadPrefs()` (this runs only on a fresh process, so
   it *is* the cold path — warm resume goes through the lifecycle observer, not
   the constructor):
   - **Load the snapshot first**, *before* the existing `if (!inGame)
     gameInit()` bootstrap reset, so the bootstrap can't clobber it. Capture
     `_stateStore!.load()` into a local, then let `gameInit()` run to set
     defaults (it no longer clears the snapshot — see item 4).
   - If the loaded snapshot has `inGame == true` and stage != `fullTime`, do NOT
     mutate game state yet. Stash it in `_pendingResume` and fire a new callback
     `onRequestResumeMatch` (mirrors `onRequestSwitchTeamOrderDialog`).
   - **Don't lose the prompt to a registration race (critical).** `main.dart`
     constructs `Game()` before `runApp`, and `_loadPrefs()` is async; with
     cached prefs (or in tests) `SharedPreferences.getInstance()` can resolve
     *before* `Home.build` registers `onRequestResumeMatch`, so firing it
     directly would no-op against a null callback and the snapshot would be
     silently ignored. Make `onRequestResumeMatch` a **setter that drains**: on
     assignment, if `_pendingResume != null` and the prompt hasn't been shown,
     invoke the callback immediately. So whichever happens last —
     snapshot-stashed or callback-registered — triggers the prompt. Guard with a
     `_resumePrompted` flag so it fires exactly once.
   - If there is no usable snapshot, the bootstrap `gameInit()` defaults stand
     and no prompt fires.
   - **Resume** → `resumePendingMatch()`. The multi-step restore runs under
     `_suppressPersist = true` so it can't write a dozen partial snapshots; the
     single committed save is issued **after** the scope closes (a flush while
     suppressed is a no-op, so persisting "once at the end" must mean *after*
     `_suppressPersist` is reset — not inside the `finally`). The async reconnects
     that complete later mutate only **connection status**, which is **not** a
     recoverable/persisted field, so they do not each trigger a save (state this
     explicitly so the module dirty-mark contract isn't read as "persist on every
     reconnect"). Steps:
     - Restore `currentStage`, scores, `inGame`, and **`_remainingTime` = the
       snapshot's freeze point** (no wall-clock subtraction).
     - **Restore team order by id, not by index (correctness).** `Game()` always
       builds `teams` as `[A, B]`; a swapped match was reordered by
       `toggleTeamOrder()` reversing the list, and `_teamColorHex` + the UI color
       bars are keyed on `team.id`. If the snapshot's `teams[0].id == 'B'`,
       reverse the live `teams` list (reuse `setTeamToDefaultOrder`/
       `toggleTeamOrder` logic) **before** assigning names/scores, then assign by
       matching `team.id` — not positionally — so scores/names land on the
       correct physical side.
     - Restore **full per-module state** via a new
       `Module.restoreFromSnapshot(ModuleSnapshot)` that sets `_label`,
       `_penaltyTime`, and the **normalized** `_state`/`_lastState`, and applies
       `isEnabled`. The private fields live on `Module`, so the setter does too.
       Ordering inside the method matters:
       1. Apply `isEnabled` (`enable()`/`disable()`) **first** — `disable()`
          itself calls `bleDisconnect()`/`_playStatus(false)`, and
          `applyPresetConfig` only reconnects when `_isEnabled`, so the flag must
          be correct before the reconnect step (the bootstrap `gameInit()` set it
          from the persisted *player count*, which can differ from the snapshot's
          per-module `isEnabled`).
       2. Set the **normalized** state/penalty.
       3. Re-establish the device (next bullet).
     - **Normalize BOTH `_state` and `_lastState` `play` → `stop` (critical).**
       The reconnect path `bleInitModule()` → `bleSendCurrentState()` →
       `bleNotify()` sends `bleSendPlay()` when `_state == play`
       (`module.dart:84-87`) — restoring `play` would auto-PLAY a robot on
       reconnect with no double-tap. Less obviously, `Module.stop()` switches on
       **`_lastState`** and only handles `stop`/`halfTime`/`fullTime`; `play`
       and `damage` fall through to `default → debugPrint('Wrong last
       ModuleState')`, a **silent no-op** (`module.dart:430-441`). So a module
       restored with `_lastState == play` (the common "was playing when killed"
       case) could no longer be stopped via the single-tap path. Map any
       persisted `play`/`halfTime`/`fullTime` to `stop` for **both** `_state` and
       `_lastState`; preserve `damage`.
     - **Re-establish the BLE device, or auto-reconnect is a no-op (critical).**
       A cold kill constructs fresh `Module`s with `macAddress == ''` /
       `bleDevice == null`; MACs are only ever set via
       `applyPresetConfig`/`setBleDevice` from explicit user actions. So the
       snapshot **must** carry each module's `macAddress`, and
       `restoreFromSnapshot` calls `applyPresetConfig(macAddress, customLabel ??
       '')` — note the `?? ''`: `applyPresetConfig(String macAddress, String
       label)` takes a non-null `String`, so passing the nullable `customLabel`
       directly will not compile. This builds `BluetoothDevice.fromId` and calls
       `bleConnect()` for enabled modules with a non-empty MAC.
     - **Do NOT replay damage/play to robots while the clock is frozen
       (critical) — and the gate must be ASYNC-safe.** A restored `damage` module
       reconnecting via `bleNotify()` would call `bleSendDamage(_penaltyTime)`,
       starting the **robot-side** penalty countdown while the match clock — and
       the app-side penalty decrement (only via `_tickTimer` →
       `notifyAllModulesTimer`) — are frozen, so the robot could self-release
       mid-stoppage without a referee START. The subtlety: `bleConnect()` is
       `async void` and the send happens **later** on the connected-event
       (`bleConnect` → connectionState → `bleInitModule` → `bleSendCurrentState`
       → `bleNotify`, `module.dart:188,312,545`) — seconds after
       `resumePendingMatch()` returns. A single game-scoped `_restoring` flag
       cleared at the end of the (synchronous) restore would already be **false**
       when that callback fires, so it would NOT suppress the send (the bug a flag
       "mirroring `_replaying`" would have shipped). Instead use a **per-module
       one-shot**: `restoreFromSnapshot` sets `_suppressNextRestoreNotify = true`
       on the module; the **first** post-restore `bleNotify()` consumes it
       (clear-on-consume in a `finally`) and sends at most STOP + score, never
       play/damage. It is per-module so each module's own late reconnect is
       covered; it is one-shot so it can NOT linger and suppress the referee's
       later START (and a module whose Bluetooth never comes back simply never
       consumes it — harmless). On the referee's double-tap **START**, the normal
       path sends `playOrDamageAll()` (`bleSendDamage` to still-penalized modules,
       `bleSendPlay` to the rest), so penalties resume *with* match time.
     - **Bound the reconnect, reusing the preset-load path.** Restoring up to 10
       enabled modules calls `bleConnect()` (100 ms stagger, then
       `connect(autoConnect:true)`) — the same fan-out the existing
       preset-load path (`game.dart:724`, `applyPresetConfig` per module) already
       performs, so reuse that behavior rather than inventing a new one. Only
       reconnect enabled modules with non-empty MACs; surface per-module
       "Connecting…"/Cancel state (already supported); keep it entirely off the
       START/STOP command paths.
     - **Both START controls must be penalty-aware after resume.** The central
       timer START (`toggleTimer` → `playAll(false)` → `playOrDamageAll`)
       preserves penalties, but the bottom "START ALL ROBOTS"
       (`toggleAllModules` → `playAll(true)` when nobody is playing,
       `game.dart:307`) calls `Module.playAll()`/`play()` which **zeroes
       `_penaltyTime`** (`module.dart:368`) — it would erase restored penalties.
       Fix: after a cold resume with any restored penalty, the first START from
       *either* control must go through the penalty-aware path. Route
       `toggleAllModules`' first post-resume start through `playAll(false)`
       (penalty-aware), or gate the bottom START until the central timer START has
       resumed the match. Pick one and state it.
     - **Frozen clock — except a half-time break may keep counting.** For
       `firstHalf`/`secondHalf`, freeze: `isTimeRunning = false`, `_isGameRunning
       = false`, `_runClockStartedAt = null`, `timerButtonText = 'START'`; robots
       stopped. For a kill **during the half-time break** (`stage == halfTime`),
       the break countdown drives **no robot play** (robots were stopped by
       `halfTimeAll`), so freezing it and showing `'SKIP'` would strand the
       remaining break with no way to continue (`toggleTimer`'s halfTime branch
       only *skips* to the second half, `game.dart:259`). Instead, restore the
       break's remaining time as the freeze point and **resume the break timer
       running** (`startTimer()` for the halfTime stage) so it continues counting
       down to the second half; `'SKIP'` still lets the referee jump ahead. This
       stays consistent with freeze-and-give-back (the dead time is given back,
       then the break continues) and never auto-plays robots.
     - `_broadcastFullState()`; then **exit the `_suppressPersist` scope and
       `_markDirty()` + flush exactly once** (the flush is a no-op while
       suppressed, so the single committed save must happen *after* the scope
       closes — see the persist-once note below); then `notifyListeners()`.
   - **Discard** → `discardPendingMatch()` → `gameInit()` + `_clearMatchState()`.
     Discard destroys the recoverable snapshot, so it must not be a single
     accidental tap (double-tap safety invariant). Make **Resume** the default/
     prominent action and require a deliberate confirm for Discard — either a
     double-tap discard control or a "Discard match?" second confirmation — so a
     stray tap can't wipe an in-progress match. The dialog is non-dismissible
     (no barrier dismiss / back-button cancel that silently keeps neither path).

6. **No catch-up on cold resume.** The existing `didChangeAppLifecycleState`
   catch-up loop is unchanged and used **only** for warm resume. Cold resume
   deliberately does not advance the clock.

7. **Backgrounded-then-killed — a third case (needs a policy decision).**
   @mato157's warm/cold split assumes a cold kill ≈ an immediate stoppage
   (robots stop within ~4 s of the process dying). That holds for a kill while
   the app is **foregrounded/active**. But if the app is **backgrounded** (the
   process is still alive, BLE links up, robots **still playing**) and Android
   then kills it later, the robots played for the whole background interval and
   only stopped ~4 s after the eventual kill. Meanwhile the 1 Hz `_tickTimer`
   (and thus the heartbeat) is suspended in the background — that is *why* the
   warm catch-up exists — so the freeze point is stuck at the **last foreground**
   value. Freeze-and-give-back would then credit back the entire background
   playing interval, not just the post-kill dead time, handing the match minutes
   it already used.
   - **Minimum mitigation (in this design):** also persist a snapshot on
     `AppLifecycleState.paused`, capturing `_runClockStartedAt` (the wall-clock
     anchor) and `runClockStartRemainingTime` so a cold relaunch *can* tell how
     long the clock had been anchored. This is cheap and keeps the data
     available even though `didChangeAppLifecycleState`'s `paused` branch
     currently only schedules notifications.
   - **Open policy question for @mato157:** for a snapshot whose anchor shows the
     clock was running when backgrounded, should cold resume (a) keep pure
     freeze-and-give-back (simple, over-credits a background kill), (b) advance
     by wall-clock elapsed since the anchor (correct for background-kill,
     *under*-credits a foreground kill by counting dead time), or (c) show the
     referee both values and let them pick? We cannot distinguish the two kill
     modes from a single snapshot, so this is a genuine tradeoff, not an
     implementation detail. Flagged in the issue thread; default to (a) unless
     mato prefers otherwise.

### UI: `lib/screens/home.dart`

- Register `game.onRequestResumeMatch = () => showDialog(...)` alongside the
  existing `onRequestSwitchTeamOrderDialog` registration.
- `AlertDialog`, **non-dismissible** (`barrierDismissible: false`, and a
  `PopScope`/`WillPopScope` that blocks the back button — the referee must pick a
  path, not silently end up in neither): title *"Resume match in progress?"*,
  body `"<teamA> <scoreA> – <scoreB> <teamB>, <stage>, saved <n> min ago"`.
- **Resume** is the default/prominent action → `game.resumePendingMatch()`.
- **Discard is destructive** (it clears the recoverable snapshot) so it must not
  be a single accidental tap (double-tap invariant). Concrete flow: the first
  "Discard" press opens a **second non-dismissible "Discard match?" confirm**
  whose destructive button calls `game.discardPendingMatch()` (or a double-tap
  discard control) — one stray tap can never wipe the match.

### State flags introduced (keep the count honest)

This design adds `_resumePrompted` (one-shot UI), `_suppressPersist` (bootstrap/
restore persistence gate), `_dirty` (persist marker), and a **per-module**
`_suppressNextRestoreNotify`. `_suppressPersist` and the restore-notify suppress
serve the same "restore in progress" phase; an implementation MAY collapse the
game-scoped ones into a single `RestorePhase`/`_coldResumeInProgress` state to
reduce independently-clocked booleans (each transient flag is a lifetime bug
waiting to happen — the async-gate finding above was exactly that). The
per-module one-shot stays per-module by necessity (async reconnects complete
independently).

## Data flow

```
score tap        -> team.addScore -> notifyModulesScore -> _persistMatchState -> save
timer start/stop -> startTimer/stopTimer -> _persistMatchState -> save
stage change     -> _tickTimer transition -> _persistMatchState -> save
running clock     -> _tickTimer (every ~5s) -> heartbeat save (freeze point)
warm resume      -> didChangeAppLifecycleState(resumed) -> catch-up (UNCHANGED)
cold relaunch    -> _loadPrefs -> store.load (BEFORE bootstrap gameInit) -> (inGame) onRequestResumeMatch
                    -> Resume  -> restore (play->stop) + FREEZE clock (no subtraction), robots STOPPED
                    -> Discard -> gameInit + _clearMatchState
end of match     -> fullTime / GAME OVER -> _clearMatchState
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

- `match_state_store_test.dart`: round-trip save/load (incl. per-module
  `macAddress` and the `runClockStartedAtMs`/`runClockStartRemainingTime` anchor
  fields); `load()` null on missing key, on corrupted JSON, and on version
  mismatch; `clear()` removes it; **a stale older `save` completing after a
  `clear()` (or a newer `save`) does NOT resurrect/overwrite** — generation guard
  / coalescing (regression for the durability ordering finding).
- `game_recovery_test.dart`:
  - score change persists a snapshot with the right scores;
  - heartbeat updates `remainingTime` while the clock runs;
  - `startTimer`/`stopTimer` update the snapshot;
  - **`gameInit()` does NOT clear the snapshot** — after the bootstrap
    `_loadPrefs()` → `gameInit()` runs, a persisted in-progress match survives
    and `onRequestResumeMatch` still fires (regression test for the
    load-before-clear bug);
  - `_clearMatchState()` removes the snapshot; it fires on Discard and on the
    `fullTime`/GAME OVER transition, not on bootstrap init;
  - a snapshot with `inGame==true` (stage != fullTime) triggers
    `onRequestResumeMatch`; a `fullTime` snapshot does not;
  - **`resumePendingMatch` freezes the clock at the persisted freeze point** —
    `_remainingTime` equals the snapshot value regardless of how long ago
    `savedAt` was (no dead-time subtraction); `isTimeRunning == false`;
    scores/stage/team-order restored; second half not auto-started; robots not
    played.
  - **full per-module restore** — a snapshot with a module in `damage` state and
    `penaltyTime > 0`, plus a custom label and enabled flag, round-trips through
    `restoreFromSnapshot` to the exact `state`/`lastState`/`penaltyTime`/label;
  - **`play` is normalized to `stop` on restore for BOTH `_state` and
    `_lastState`** — a snapshot with a module in `play` restores both fields as
    `stop`, so the reconnect `bleNotify()` path cannot emit `bleSendPlay()` AND a
    later `Module.stop()` (which switches on `_lastState`) is not a silent no-op
    (regression tests for the auto-play-on-reconnect and the `stop()`-no-op
    bugs); a `damage` module keeps `damage`.
  - **damage is not replayed to the robot during the frozen clock, even on a
    LATE async reconnect** — `restoreFromSnapshot` sets the per-module
    `_suppressNextRestoreNotify`; a `bleNotify()` fired from a reconnect that
    completes *after* `resumePendingMatch()` returns still suppresses
    `bleSendDamage`/`bleSendPlay` (sends at most STOP+score) and consumes the
    one-shot; only a referee START via `playOrDamageAll` sends damage (regression
    for the async-gate bug — a synchronous flag would already be cleared).
  - **bottom START preserves restored penalties** — after a cold resume with a
    `damage` module, the bottom "START ALL" path does not zero `_penaltyTime`
    (goes through the penalty-aware start, not `playAll(true)`).
  - **half-time cold resume continues the break** — a `halfTime` snapshot restores
    the break with the clock **running** (not auto-skipped to second half) at the
    frozen remaining time.
  - **warm-resume persists post-catch-up** — after the `resumed` replay loop, one
    flush records the advanced freeze point (so a crash right after resume can't
    over-credit).
  - **fullTime transition clears, not persists** — the secondHalf→fullTime
    `_tickTimer` case clears the snapshot rather than saving a `fullTime` one.
  - **module MAC round-trips and drives reconnect** — `restoreFromSnapshot` on a
    fresh module with a non-empty `macAddress` sets `macAddress` and (for an
    enabled module) goes through the `applyPresetConfig` device-setup path with a
    non-null label (`customLabel ?? ''`); `isEnabled` is applied **before** the
    reconnect call, and `_state`/`_lastState` are set before it too.
  - **enabled flag from snapshot wins over the bootstrap player count** — a
    module disabled in the snapshot but enabled by the bootstrap `gameInit()`
    player count ends up disabled (and not reconnected) after restore.
  - **swapped team order restores by id** — a snapshot saved with `teams[0].id ==
    'B'` restores names/scores onto the correct physical sides (reverse applied;
    assignment by `id`, not index).
  - **bootstrap does not wipe the on-disk snapshot** — with `_suppressPersist`
    active during `_loadPrefs()`'s `gameInit()` → `stopTimer()`, the persisted
    snapshot on disk is unchanged (regression test for the indirect
    `gameInit→stopTimer` re-wipe).
  - **team-name edits persist** — `Game.setTeamName(...)` (the route that
    replaces direct `team.name =` + `notifyMQTT` in `TeamSettingsWidget`)
    persists a snapshot; `loadMatchData()` persists applied names.
  - **resume-callback drain** — stashing `_pendingResume` *before*
    `onRequestResumeMatch` is assigned still fires the prompt exactly once when
    the callback is later registered (regression test for the registration
    race); assigning the callback when there is no pending resume does nothing.
  - **pause persists a snapshot** — `didChangeAppLifecycleState(paused)` while the
    clock runs writes a snapshot carrying `runClockStartedAtMs` (data for the
    backgrounded-then-killed case, item 7).

## Files touched

| Path | Change |
|---|---|
| `lib/services/match_state_store.dart` | **new** — versioned snapshot model (incl. clock-anchor fields) + serialized save/clear stream with generation guard/coalescing |
| `lib/models/game.dart` | store wiring, `_markDirty` + off-hot-path coalesced flush, `_suppressPersist` scope, heartbeat (decrement-branch only) + post-catch-up flush, pause-snapshot, cold-resume flow, `setTeamName`, restore-by-id, penalty-aware first START |
| `lib/models/module.dart` | `toSnapshot()` / `restoreFromSnapshot()` (normalize `_state` **and** `_lastState`, enabled-first ordering), per-module one-shot `_suppressNextRestoreNotify` consumed by first post-restore `bleNotify` |
| `lib/screens/home.dart` | register `onRequestResumeMatch`, resume/**confirm-discard** dialog, route team-name edits through `Game.setTeamName` |
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
- **Open policy question for @mato157 — backgrounded-then-killed** (see design
   item 7). Pure freeze-and-give-back over-credits a match that was killed while
   *backgrounded with robots still playing*. The design persists a pause-time
   snapshot so the data exists; the policy (keep freeze / advance by wall-clock /
   ask the referee) is mato's call. Defaulting to freeze until decided.

## Branch / PR

Branch `mrshu/match-recovery` off `dev`; one focused PR for parts 1 & 2 of #4.
Logging (#16) is a separate follow-up.
