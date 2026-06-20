# Single-tap actions toggle — design

Issue: #12 (Feature: allow switching double taps to single taps).
Date: 2026-06-20
Status: draft — approved in brainstorming

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

A pref-backed bool, mirroring the existing `periodTime`/`halfTimeDuration`
pattern (same `_prefs`, same getter/setter shape):

```dart
static const String _singleTapEnabledKey = 'gesture_single_tap_enabled';
bool _singleTapEnabled = false;

bool get singleTapEnabled => _singleTapEnabled;
set singleTapEnabled(bool value) {
  _singleTapEnabled = value;
  _prefs?.setBool(_singleTapEnabledKey, value);
  notifyListeners();
}
```

- Loaded in `_loadPrefs()`: `_singleTapEnabled = _prefs!.getBool(_singleTapEnabledKey) ?? false;`
- Default `false` ⇒ double-tap. Setter persists and `notifyListeners()` so the
  Home buttons rebuild live when toggled (Home already rebuilds on `Game`).

No new provider, no new service — keeps the change minimal and the provider-tree
invariant intact.

### 2. `CriticalGestureDetector` (`lib/widgets/critical_gesture_detector.dart`, new)

A small, single-purpose widget so the mode logic lives in exactly one tested
place instead of four hand-rolled `if/else` gesture detectors:

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

Key property: it registers **exactly one** of `onTap`/`onDoubleTap`, never both.
That avoids Flutter's tap-disambiguation delay (which would otherwise slow the
single-tap path) and exactly reproduces today's behavior in double-tap mode.
`onLongPress` is passed through so the per-module and score widgets keep their
long-press editors in both modes.

### 3. Wire the four Home sites

Replace each of the four `GestureDetector(onDoubleTap: …)` (and the two that also
have `onLongPress`) with `CriticalGestureDetector`, reading `singleTap` from the
`Game` already in scope (`context.watch<Game>().singleTapEnabled`, or the
existing `Consumer`/`game` reference at each site). The action and any
`onLongPress` move across verbatim.

### 4. Settings toggle (`lib/screens/settings.dart`)

A `SwitchListTile`:
- title: "Single-tap actions"
- subtitle: a short warning, e.g. "Off by default. When on, start/stop, scoring
  and robot controls fire on a single tap — this removes the accidental-touch
  protection."
- value: `game.singleTapEnabled`; `onChanged`: `game.singleTapEnabled = v`.

Placed near the other game/behavior settings, following the existing section
style.

## Data flow

```
Settings SwitchListTile -> game.singleTapEnabled = v -> _prefs.setBool + notifyListeners
Home rebuild -> CriticalGestureDetector(singleTap: game.singleTapEnabled)
  singleTap == true  -> onTap fires the action
  singleTap == false -> onDoubleTap fires the action (default)
onLongPress -> unchanged in both modes
```

## Error handling

- `_prefs` not yet loaded at first build → getter returns the in-memory default
  (`false`), i.e. double-tap. No crash; once `_loadPrefs` completes,
  `notifyListeners` rebuilds with the stored value.

## Testing

- **`test/single_tap_pref_test.dart`** (or fold into an existing Game test):
  `singleTapEnabled` defaults to `false`; setting it persists to
  SharedPreferences and a fresh load returns the stored value.
- **`test/critical_gesture_detector_test.dart`** (widget test):
  - `singleTap: true` → a single tap fires `onAction`.
  - `singleTap: false` → a double tap fires `onAction`; a single tap does **not**.
  - `onLongPress` fires in both modes.

## Files touched

| Path | Change |
|---|---|
| `lib/models/game.dart` | pref-backed `singleTapEnabled` getter/setter + load in `_loadPrefs` |
| `lib/widgets/critical_gesture_detector.dart` | **new** — single/double-tap gesture wrapper |
| `lib/screens/home.dart` | replace the 4 critical `GestureDetector`s with `CriticalGestureDetector` |
| `lib/screens/settings.dart` | "Single-tap actions" `SwitchListTile` |
| `test/critical_gesture_detector_test.dart` | **new** |
| `test/single_tap_pref_test.dart` | **new** (or extend an existing Game test) |

## Branch / PR

Branch `mrshu/single-tap-toggle` off `dev`; one focused PR closing #12.
