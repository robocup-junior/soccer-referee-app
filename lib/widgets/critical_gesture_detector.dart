import 'package:flutter/material.dart';

/// Minimum gap between two single-tap critical actions (issue #12, round-2
/// review). A second tap within this window of the first is ignored, so a
/// reflexive double-tap — muscle memory from the default double-tap mode —
/// fires the critical action only once instead of twice (e.g. +2 goals, or
/// stop-then-restart all robots). Matches Flutter's double-tap recognition
/// window (`kDoubleTapTimeout` is 300ms).
const Duration kCriticalTapDebounce = Duration(milliseconds: 300);

/// Stateful single-tap guard: [allow] returns true at most once per [window].
///
/// The clock is passed in so the guard is deterministically unit-testable; the
/// widgets below call `allow(DateTime.now())`. It only ever *suppresses* a
/// follow-up tap — the first (allowed) tap fires its action immediately and
/// synchronously, so nothing is delayed or queued on the critical path.
class TapDebounce {
  TapDebounce([this.window = kCriticalTapDebounce]);

  final Duration window;
  DateTime? _lastFired;

  bool allow(DateTime now) {
    final last = _lastFired;
    if (last != null && now.difference(last) < window) return false;
    _lastFired = now;
    return true;
  }
}

/// Gesture wrapper for the app's critical control actions (issue #12).
///
/// All destructive controls default to double-tap to guard against accidental
/// touch (CLAUDE.md invariant). When the user opts into single-tap mode via
/// Settings, the same action fires on a single tap instead.
///
/// This widget is for the **non-button** sites — a plain/decorated child whose
/// tap is owned entirely by this [GestureDetector] (the per-module cell and the
/// score container in `home.dart`). It registers **exactly one** of
/// [GestureDetector.onTap]/[GestureDetector.onDoubleTap] so there is no
/// tap-disambiguation delay and double-tap mode reproduces today's behavior
/// exactly. [onLongPress] passes through unchanged in both modes.
///
/// In single-tap mode taps are debounced via [TapDebounce] so a reflexive
/// double-tap fires the action once. Double-tap mode is left untouched (a
/// double-tap is already a single deliberate gesture).
///
/// Button-backed sites (the timer and all-robots controls) use [CriticalButton]
/// instead — a parent onTap would lose the gesture arena to an ElevatedButton's
/// own tap recognizer.
class CriticalGestureDetector extends StatefulWidget {
  final bool singleTap;
  final VoidCallback onAction;
  final VoidCallback? onLongPress;
  final Widget child;

  const CriticalGestureDetector({
    required this.singleTap,
    required this.onAction,
    required this.child,
    this.onLongPress,
    super.key,
  });

  @override
  State<CriticalGestureDetector> createState() =>
      _CriticalGestureDetectorState();
}

class _CriticalGestureDetectorState extends State<CriticalGestureDetector> {
  final TapDebounce _debounce = TapDebounce();

  void _fireSingleTap() {
    if (_debounce.allow(DateTime.now())) widget.onAction();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.singleTap ? _fireSingleTap : null,
      onDoubleTap: widget.singleTap ? null : widget.onAction,
      onLongPress: widget.onLongPress,
      child: widget.child,
    );
  }
}

/// Critical control backed by an [ElevatedButton] (the timer and all-robots
/// buttons in `home.dart`).
///
/// A parent `onTap` competes with the button's own tap recognizer in the
/// gesture arena and can lose, so the single tap is routed through the button's
/// `onPressed`; the double-tap stays on the parent [GestureDetector]:
///
/// - double-tap mode: `onPressed` is a no-op (button stays enabled exactly as
///   today) and the parent `onDoubleTap` runs the action.
/// - single-tap mode: `onPressed` runs the (debounced) action and the parent
///   `onDoubleTap` is null, so the action fires on the button with no arena
///   conflict and a reflexive double-tap fires once.
///
/// [style] and [child] are computed reactively by the caller and passed through
/// so the button's color/label still track game state.
class CriticalButton extends StatefulWidget {
  final bool singleTap;
  final VoidCallback onAction;
  final ButtonStyle? style;
  final Widget child;

  const CriticalButton({
    required this.singleTap,
    required this.onAction,
    required this.child,
    this.style,
    super.key,
  });

  @override
  State<CriticalButton> createState() => _CriticalButtonState();
}

class _CriticalButtonState extends State<CriticalButton> {
  final TapDebounce _debounce = TapDebounce();

  void _fireSingleTap() {
    if (_debounce.allow(DateTime.now())) widget.onAction();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: widget.singleTap ? null : widget.onAction,
      child: ElevatedButton(
        onPressed: widget.singleTap ? _fireSingleTap : () {},
        style: widget.style,
        child: widget.child,
      ),
    );
  }
}
