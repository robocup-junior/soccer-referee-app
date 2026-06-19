import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/models/scoreboard_result.dart';

void main() {
  group('ScoreboardMatchConfig parsing', () {
    test('parses full payload with home_side', () {
      final config = ScoreboardMatchConfig.fromJson({
        'match_code': 'M-12',
        'home_team': {'name': 'Blue'},
        'away_team': {'name': 'Red'},
        'home_side': 'right',
        'venue': 'Field 1',
        'scheduled_start': '2026-06-20T10:00:00Z',
        'duration_seconds': 480,
        'timezone': 'Europe/Prague',
        'version': 7,
        'status': 'scheduled',
      });

      expect(config.matchCode, 'M-12');
      expect(config.homeTeamName, 'Blue');
      expect(config.awayTeamName, 'Red');
      expect(config.homeIsLeft, isFalse);
      expect(config.durationSeconds, 480);
      expect(config.version, 7);
      expect(config.status, 'SCHEDULED');
    });

    test('falls back to side_order map and defaults', () {
      final config = ScoreboardMatchConfig.fromJson({
        'home_team': 'Home',
        'away_team': 'Away',
        'side_order': {'home': 'left'},
      });

      expect(config.homeIsLeft, isTrue);
      expect(config.durationSeconds, 600);
      expect(config.version, 0);
      expect(config.timezone, 'UTC');
    });
  });

  group('ResultOutboxItem serialization', () {
    test('roundtrips json payload', () {
      final now = DateTime.now().toUtc();
      final item = ResultOutboxItem(
        id: 'id-1',
        baseUrl: 'https://scoreboard.junior.robocup.org',
        token: 'selector.secret',
        matchCode: 'M-1',
        homeGoals: 3,
        awayGoals: 2,
        version: 5,
        idempotencyKey: 'idem-1',
        comment: 'via app',
        state: ResultSubmissionState.pending,
        responseStatus: null,
        responseBody: null,
        errorMessage: null,
        createdAt: now,
        updatedAt: now,
      );

      final decoded = ResultOutboxItem.fromJson(item.toJson());
      expect(decoded.id, item.id);
      expect(decoded.matchCode, item.matchCode);
      expect(decoded.homeGoals, item.homeGoals);
      expect(decoded.awayGoals, item.awayGoals);
      expect(decoded.idempotencyKey, item.idempotencyKey);
      expect(decoded.state, ResultSubmissionState.pending);
    });
  });
}
