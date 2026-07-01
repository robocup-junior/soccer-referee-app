import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/widgets/scrolling_status_text.dart';

// Wraps the widget in a fixed-width box so we control whether the text overflows.
Widget _host({required double width, required String text}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox(
        width: width,
        child: ScrollingStatusText(
          text: text,
          style: const TextStyle(fontSize: 12),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders a single static copy when the text fits', (tester) async {
    await tester.pumpWidget(_host(width: 400, text: 'Awaiting link'));
    await tester.pump();

    // Fits -> exactly one Text with the message, no marquee duplicate.
    expect(find.text('Awaiting link'), findsOneWidget);
    // No looping animation scheduled, so the tree settles.
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('scrolls (two copies) when the text overflows', (tester) async {
    await tester.pumpWidget(
      _host(width: 40, text: 'Final result requires manual review and more'),
    );
    // Let the post-frame callback start the marquee.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // Overflow path renders the text twice for a seamless wrap...
    expect(
      find.text('Final result requires manual review and more'),
      findsNWidgets(2),
    );
    // ...and the marquee is animating.
    expect(tester.hasRunningAnimations, isTrue);
  });

  testWidgets('switching from long to short text stops the animation',
      (tester) async {
    await tester.pumpWidget(_host(width: 40, text: 'A very long status message'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.hasRunningAnimations, isTrue);

    await tester.pumpWidget(_host(width: 400, text: 'No link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('No link'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
