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

- **Editable only while the clock is stopped.** The editor will not open
  while the timer is running. This avoids reconciling the background
  catch-up anchors (`_runClockStartedAt`,
  `_runClockStartRemainingTime`), which are already `null` when stopped
  (`stopTimer` clears them). Simplest and safest.
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
the live timer ticks never publish time to the bridge. To stay
consistent with existing behavior, `setRemainingTime` publishes to MQTT
only (mirroring `_tickTimer`). Adding a bridge time topic is out of
scope.

## Model — `lib/models/game.dart`

Add a public setter next to the `remainingTime` getter:

```dart
void setRemainingTime(int seconds) {
  // Editing is gated to a stopped clock in the UI, so the run-clock
  // catch-up anchors are already null — no reconciliation needed.
  final maxTime = currentStage == MatchStage.halfTime
      ? halfTimeDuration
      : periodTime;
  _remainingTime = seconds.clamp(0, maxTime);
  notifyListeners();
  mqttService.publishTime(_remainingTime);
}
```

- Clamp to the current stage's natural maximum (`halfTimeDuration`
  during the break, otherwise `periodTime`), floor 0.
- Publishes to MQTT only.
- Does not touch the run-clock anchors and does not call
  `notifyAllModulesTimer()`.

## UI — `lib/screens/home.dart`

Wrap the remaining-time `Text` (currently home.dart:88) in a
`GestureDetector` with `onLongPress`. The double-tap start/stop toggle
stays on the separate `ElevatedButton` below it (unchanged).

- `onLongPress` opens the editor only when `!game.isTimerRunning` **and**
  `currentStage` is `firstHalf`, `secondHalf`, or `halfTime`.
- While the timer is running, show a `SnackBar`: "Stop the clock to edit
  the time." (Do not open the editor.)
- The editor is a `showModalBottomSheet` using the same
  `FractionallySizedBox` + grey container styling as the score editor,
  hosting a new `TimeSettingsWidget`.

### `TimeSettingsWidget` (new `StatefulWidget`)

Mirrors `TeamSettingsWidget`:

- Title "Edit remaining time".
- An `mm:ss` `TextEditingController` seeded from `game.remainingTime`.
  "Set" parses the field (accept `mm:ss` or a plain seconds integer;
  ignore unparseable input) and applies via `game.setRemainingTime`.
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
