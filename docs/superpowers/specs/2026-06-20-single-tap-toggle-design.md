# Single-tap actions toggle — design

Issue: #12 (Feature: allow switching double taps to single taps).
Date: 2026-06-20
Status: draft — approved in brainstorming + review-anvil R1 hardening

## Problem

All critical control actions in the app require a **double-tap** to guard against
accidental touch (CLAUDE.md invariant). Some referees want faster single-tap
operation. #12 asks for a settings toggle that switches all double-tap actions to
single-tap, with the **default remaining double-tap**.

## Scope

The toggle affects exactly the four `onDoubleTap` critical actions in
`lib/screens/home.dart`:

1. Timer START/STOP — `game.toggleTimer()` (`home.dart:94`)
2. Start/stop **all** robots — `game.toggleAllModules()` (`home.dart:153`)
3. Per-module play / penalty / stop — `module.play()/penalty()/stop()`
   (`home.dart:196`)
4. Score a goal — `team.addScore(1)` + `game.stopAll(true)` +
   `game.notifyModulesScore()` (`home.dart:264`)

All four are in scope (decided 2026-06-20), including scoring — one switch, one
consistent behavior everywhere.

**Out of scope — unchanged in both modes:** the `onLongPress` actions, which are
navigation/edit, not critical control:
- open module settings (`home.dart:207`)
- edit team name/score bottom sheet (`home.dart:269`)

These remain long-press regardless of the toggle.

## Non-goals / invariants

- **START/STOP latency:** unaffected. The toggle only chooses the *gesture
  recognizer*; the action callbacks (`toggleTimer`, `toggleAllModules`,
  `module.*`, `team.addScore`) and the fire-and-forget `bleSendPlayAll()`/
  `bleSendStopAll()` paths are untouched. No awaits/blocking added.
- **Double-tap safety:** this feature *intentionally* relaxes that invariant —
  but **only when the user explicitly opts in**. The default (`false`) preserves
  double-tap everywhere, so the shipped-default behavior is unchanged.
- **Provider tree:** **no new provider.** The preference lives on the existing
  `Game` `ChangeNotifier`, which `home.dart` already consumes — so the static
  provider list in `main.dart` is untouched.
- **Portrait-only:** unchanged.

## Architecture

### 1. Preference on `Game` (`lib/models/game.dart`)

A pref-backed bool stored on `Game` (same `_prefs` instance as the other game
settings). Note it is **not** an exact copy of `periodTime`: that setter does
*not* `notifyListeners()`, but this one **must** (so the Home buttons rebuild live
on toggle):

```dart
static const String _singleTapEnabledKey = 'gesture_single_tap_enabled';
bool _singleTapEnabled = false;

bool get singleTapEnabled => _singleTapEnabled;
set singleTapEnabled(bool value) {
  if (_singleTapEnabled == value) return;
  _singleTapEnabled = value;
  if (_prefsLoaded) {
    _prefs!.setBool(_singleTapEnabledKey, value);
  } else {
    _pendingSingleTapWrite = true; // persisted at end of _loadPrefs
  }
  notifyListeners();
}
```

- **Load-timing race (lost write).** `Game()` starts `_loadPrefs()` unawaited
  (`game.dart:87`); `_prefs` is null until it resolves. A naive
  `_prefs?.setBool` would *silently drop* a toggle made before load, and the
  subsequent `_loadPrefs` read (`getBool(...) ?? false`) would then clobber the
  user's choice. Guard it like `VibrationService` does with `_prefsLoaded`: the
  setter writes memory immediately; if prefs aren't loaded yet it marks a pending
  write; `_loadPrefs()` reads the stored value into `_singleTapEnabled` **only
  when no pending user change exists**, and flushes any pending write at the end.
  (In practice the Settings screen is reached after load, but this closes the
  race without relying on that.)
- Default `false` ⇒ double-tap (shipped behavior unchanged).

No new provider, no new service — keeps the change minimal and the provider-tree
invariant intact.

### 2. Two gesture patterns — because two of the four sites wrap a button

The four sites are **not** structurally identical, and that matters for Flutter's
gesture arena:

- **Non-button children** (per-module cell `home.dart:196`, score container
  `home.dart:264`) wrap a plain/decorated child. A parent `GestureDetector` owns
  the tap → safe to swap `onDoubleTap` for `onTap`.
- **Button children** (timer `home.dart:94→ElevatedButton(onPressed:(){})` at
  `:98`; all-robots `:153→onPressed:(){}` at `:175`) wrap an interactive
  `ElevatedButton`. A parent `onTap` **competes with the button's own tap
  recognizer and can lose the arena** — so single-tap mode would silently not
  fire. (Double-tap works today only because the button consumes single taps
  while the parent claims the double-tap.) For these, the single tap must go on
  the **button's `onPressed`**, not a parent `onTap`.

So:

**(a) `CriticalGestureDetector`** (`lib/widgets/critical_gesture_detector.dart`,
new) — for the two **non-button** sites:

```dart
class CriticalGestureDetector extends StatelessWidget {
  final bool singleTap;
  final VoidCallback onAction;
  final VoidCallback? onLongPress;
  final Widget child;
  // ...
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: singleTap ? onAction : null,
        onDoubleTap: singleTap ? null : onAction,
        onLongPress: onLongPress,
        child: child,
      );
}
```

Registers **exactly one** of `onTap`/`onDoubleTap` (never both → no
tap-disambiguation delay; double-tap mode reproduces today exactly), and passes
`onLongPress` through so the per-module/score long-press editors survive.

**(b) Button sites** — keep the `GestureDetector`+`ElevatedButton`, but route the
single tap through the button. A tiny shared helper keeps the logic in one tested
place:

```dart
// returns the (onTap-for-button, onDoubleTap-for-parent) pair
({VoidCallback? onPressed, VoidCallback? onDoubleTap})
    criticalButtonGestures({required bool singleTap, required VoidCallback onAction}) =>
  (onPressed: singleTap ? onAction : () {},
   onDoubleTap: singleTap ? null : onAction);
```

- double-tap mode: `onPressed: () {}` (today's no-op), parent `onDoubleTap:
  onAction` (today's behavior).
- single-tap mode: `onPressed: onAction`, parent `onDoubleTap: null` — the action
  fires on the button itself, no arena conflict.

### 3. Wire the four Home sites

- **Per-module (`:196`) and score (`:264`)** → wrap in `CriticalGestureDetector`,
  moving the action body and `onLongPress` across verbatim. The per-module
  play/penalty/stop branching and the score `addScore`+`stopAll(true)`+
  `notifyModulesScore()` collapse into the single `onAction` callback unchanged.
- **Timer (`:94`) and all-robots (`:153`)** → keep the existing
  `GestureDetector`/`ElevatedButton`, feeding both from `criticalButtonGestures`.

All four read `singleTap` from the `Game` already in scope at build (`home.dart`
holds `final game = Provider.of<Game>(context)` at `:35`, and the per-module/score
builders receive `game` by parameter), so a toggle rebuilds them live.

### 4. Settings toggle (`lib/screens/settings.dart`)

Follow the **actual** settings pattern: a `SettingSwitch` inside a
`SettingsSection` (there is no `SwitchListTile` in this screen — every toggle
uses `SettingSwitch`, e.g. the Vibration section).

- **Reactivity (required).** `SettingsScreen` is a `StatefulWidget` that reads
  `widget.game` directly — it is *not* a `context.watch` consumer, so
  `Game.notifyListeners()` does not rebuild it. The switch thumb would appear
  stuck unless the change goes through `setState`. So `onChanged: (v) =>
  setState(() => widget.game.singleTapEnabled = v)` (matching how existing
  toggles update, e.g. `settings.dart:147`), or wrap the section in
  `AnimatedBuilder(animation: widget.game)`. Use `setState`.
- **Warning text.** `SettingSwitch` (`settings.dart:891`) has **no** subtitle
  parameter. Either (preferred) add an optional `subtitle`/`description` param to
  `SettingSwitch` (additive, backward-compatible — all existing call sites omit
  it) and render it under the row, or place a short helper `Text` in the same
  `SettingsSection`. Warning copy: "Off by default. When on, start/stop, scoring
  and robot controls fire on a single tap — removes the accidental-touch
  protection."
- title: "Single-tap actions"; value: `widget.game.singleTapEnabled`.

Placed in a `SettingsSection` near the other behavior settings.

## Data flow

```
Settings SettingSwitch -> setState(() => game.singleTapEnabled = v)
  -> persist (or pending-write if prefs not loaded) + notifyListeners
Home rebuild (Provider.of<Game> at :35):
  non-button sites -> CriticalGestureDetector(singleTap)
     true  -> onTap fires onAction ; false -> onDoubleTap fires onAction
  button sites     -> criticalButtonGestures(singleTap)
     true  -> ElevatedButton.onPressed = onAction, parent onDoubleTap = null
     false -> onPressed = no-op,            parent onDoubleTap = onAction
onLongPress -> unchanged in both modes
```

## Error handling

- `_prefs` not loaded at first build → getter returns the in-memory default
  (`false`) = double-tap. No crash; `_loadPrefs` then applies the stored value
  (or flushes a pending pre-load toggle) and `notifyListeners` rebuilds.

## Testing

- **`test/single_tap_pref_test.dart`** (or fold into an existing Game test):
  `singleTapEnabled` defaults to `false`; setting it persists to
  SharedPreferences and a fresh load returns the stored value; **a toggle made
  before `_loadPrefs()` completes is not lost** (pending-write flush; the stored
  default does not clobber it).
- **`test/critical_gesture_detector_test.dart`** (widget test):
  - `singleTap: true` → a single tap fires `onAction`.
  - `singleTap: false` → a double tap fires `onAction`; a single tap does **not**.
  - `onLongPress` fires in both modes.
  - **with an `ElevatedButton` child driven by `criticalButtonGestures`**: in
    single-tap mode a single tap fires `onAction` (via the button's `onPressed`,
    not swallowed); in double-tap mode a double tap fires it and a single tap
    does not.

## Files touched

| Path | Change |
|---|---|
| `lib/models/game.dart` | pref-backed `singleTapEnabled` getter/setter (with `_prefsLoaded`/pending-write guard) + load in `_loadPrefs`; `criticalButtonGestures` helper (or co-locate with the widget) |
| `lib/widgets/critical_gesture_detector.dart` | **new** — single/double-tap wrapper for non-button sites + `criticalButtonGestures` helper for button sites |
| `lib/screens/home.dart` | per-module & score → `CriticalGestureDetector`; timer & all-robots → `criticalButtonGestures` on the existing `ElevatedButton` |
| `lib/screens/settings.dart` | `SettingSwitch` in a `SettingsSection` via `setState`; optional `subtitle` on `SettingSwitch` for the warning |
| `test/critical_gesture_detector_test.dart` | **new** (incl. an `ElevatedButton`-child case) |
| `test/single_tap_pref_test.dart` | **new** (or extend an existing Game test; incl. pre-load toggle) |

## Branch / PR

Branch `mrshu/single-tap-toggle` off `dev`; one focused PR closing #12.
