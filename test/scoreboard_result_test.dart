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
        'home_team': {'name': 'Home'},
        'away_team': {'name': 'Away'},
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
        retryCount: 2,
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
      expect(decoded.retryCount, item.retryCount);
      expect(decoded.state, ResultSubmissionState.pending);
    });

    test('defaults retry_count to zero for old payloads', () {
      final decoded = ResultOutboxItem.fromJson({
        'id': 'id-legacy',
        'base_url': 'https://scoreboard.junior.robocup.org',
        'token': 'selector.secret',
        'match_code': 'M-2',
        'home_goals': 1,
        'away_goals': 0,
        'version': 1,
        'idempotency_key': 'idem-legacy',
        'state': 'pending',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      expect(decoded.retryCount, 0);
    });
  });

  group('ResultOutboxItem.copyWith clearing', () {
    final now = DateTime.now().toUtc();
    ResultOutboxItem failedItem() => ResultOutboxItem(
          id: 'id-1',
          baseUrl: 'https://scoreboard.junior.robocup.org',
          token: 'selector.secret',
          matchCode: 'M-1',
          homeGoals: 2,
          awayGoals: 1,
          version: 5,
          idempotencyKey: 'idem-1',
          retryCount: 5,
          state: ResultSubmissionState.failed,
          responseStatus: 500,
          responseBody: const {'reason': 'boom'},
          errorMessage: 'temporary_error_500',
          createdAt: now,
          updatedAt: now,
        );

    test('clearError nulls the error on a successful submit', () {
      final submitted = failedItem().copyWith(
        state: ResultSubmissionState.submitted,
        responseStatus: 200,
        clearError: true,
      );
      expect(submitted.errorMessage, isNull);
      expect(submitted.responseStatus, 200);
    });

    test('clearResponse + clearError wipe stale failure details on revival', () {
      final revived = failedItem().copyWith(
        state: ResultSubmissionState.pending,
        retryCount: 0,
        clearError: true,
        clearResponse: true,
      );
      expect(revived.state, ResultSubmissionState.pending);
      expect(revived.retryCount, 0);
      expect(revived.errorMessage, isNull);
      expect(revived.responseStatus, isNull);
      expect(revived.responseBody, isNull);
    });

    test('without clear flags, existing fields are preserved', () {
      final updated = failedItem().copyWith(retryCount: 1);
      expect(updated.errorMessage, 'temporary_error_500');
      expect(updated.responseStatus, 500);
      expect(updated.responseBody, isNotNull);
    });
  });
}
