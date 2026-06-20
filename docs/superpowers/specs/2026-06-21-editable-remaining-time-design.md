# Editable remaining match time via long-press

Tracks GitHub issue #21.

## Problem

There is no way to correct the remaining match time. If the referee
forgets to stop the clock (e.g. during a rules discussion / stoppage),
the lost playing time cannot be given back to the teams.

## Solution

Make the timer display editable the same way the score already is:
**long-press the time** to open a bottom-sheet editor, mirroring the
existing score editor (`buildTeamContainer` /
`TeamSettingsWidget`). The double-tap start/stop toggle on the button
below the time is left untouched (double-tap safety invariant).

## Decisions

- **Editable only while the clock is stopped within an active first or
  second half.** The editor will not open while the timer is running.
  This avoids reconciling the background catch-up anchors
  (`_runClockStartedAt`, `_runClockStartRemainingTime`), which are
  already `null` when stopped (`stopTimer` clears them). Half-time is
  excluded because its clock always runs (the `firstHalf -> halfTime`
  transition calls `startTimer()` and the only half-time control, SKIP,
  jumps straight to the second half, so a stopped half-time state never
  exists). Pre-match setup (`inGame == false`) is excluded so the match
  duration is changed only via Settings; full time is excluded by the
  stage check.
- **Editor controls: quick +/- buttons plus an `mm:ss` field.** Mirrors
  the score editor's affordance set while allowing a precise jump.

## Correction to the issue's implementation notes

The issue suggests `setRemainingTime` should call
`notifyAllModulesTimer()` "so per-module damage-timer alerts stay
correct." Reading the code, `notifyAllModulesTimer()` (game.dart:319)
*decrements each damaged module's penalty by one tick* — it is the
per-second damage countdown driven by `_tickTimer`. A one-time game-time
correction is not a tick; calling it would wrongly subtract a second
from every active damage timer. Game time and module damage timers are
independent, so `setRemainingTime` does **not** call it.

Likewise, the issue mentions publishing the corrected time to the BLE
bridge. The bridge currently carries only `team{1,2}_score` and
`team{1,2}_color` (`bridge_message.dart`) — there is no time topic, and
the live timer ticks never publish time to the bridge. `setRemainingTime`
therefore does not publish to the bridge; adding a bridge time topic is
out of scope. It does publish stage+time to MQTT via
`_broadcastStageAndTime()` (the same call every other stopped-state
update uses — reset, refresh, resume-without-replay, SKIP) so a retained
MQTT consumer never combines the corrected time with a stale stage.

## Model — `lib/models/game.dart`

Add a public setter next to the `remainingTime` getter:

```dart
void setRemainingTime(int seconds) {
  // Editing is gated to a stopped clock in an active half by the UI, so
  // the run-clock catch-up anchors are already null — no reconciliation
  // needed — and both editable stages cap at periodTime.
  _remainingTime = seconds.clamp(0, periodTime);
  notifyListeners();
  _broadcastStageAndTime();
}
```

- Clamp to `[1, periodTime]`. The floor is 1 second, not 0: the normal
  expiry path never leaves an active half stopped at `0:00` (a tick at 0
  transitions the stage), so a manual `0:00` would create a state where a
  later START double-tap fires `playAll()` one tick before the transition
  stops the robots again. Flooring at 1 keeps the manual path consistent
  with the timer's own invariant.
- Publishes stage+time via `_broadcastStageAndTime()`.
- Does not touch the run-clock anchors and does not call
  `notifyAllModulesTimer()`.

## UI — `lib/screens/home.dart`

Wrap the remaining-time `Text` (currently home.dart:88) in a
`GestureDetector` with `onLongPress`. The double-tap start/stop toggle
stays on the separate `ElevatedButton` below it (unchanged).

- `onLongPress` opens the editor only when `!game.isTimerRunning` **and**
  `game.inGame` **and** `currentStage` is `firstHalf` or `secondHalf`.
- While the timer is running, show a `SnackBar`: "Stop the clock to edit
  the time." (Do not open the editor.) Other blocked states (pre-match,
  full time) silently ignore the long-press.
- The editor is a `showModalBottomSheet` using the same
  `FractionallySizedBox` + grey container styling as the score editor,
  hosting a new `TimeSettingsWidget`.

### `TimeSettingsWidget` (new `StatefulWidget`)

Mirrors `TeamSettingsWidget`:

- Title "Edit remaining time".
- An `mm:ss` `TextEditingController` seeded from `game.remainingTime`.
  "Set" parses the field via the top-level `parseMmSs(String)` helper and
  applies via `game.setRemainingTime`. `parseMmSs` accepts either a plain
  nonnegative seconds integer or `mm:ss` with a nonnegative minutes part
  and a seconds part in `0..59`; anything else (`5:99`, `1:2:3`, `:30`,
  empty, non-numeric) returns `null` and the field is restored to the
  current value. Extracting it as a top-level pure function keeps the
  parsing unit-testable without pumping a widget.
- Quick-nudge buttons **−1:00 / −0:30 / +0:30 / +1:00**, each calling
  `game.setRemainingTime(game.remainingTime ± delta)` (clamping handles
  the bounds) and refreshing the field text to the clamped value.

## Testing (manual, on device)

- Long-press while stopped opens the editor.
- Nudge buttons clamp at 0 and at the stage maximum.
- `mm:ss` entry applies the exact time.
- The MQTT scoreboard reflects the corrected time.
- Long-press while running shows the SnackBar and does not open the
  editor.
- Double-tap start/stop still toggles the clock (invariant preserved).

## Invariants respected (CLAUDE.md)

- No change to the fire-and-forget robot START/STOP path.
- Start/stop stays double-tap; the edit is a deliberate long-press +
  bottom-sheet action.
- Portrait-only and provider tree untouched.
