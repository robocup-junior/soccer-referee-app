import 'package:flutter/material.dart';

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
/// exactly. [onLongPress] passes through unchanged in both modes (it drives the
/// module-settings / team-edit navigation, which is not a critical control).
///
/// Button-backed sites (the timer and all-robots ElevatedButtons) must NOT use
/// this — a parent onTap competes with the button's own tap recognizer in the
/// gesture arena and can lose. Use [criticalButtonGestures] for those.
class CriticalGestureDetector extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: singleTap ? onAction : null,
      onDoubleTap: singleTap ? null : onAction,
      onLongPress: onLongPress,
      child: child,
    );
  }
}

/// Gesture wiring for the **button-backed** critical sites (the timer and
/// all-robots [ElevatedButton]s in `home.dart`).
///
/// Returns the (button onPressed, parent onDoubleTap) pair so the single tap is
/// routed through the button itself rather than a parent onTap that would lose
/// the gesture arena to the button's own recognizer:
///
/// - double-tap mode: `onPressed` is a no-op (today's behavior — the button
///   swallows single taps) and the parent `onDoubleTap` runs the action.
/// - single-tap mode: `onPressed` runs the action and the parent `onDoubleTap`
///   is null, so the action fires on the button with no arena conflict.
({VoidCallback? onPressed, VoidCallback? onDoubleTap}) criticalButtonGestures({
  required bool singleTap,
  required VoidCallback onAction,
}) {
  return (
    onPressed: singleTap ? onAction : () {},
    onDoubleTap: singleTap ? null : onAction,
  );
}
