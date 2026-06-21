// Widget tests for the single-tap/double-tap critical control widgets (issue
// #12): CriticalGestureDetector (non-button sites), CriticalButton
// (ElevatedButton-backed sites), and the TapDebounce guard that makes a
// reflexive double-tap fire a single-tap action only once.
//
// Single-tap mode is verified with real taps (only a TapGestureRecognizer is
// involved). Double-tap mode is verified by inspecting/invoking the configured
// callbacks rather than simulating a real double tap: a single tap on a
// GestureDetector that registers only onDoubleTap leaves the
// DoubleTapGestureRecognizer's timeout Timer pending and trips the test
// binding's `!timersPending` invariant. Inspecting the wiring proves the
// contract (single tap cannot fire; the action is bound to the double tap)
// without that fragility.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rcj_scoreboard/widgets/critical_gesture_detector.dart';

void main() {
  group('TapDebounce', () {
    final t0 = DateTime(2026, 1, 1, 12, 0, 0);

    test('allows the first call', () {
      expect(TapDebounce().allow(t0), isTrue);
    });

    test('suppresses a second call within the window', () {
      final d = TapDebounce(const Duration(milliseconds: 300));
      expect(d.allow(t0), isTrue);
      expect(d.allow(t0.add(const Duration(milliseconds: 100))), isFalse);
      expect(d.allow(t0.add(const Duration(milliseconds: 299))), isFalse);
    });

    test('allows again once the window has elapsed', () {
      final d = TapDebounce(const Duration(milliseconds: 300));
      expect(d.allow(t0), isTrue);
      expect(d.allow(t0.add(const Duration(milliseconds: 300))), isTrue);
      // and the window restarts from the last allowed call
      expect(d.allow(t0.add(const Duration(milliseconds: 350))), isFalse);
    });
  });

  group('CriticalGestureDetector (non-button)', () {
    Widget host(bool single, VoidCallback onAction,
        {VoidCallback? onLongPress}) {
      return MaterialApp(
        home: Scaffold(
          body: CriticalGestureDetector(
            singleTap: single,
            onAction: onAction,
            onLongPress: onLongPress,
            child: const SizedBox(width: 200, height: 200, child: Text('x')),
          ),
        ),
      );
    }

    GestureDetector findGd(WidgetTester tester) => tester.widget<GestureDetector>(
          find.descendant(
            of: find.byType(CriticalGestureDetector),
            matching: find.byType(GestureDetector),
          ),
        );

    testWidgets('single-tap mode: a single tap fires onAction', (tester) async {
      var fired = 0;
      await tester.pumpWidget(host(true, () => fired++));
      await tester.tap(find.text('x'));
      await tester.pump();
      expect(fired, 1);
    });

    testWidgets('single-tap mode: a reflexive double tap fires only once',
        (tester) async {
      var fired = 0;
      await tester.pumpWidget(host(true, () => fired++));
      // Two taps in immediate succession (wall-clock gap << 300ms debounce).
      await tester.tap(find.text('x'));
      await tester.tap(find.text('x'));
      await tester.pump();
      expect(fired, 1, reason: 'second tap within the window is debounced');
    });

    testWidgets('single-tap mode: only onTap is wired', (tester) async {
      await tester.pumpWidget(host(true, () {}));
      final gd = findGd(tester);
      expect(gd.onTap, isNotNull);
      expect(gd.onDoubleTap, isNull);
    });

    testWidgets(
        'double-tap mode: only onDoubleTap is wired and it fires the action',
        (tester) async {
      var fired = 0;
      await tester.pumpWidget(host(false, () => fired++));
      final gd = findGd(tester);
      // No onTap => a single tap cannot fire the critical action.
      expect(gd.onTap, isNull);
      expect(gd.onDoubleTap, isNotNull);
      gd.onDoubleTap!();
      expect(fired, 1);
    });

    testWidgets('onLongPress fires in both modes', (tester) async {
      for (final single in [true, false]) {
        var longPressed = 0;
        await tester.pumpWidget(
            host(single, () {}, onLongPress: () => longPressed++));
        await tester.longPress(find.text('x'));
        await tester.pump();
        expect(longPressed, 1, reason: 'singleTap=$single');
      }
    });
  });

  group('CriticalButton (ElevatedButton-backed)', () {
    Widget host(bool single, VoidCallback onAction) {
      return MaterialApp(
        home: Scaffold(
          body: CriticalButton(
            singleTap: single,
            onAction: onAction,
            child: const Text('go'),
          ),
        ),
      );
    }

    testWidgets('single-tap mode: a single tap fires (not swallowed by button)',
        (tester) async {
      var fired = 0;
      await tester.pumpWidget(host(true, () => fired++));
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(fired, 1);
    });

    testWidgets('single-tap mode: a reflexive double tap fires only once',
        (tester) async {
      var fired = 0;
      await tester.pumpWidget(host(true, () => fired++));
      await tester.tap(find.text('go'));
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(fired, 1, reason: 'second tap within the window is debounced');
    });

    testWidgets('double-tap mode: button press is a no-op; double tap fires',
        (tester) async {
      var fired = 0;
      await tester.pumpWidget(host(false, () => fired++));

      // The button stays enabled but its press is a no-op, so a single tap
      // cannot fire the critical action.
      final btn = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(btn.onPressed, isNotNull);
      btn.onPressed!();
      expect(fired, 0, reason: 'a single button press must not fire the action');

      // The action is bound to the parent GestureDetector's double tap.
      final gd = tester.widget<GestureDetector>(
        find
            .ancestor(
              of: find.byType(ElevatedButton),
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      expect(gd.onDoubleTap, isNotNull);
      gd.onDoubleTap!();
      expect(fired, 1);
    });
  });
}
