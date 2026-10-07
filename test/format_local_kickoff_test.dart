// test/format_local_kickoff_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/utils/format.dart';

void main() {
  test('null scheduledStart -> null (line omitted)', () {
    expect(formatLocalKickoff(null), isNull);
  });

  test('formats weekday/day/month with zero-padded hh:mm', () {
    // A *local* DateTime, so toLocal() is a no-op and the result is
    // deterministic regardless of the test machine's timezone. 2026-07-01 is a
    // Wednesday; single-digit hour/minute must zero-pad.
    expect(formatLocalKickoff(DateTime(2026, 7, 1, 9, 5)), 'Wed 1 Jul · 09:05');
  });
}
