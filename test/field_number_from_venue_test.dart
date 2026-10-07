// Unit tests for the shared venue->field-number rule (#50). Both the catigoal
// path (Match.fromJson) and the scoreboard referee-link path
// (Game._applyScoreboardMatchConfig) depend on this single helper, so it gets
// its own test home.

import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/services/match_data.dart';

void main() {
  test('strips leading zeros', () {
    expect(fieldNumberFromVenue('Field 03'), '3');
    expect(fieldNumberFromVenue('007'), '7');
  });

  test('a zero-only venue yields empty (RCJ fields start at 1)', () {
    expect(fieldNumberFromVenue('Field 0'), '');
  });
}
