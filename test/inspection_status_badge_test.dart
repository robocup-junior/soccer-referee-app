// test/inspection_status_badge_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/widgets/inspection_status_badge.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('ok renders a green "cleared" badge', (tester) async {
    await tester.pumpWidget(
        wrap(const InspectionStatusBadge(status: InspectionStatus.ok)));
    expect(find.text('cleared'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('failed renders a red "failed" badge', (tester) async {
    await tester.pumpWidget(
        wrap(const InspectionStatusBadge(status: InspectionStatus.failed)));
    expect(find.text('failed'), findsOneWidget);
    expect(find.byIcon(Icons.cancel), findsOneWidget);
  });

  testWidgets('missing and unknown render a neutral dash, never a warning',
      (tester) async {
    for (final s in [InspectionStatus.missing, InspectionStatus.unknown]) {
      await tester.pumpWidget(wrap(InspectionStatusBadge(status: s)));
      // Neutral: a dash, no status word, no colored status icon.
      expect(find.text('—'), findsOneWidget);
      expect(find.text('cleared'), findsNothing);
      expect(find.text('failed'), findsNothing);
      expect(find.byIcon(Icons.check_circle), findsNothing);
      expect(find.byIcon(Icons.cancel), findsNothing);
    }
  });
}
