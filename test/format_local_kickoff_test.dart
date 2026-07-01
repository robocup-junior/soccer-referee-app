// test/format_local_kickoff_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/screens/home.dart';

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

  test('indexes the month and weekday tables correctly across the year', () {
    // First and last months exercise the table bounds (weekday-1 / month-1).
    expect(formatLocalKickoff(DateTime(2026, 1, 5, 0, 0)), contains('5 Jan'));
    final dec = formatLocalKickoff(DateTime(2026, 12, 25, 23, 59));
    expect(dec, contains('25 Dec'));
    expect(dec, endsWith('23:59'));
  });
}
