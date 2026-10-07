// test/inspection_robot_list_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/widgets/inspection_robot_list.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('renders one row per robot with status and note', (tester) async {
    await tester.pumpWidget(wrap(const InspectionRobotList(robots: [
      InspectionRobot(robot: 1, status: InspectionStatus.ok, note: ''),
      InspectionRobot(
          robot: 2,
          status: InspectionStatus.failed,
          note: 'battery below spec'),
    ])));
    expect(find.text('Robot 1'), findsOneWidget);
    expect(find.text('Robot 2'), findsOneWidget);
    expect(find.text('cleared'), findsOneWidget); // ok badge
    expect(find.text('failed'), findsOneWidget); // failed badge
    expect(find.textContaining('battery below spec'), findsOneWidget);
  });
}
