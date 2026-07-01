import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/services/scoreboard_result_service.dart';

class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this.handler);

  final FutureOr<http.Response> Function(http.BaseRequest request) handler;
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final response = await handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([response.bodyBytes]),
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
      request: request,
    );
  }
}

Map<String, dynamic> _matchJson({
  String matchCode = 'M-1',
  int version = 5,
}) =>
    {
      'match_code': matchCode,
      'home_team': {'name': 'Blue'},
      'away_team': {'name': 'Red'},
      'home_is_left': true,
      'venue': '1',
      'duration_seconds': 600,
      'timezone': 'Europe/Prague',
      'version': version,
      'status': 'SCHEDULED',
      'home_inspection_robots': const [],
      'away_inspection_robots': const [],
    };

Future<void> _waitFor(
  bool Function() condition, {
  String reason = 'condition was not met',
}) async {
  for (var i = 0; i < 20; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail(reason);
}

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

    test('parses per-robot inspection status and notes, in order', () {
      final config = ScoreboardMatchConfig.fromJson({
        ..._matchJson(),
        'home_inspection_robots': const [
          {'robot': 1, 'status': 'ok', 'note': ''},
        ],
        'away_inspection_robots': const [
          {'robot': 1, 'status': 'failed', 'note': 'battery low'},
          {'robot': 2, 'status': 'ok', 'note': 'wheels re-seated'},
        ],
      });

      expect(config.homeInspectionRobots, const [
        InspectionRobot(robot: 1, status: InspectionStatus.ok, note: ''),
      ]);
      expect(config.awayInspectionRobots, const [
        InspectionRobot(
            robot: 1, status: InspectionStatus.failed, note: 'battery low'),
        InspectionRobot(
            robot: 2, status: InspectionStatus.ok, note: 'wheels re-seated'),
      ]);
    });

    test('absent robots -> empty; garbage status -> unknown', () {
      final absent = ScoreboardMatchConfig.fromJson(_matchJson()
        ..remove('home_inspection_robots')
        ..remove('away_inspection_robots'));
      expect(absent.homeInspectionRobots, isEmpty);
      expect(absent.awayInspectionRobots, isEmpty);

      final garbage = ScoreboardMatchConfig.fromJson({
        ..._matchJson(),
        'home_inspection_robots': const [
          {'robot': 1, 'status': 'exploded', 'note': ''},
        ],
      });
      expect(
          garbage.homeInspectionRobots.single.status, InspectionStatus.unknown);
    });

    test('robot id parses from int, float and string; bad rows dropped', () {
      final config = ScoreboardMatchConfig.fromJson({
        ..._matchJson(),
        'home_inspection_robots': const [
          {'robot': 1, 'status': 'ok', 'note': ''}, // int
          {'robot': 3.0, 'status': 'ok', 'note': ''}, // float -> 3
          {'robot': '2', 'status': 'failed', 'note': 'x'}, // string -> 2
          {'robot': 0, 'status': 'ok', 'note': ''}, // non-positive -> dropped
          {'robot': 'nope', 'status': 'ok', 'note': ''}, // unparseable -> dropped
          'not-a-map', // dropped
        ],
        'away_inspection_robots': 'not-a-list',
      });
      expect(config.homeInspectionRobots.map((r) => r.robot), [1, 3, 2]);
      expect(config.awayInspectionRobots, isEmpty);
    });

    test('robot note is trimmed; status normalizes case + whitespace', () {
      final config = ScoreboardMatchConfig.fromJson({
        ..._matchJson(),
        'home_inspection_robots': const [
          {'robot': 1, 'status': 'OK', 'note': '  spaced out  '},
          {'robot': 2, 'status': ' Failed ', 'note': '   '},
        ],
      });
      expect(config.homeInspectionRobots[0].status, InspectionStatus.ok);
      expect(config.homeInspectionRobots[0].note, 'spaced out');
      expect(config.homeInspectionRobots[1].status, InspectionStatus.failed);
      expect(config.homeInspectionRobots[1].note, '');
    });

    test('per-robot inspection survives a toJson/fromJson round-trip', () {
      final original = ScoreboardMatchConfig.fromJson({
        ..._matchJson(),
        'home_inspection_robots': const [
          {'robot': 2, 'status': 'failed', 'note': 'loose wiring'},
        ],
        'away_inspection_robots': const [],
      });

      final restored = ScoreboardMatchConfig.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.homeInspectionRobots, const [
        InspectionRobot(
            robot: 2, status: InspectionStatus.failed, note: 'loose wiring'),
      ]);
      expect(restored.awayInspectionRobots, isEmpty);
    });

    test('inspection is not part of the load signature', () {
      final base = ScoreboardMatchConfig.fromJson(_matchJson());
      final flipped = base.copyWith(
        homeInspectionRobots: const [
          InspectionRobot(robot: 1, status: InspectionStatus.failed, note: 'x'),
        ],
      );
      // Inspection state is cosmetic: a change must not re-fire the
      // confirm-on-load / apply-dedupe logic keyed on `signature`.
      expect(flipped.signature, base.signature);
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

    test('signature does not collide for separator-containing team names', () {
      final a = ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M'))
          .copyWith(homeTeamName: 'A:B', awayTeamName: 'C');
      final b = ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M'))
          .copyWith(homeTeamName: 'A', awayTeamName: 'B:C');
      expect(a.signature, isNot(b.signature),
          reason: 'a colon in a team name must not alias a different fixture');
    });

    test('parses per-side module MACs, normalising to upper-case', () {
      final config = ScoreboardMatchConfig.fromJson({
        ..._matchJson(),
        'home_module_macs': ['a1:b2:c3:d4:e5:f6', '11:22:33:44:55:66'],
        'away_module_macs': ['aa:bb:cc:dd:ee:ff'],
      });

      expect(config.homeModuleMacs, ['A1:B2:C3:D4:E5:F6', '11:22:33:44:55:66']);
      expect(config.awayModuleMacs, ['AA:BB:CC:DD:EE:FF']);
    });

    test('defaults module MACs to empty lists for payloads without them', () {
      final config = ScoreboardMatchConfig.fromJson(_matchJson());

      expect(config.homeModuleMacs, isEmpty);
      expect(config.awayModuleMacs, isEmpty);
    });

    test('drops blank/whitespace MAC entries', () {
      final config = ScoreboardMatchConfig.fromJson({
        ..._matchJson(),
        'home_module_macs': ['A1:B2:C3:D4:E5:F6', '', '   '],
      });

      expect(config.homeModuleMacs, ['A1:B2:C3:D4:E5:F6']);
    });

    test('toJson/fromJson round-trips module MACs so a cold resume keeps them',
        () {
      final config = ScoreboardMatchConfig.fromJson({
        ..._matchJson(),
        'home_module_macs': ['A1:B2:C3:D4:E5:F6'],
        'away_module_macs': ['AA:BB:CC:DD:EE:FF'],
      });

      final restored = ScoreboardMatchConfig.fromJson(config.toJson());

      expect(restored.homeModuleMacs, ['A1:B2:C3:D4:E5:F6']);
      expect(restored.awayModuleMacs, ['AA:BB:CC:DD:EE:FF']);
    });

    test('parses inspection robots (status + note per robot)', () {
      final config = ScoreboardMatchConfig.fromJson({
        ..._matchJson(),
        'home_inspection_robots': const [
          {'robot': 1, 'status': 'ok', 'note': ''},
          {'robot': 2, 'status': 'failed', 'note': 'battery below spec'},
        ],
        'away_inspection_robots': const [
          {'robot': 1, 'status': 'missing', 'note': ''},
        ],
      });

      expect(config.homeInspectionRobots, const [
        InspectionRobot(robot: 1, status: InspectionStatus.ok, note: ''),
        InspectionRobot(
            robot: 2, status: InspectionStatus.failed, note: 'battery below spec'),
      ]);
      expect(config.awayInspectionRobots, const [
        InspectionRobot(robot: 1, status: InspectionStatus.missing, note: ''),
      ]);
    });

    test('inspection robots parsing is total (drops malformed/invalid robot)', () {
      final config = ScoreboardMatchConfig.fromJson({
        ..._matchJson(),
        'home_inspection_robots': const [
          {'robot': 1, 'status': 'ok', 'note': ''},
          {'robot': 'x', 'status': 'ok', 'note': 'bad id'},
          {'robot': 0, 'status': 'ok', 'note': 'zero'},
          'not-a-map',
        ],
        'away_inspection_robots': 'not-a-list',
      });
      expect(config.homeInspectionRobots,
          const [InspectionRobot(robot: 1, status: InspectionStatus.ok, note: '')]);
      expect(config.awayInspectionRobots, isEmpty);
    });

    test('inspection robots survive a toJson/fromJson round-trip', () {
      final original = ScoreboardMatchConfig.fromJson({
        ..._matchJson(),
        'home_inspection_robots': const [
          {'robot': 2, 'status': 'failed', 'note': 'loose wiring'},
        ],
      });
      final restored = ScoreboardMatchConfig.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(restored.homeInspectionRobots, const [
        InspectionRobot(
            robot: 2, status: InspectionStatus.failed, note: 'loose wiring'),
      ]);
    });

    test('inspection robots are not part of the load signature', () {
      final base = ScoreboardMatchConfig.fromJson(_matchJson());
      final flipped = base.copyWith(homeInspectionRobots: const [
        InspectionRobot(robot: 1, status: InspectionStatus.failed, note: 'x'),
      ]);
      expect(flipped.signature, base.signature);
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
        homeConfirmed: true,
        awayConfirmed: false,
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
      expect(decoded.homeConfirmed, isTrue);
      expect(decoded.awayConfirmed, isFalse);
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
      expect(decoded.homeConfirmed, isFalse);
      expect(decoded.awayConfirmed, isFalse);
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

    test('clearResponse + clearError wipe stale failure details on revival',
        () {
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

    test('copyWith can update confirmations', () {
      final updated = failedItem().copyWith(
        homeConfirmed: true,
        awayConfirmed: true,
      );
      expect(updated.homeConfirmed, isTrue);
      expect(updated.awayConfirmed, isTrue);
    });
  });

  group('ScoreboardResultService staging', () {
    test('handleDeepLink fetches pending config without committing token',
        () async {
      final client = _FakeHttpClient((request) {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/soccer/match/');
        return http.Response(
            jsonEncode(_matchJson(matchCode: 'M-PENDING')), 200);
      });
      final service = ScoreboardResultService(httpClient: client);

      await service.handleDeepLink(Uri(
        scheme: 'rcjrefmate',
        host: 'r',
        pathSegments: ['fresh-token'],
        queryParameters: {'base_url': 'http://127.0.0.1:8080'},
      ));

      expect(service.pendingMatchConfig?.matchCode, 'M-PENDING');
      expect(service.matchConfig, isNull);
      expect(service.hasToken, isFalse);
      expect(service.statusMessage, 'Confirm to load match');

      await service.confirmPendingMatch();
      expect(service.pendingMatchConfig, isNull);
      expect(service.matchConfig?.matchCode, 'M-PENDING');
      expect(service.hasToken, isTrue);
      expect(service.statusMessage, 'Match loaded');
    });

    test('cancelPendingMatch preserves committed match', () {
      final service = ScoreboardResultService(
          httpClient: _FakeHttpClient(
        (_) => http.Response('{}', 500),
      ));
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-COMMITTED')),
        token: 'old-token',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );
      service.debugApplyPendingMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-PENDING')),
        token: 'new-token',
        baseUri: Uri.parse('http://127.0.0.1:8081'),
      );

      service.cancelPendingMatch();

      expect(service.pendingMatchConfig, isNull);
      expect(service.matchConfig?.matchCode, 'M-COMMITTED');
      expect(service.hasToken, isTrue);
      expect(service.statusMessage, 'Match loaded');
    });

    test('confirmPendingMatch ignores a stale dialog signature', () async {
      final service = ScoreboardResultService(
          httpClient: _FakeHttpClient((_) => http.Response('{}', 500)));
      // A first link is staged, then a second link replaces it before the
      // (stale) first dialog's Load is tapped.
      final firstPending =
          ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-A'));
      service.debugApplyPendingMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-B')),
        token: 'token-b',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );

      await service.confirmPendingMatch(
          expectedSignature: firstPending.signature);

      // The stale Load must not commit the newer pending match.
      expect(service.matchConfig, isNull);
      expect(service.pendingMatchConfig?.matchCode, 'M-B');
    });

    test('cancelPendingMatch keeps a newer pending link on a stale signature',
        () {
      final service = ScoreboardResultService(
          httpClient: _FakeHttpClient((_) => http.Response('{}', 500)));
      final firstPending =
          ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-A'));
      service.debugApplyPendingMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-B')),
        token: 'token-b',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );

      service.cancelPendingMatch(expectedSignature: firstPending.signature);

      // A stale Cancel must not discard the newer staged link.
      expect(service.pendingMatchConfig?.matchCode, 'M-B');
    });
  });

  group('ScoreboardResultService submission', () {
    test('sends confirmations and keeps linked match after success', () async {
      String? postBody;
      final client = _FakeHttpClient((request) {
        expect(request.method, 'POST');
        if (request is http.Request) {
          postBody = request.body;
        }
        return http.Response(jsonEncode({'version': 6}), 200);
      });
      final service = ScoreboardResultService(httpClient: client);
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-SUBMIT')),
        token: 'token',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );

      final queued = await service.enqueueFinalResult(
        homeGoals: 4,
        awayGoals: 3,
        comment: 'checked',
        homeConfirmed: true,
        awayConfirmed: false,
      );

      expect(queued, isTrue);
      expect(service.outbox.single.homeConfirmed, isTrue);
      expect(service.outbox.single.awayConfirmed, isFalse);

      await _waitFor(() => postBody != null, reason: 'POST was not sent');
      final payload = jsonDecode(postBody!) as Map<String, dynamic>;
      expect(payload['home_goals'], 4);
      expect(payload['away_goals'], 3);
      expect(payload['home_confirmed'], isTrue);
      expect(payload['away_confirmed'], isFalse);
      expect(payload['comment'], 'checked');

      await _waitFor(
        () => service.outbox.single.state == ResultSubmissionState.submitted,
        reason: 'submission did not finish',
      );
      expect(service.matchConfig?.matchCode, 'M-SUBMIT');
      expect(service.hasToken, isTrue);
      expect(service.hasResultFor('M-SUBMIT'), isTrue);
      expect(service.statusMessage, '✓ Submitted M-SUBMIT');
    });

    test('submitted confirmation survives a later config refresh', () async {
      String? postBody;
      final client = _FakeHttpClient((request) {
        if (request.method == 'POST') {
          if (request is http.Request) postBody = request.body;
          return http.Response(jsonEncode({'version': 6}), 200);
        }
        // A subsequent GET refresh of the same match.
        return http.Response(jsonEncode(_matchJson(matchCode: 'M-KEEP')), 200);
      });
      final service = ScoreboardResultService(httpClient: client);
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-KEEP')),
        token: 'token',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );

      await service.enqueueFinalResult(homeGoals: 1, awayGoals: 0);
      await _waitFor(() => postBody != null, reason: 'POST was not sent');
      await _waitFor(
        () => service.outbox.single.state == ResultSubmissionState.submitted,
        reason: 'submission did not finish',
      );
      expect(service.statusMessage, '✓ Submitted M-KEEP');

      // A refresh of the linked match must not make a delivered result look
      // un-sent (Part C of #51).
      await service.refreshMatchConfig();
      expect(service.statusMessage, '✓ Submitted M-KEEP');
    });

    test(
        'a terminal 401 rejection unblocks the review for a re-submit '
        '(RAVF002)', () async {
      final client = _FakeHttpClient(
          (request) => http.Response(jsonEncode({'reason': 'bad token'}), 401));
      final service = ScoreboardResultService(httpClient: client);
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-401')),
        token: 'token',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );

      await service.enqueueFinalResult(homeGoals: 1, awayGoals: 0);
      await _waitFor(
        () =>
            service.outbox.single.state == ResultSubmissionState.failed &&
            service.outbox.single.responseStatus == 401,
        reason: 'the 401 did not mark the item terminally failed',
      );

      // hasResultFor still sees the item (audit trail), but the review gate
      // (hasUnresolvedResultFor) treats a terminal rejection as correctable, so
      // the referee gets the Submit affordance back.
      expect(service.hasResultFor('M-401'), isTrue);
      expect(service.hasUnresolvedResultFor('M-401'), isFalse);

      // A fresh enqueue is accepted (a corrected, second attempt).
      final reSubmitted =
          await service.enqueueFinalResult(homeGoals: 2, awayGoals: 0);
      expect(reSubmitted, isTrue);
    });

    test('a 409 conflict keeps the review blocked (RAVF002)', () async {
      final client = _FakeHttpClient((request) =>
          http.Response(jsonEncode({'reason': 'already recorded'}), 409));
      final service = ScoreboardResultService(httpClient: client);
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-409')),
        token: 'token',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );

      await service.enqueueFinalResult(homeGoals: 1, awayGoals: 0);
      await _waitFor(
        () => service.outbox.single.state == ResultSubmissionState.conflict,
        reason: 'the 409 did not record a conflict',
      );

      // A conflict is a terminal SERVER state the referee can't correct by
      // re-submitting, so it must keep blocking the review.
      expect(service.hasUnresolvedResultFor('M-409'), isTrue);
    });

    test('cancelling a staged link keeps a prior submitted confirmation',
        () async {
      final client = _FakeHttpClient((request) {
        if (request.method == 'POST') {
          return http.Response(jsonEncode({'version': 6}), 200);
        }
        return http.Response('{}', 500);
      });
      final service = ScoreboardResultService(httpClient: client);
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-DONE')),
        token: 'token',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );
      await service.enqueueFinalResult(homeGoals: 2, awayGoals: 1);
      await _waitFor(() => service.statusMessage == '✓ Submitted M-DONE',
          reason: 'submit did not confirm');

      // Referee mistakenly scans another link then cancels it.
      service.debugApplyPendingMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-OTHER')),
        token: 'other',
        baseUri: Uri.parse('http://127.0.0.1:8081'),
      );
      service.cancelPendingMatch();

      expect(service.matchConfig?.matchCode, 'M-DONE');
      expect(service.statusMessage, '✓ Submitted M-DONE');
    });

    test('a late POST for an old match does not mutate the newly loaded match',
        () async {
      final postGate = Completer<void>();
      final client = _FakeHttpClient((request) async {
        if (request.method == 'POST') {
          await postGate.future;
          return http.Response(jsonEncode({'version': 99}), 200);
        }
        return http.Response('{}', 500);
      });
      final service = ScoreboardResultService(httpClient: client);
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
            _matchJson(matchCode: 'M-A', version: 1)),
        token: 'token-a',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );
      await service.enqueueFinalResult(homeGoals: 1, awayGoals: 0);

      // A's POST is now in flight (blocked on the gate). Load a DIFFERENT match.
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
            _matchJson(matchCode: 'M-B', version: 2)),
        token: 'token-b',
        baseUri: Uri.parse('http://127.0.0.1:8081'),
      );
      expect(service.matchConfig?.matchCode, 'M-B');

      // Release A's response; it must not stamp B with A's version/COMPLETED.
      postGate.complete();
      await _waitFor(
        () => service.outbox.any((i) =>
            i.matchCode == 'M-A' && i.state == ResultSubmissionState.submitted),
        reason: 'A submission did not finish',
      );
      expect(service.matchConfig?.matchCode, 'M-B');
      expect(service.matchConfig?.version, 2,
          reason: "B's version must be untouched by A's response");
      expect(service.matchConfig?.status, isNot('COMPLETED'));
    });

    test('a late POST for an old REVISION does not stamp the current revision',
        () async {
      final postGate = Completer<void>();
      final client = _FakeHttpClient((request) async {
        if (request.method == 'POST') {
          await postGate.future;
          return http.Response(jsonEncode({'version': 99}), 200);
        }
        return http.Response('{}', 500);
      });
      final service = ScoreboardResultService(httpClient: client);
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
            _matchJson(matchCode: 'M-R', version: 1)),
        token: 't',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );
      await service.enqueueFinalResult(homeGoals: 1, awayGoals: 0);

      // The SAME fixture is re-applied at a new revision (organizer edit /
      // refresh) while the v1 POST is still in flight.
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
            _matchJson(matchCode: 'M-R', version: 2)),
        token: 't',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );

      postGate.complete();
      await _waitFor(
        () => service.outbox.single.state == ResultSubmissionState.submitted,
        reason: 'submission did not finish',
      );
      expect(service.matchConfig?.version, 2,
          reason: 'matchCode matches but the revision drifted; do not stamp');
      expect(service.statusMessage, isNot('✓ Submitted M-R'));
    });

    test('a late failure for an old match does not relabel the current match',
        () async {
      final postGate = Completer<void>();
      final client = _FakeHttpClient((request) async {
        if (request.method == 'POST') {
          await postGate.future;
          return http.Response(jsonEncode({'reason': 'late'}), 409);
        }
        return http.Response('{}', 500);
      });
      final service = ScoreboardResultService(httpClient: client);
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-A')),
        token: 'token-a',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );
      await service.enqueueFinalResult(homeGoals: 1, awayGoals: 0);

      // Load a different match while A's POST is in flight.
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-B')),
        token: 'token-b',
        baseUri: Uri.parse('http://127.0.0.1:8081'),
      );

      postGate.complete();
      await _waitFor(
        () => service.outbox.any((i) =>
            i.matchCode == 'M-A' && i.state == ResultSubmissionState.conflict),
        reason: "A's conflict was not recorded",
      );
      // The outbox item is marked conflict, but B's visible status must not read
      // as conflicted because of A's late response.
      expect(service.statusMessage, isNot('Conflict — review'));
    });

    test('a late retriable failure for an old match does not relabel status',
        () async {
      final postGate = Completer<void>();
      final client = _FakeHttpClient((request) async {
        if (request.method == 'POST') {
          await postGate.future;
          return http.Response('{}', 500); // retriable
        }
        return http.Response('{}', 500);
      });
      final service = ScoreboardResultService(httpClient: client);
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-A')),
        token: 'token-a',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );
      await service.enqueueFinalResult(homeGoals: 1, awayGoals: 0);

      // Load a different match while A's POST is in flight.
      service.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-B')),
        token: 'token-b',
        baseUri: Uri.parse('http://127.0.0.1:8081'),
      );

      postGate.complete();
      await _waitFor(
        () =>
            service.outbox.any((i) => i.matchCode == 'M-A' && i.retryCount > 0),
        reason: "A's retriable failure was not recorded",
      );
      // A's late 500 bumps its retry count, but must not relabel B's status.
      expect(service.statusMessage, isNot(startsWith('Will retry')));
      expect(service.statusMessage, isNot(startsWith('Sync failed')));
    });

    test('cancel does not drop a newer link whose fetch is still in flight',
        () async {
      final gate = Completer<http.Response>();
      final client = _FakeHttpClient((_) => gate.future); // GET hangs
      final service = ScoreboardResultService(httpClient: client);

      // Link A is already staged (dialog A would be open).
      service.debugApplyPendingMatchConfig(
        ScoreboardMatchConfig.fromJson(_matchJson(matchCode: 'M-A')),
        token: 'token-a',
        baseUri: Uri.parse('http://127.0.0.1:8080'),
      );
      final sigA = service.pendingMatchConfig!.signature;

      // Link B arrives: pending token/base become B, pending config goes null
      // while B's GET is in flight (hanging on the gate).
      unawaited(service.handleDeepLink(Uri(
        scheme: 'rcjrefmate',
        host: 'r',
        pathSegments: ['token-b'],
        queryParameters: {'base_url': 'http://127.0.0.1:8081'},
      )));
      await Future<void>.delayed(Duration.zero);
      expect(service.pendingMatchConfig, isNull, reason: "B's fetch in flight");

      // A stale Cancel for dialog A must NOT clear B's in-flight pending target.
      service.cancelPendingMatch(expectedSignature: sigA);

      gate.complete(
          http.Response(jsonEncode(_matchJson(matchCode: 'M-B')), 200));
      await _waitFor(() => service.pendingMatchConfig?.matchCode == 'M-B',
          reason: 'B must still surface as pending after a stale cancel');
    });
  });
}
