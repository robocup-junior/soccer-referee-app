// Widget tests for the single-tap/double-tap critical control widgets (issue
// #12): CriticalGestureDetector (non-button sites), CriticalButton
// (ElevatedButton-backed sites), and the TapDebounce guard that makes a
// reflexive double-tap fire a single-tap action only once.

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

    testWidgets('single-tap mode: a reflexive double tap fires only once',
        (tester) async {
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
      // Two taps in immediate succession (wall-clock gap << 300ms debounce).
      await tester.tap(find.text('x'));
      await tester.tap(find.text('x'));
      await tester.pump();
      expect(fired, 1, reason: 'second tap within the window is debounced');
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

      await tester.tap(find.text('x'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(fired, 0, reason: 'single tap must not fire in double-tap mode');

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

    testWidgets('double-tap mode: a double tap fires, a single tap does not',
        (tester) async {
      var fired = 0;
      await tester.pumpWidget(host(false, () => fired++));

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
