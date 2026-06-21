// Widget tests for the single-tap/double-tap gesture wrapper (issue #12):
// CriticalGestureDetector (non-button sites) and criticalButtonGestures
// (ElevatedButton-backed sites).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rcj_scoreboard/widgets/critical_gesture_detector.dart';

void main() {
  group('CriticalGestureDetector (non-button)', () {
    testWidgets('single-tap mode: a single tap fires onAction', (tester) async {
      var fired = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CriticalGestureDetector(
            singleTap: true,
            onAction: () => fired++,
            child: const SizedBox(width: 200, height: 200, child: Text('x')),
          ),
        ),
      ));
      await tester.tap(find.text('x'));
      await tester.pump();
      expect(fired, 1);
    });

    testWidgets('double-tap mode: a double tap fires, a single tap does not',
        (tester) async {
      var fired = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CriticalGestureDetector(
            singleTap: false,
            onAction: () => fired++,
            child: const SizedBox(width: 200, height: 200, child: Text('x')),
          ),
        ),
      ));

      // A lone tap must not trigger the action.
      await tester.tap(find.text('x'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(fired, 0, reason: 'single tap must not fire in double-tap mode');

      // A double tap (two taps within the recognizer window) does.
      await tester.tap(find.text('x'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('x'));
      await tester.pump();
      expect(fired, 1);
    });

    testWidgets('onLongPress fires in both modes', (tester) async {
      for (final single in [true, false]) {
        var longPressed = 0;
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: CriticalGestureDetector(
              singleTap: single,
              onAction: () {},
              onLongPress: () => longPressed++,
              child: const SizedBox(width: 200, height: 200, child: Text('x')),
            ),
          ),
        ));
        await tester.longPress(find.text('x'));
        await tester.pump();
        expect(longPressed, 1, reason: 'singleTap=$single');
      }
    });
  });

  group('criticalButtonGestures (ElevatedButton-backed)', () {
    // Builds the same GestureDetector+ElevatedButton shape used by the timer and
    // all-robots controls in home.dart.
    Widget buildButton(bool single, VoidCallback onAction) {
      final g = criticalButtonGestures(singleTap: single, onAction: onAction);
      return MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            onDoubleTap: g.onDoubleTap,
            child: ElevatedButton(
              onPressed: g.onPressed,
              child: const Text('go'),
            ),
          ),
        ),
      );
    }

    testWidgets('single-tap mode: a single tap fires (not swallowed by button)',
        (tester) async {
      var fired = 0;
      await tester.pumpWidget(buildButton(true, () => fired++));
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(fired, 1);
    });

    testWidgets('double-tap mode: a double tap fires, a single tap does not',
        (tester) async {
      var fired = 0;
      await tester.pumpWidget(buildButton(false, () => fired++));

      await tester.tap(find.text('go'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(fired, 0, reason: 'single tap must not fire in double-tap mode');

      await tester.tap(find.text('go'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(fired, 1);
    });
  });
}
