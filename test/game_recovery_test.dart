// Tests for match cold-resume (#45): persistence wiring + restore flow.
//
// Like game_remaining_time_test, these use testWidgets because the Game
// constructor stands up wakelock/notification/MQTT/bridge services whose
// platform-channel calls reject asynchronously in the headless test VM; the
// widget binding tolerates those pending replies. We avoid leaving real Timers
// pending (Timer.periodic from startTimer, and the 100 ms staggered fan-out
// delays) by either not starting the clock or cancelling/draining it before the
// test returns.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/module.dart';
import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/models/team.dart';
import 'package:rcj_scoreboard/services/match_state_store.dart';

ModuleSnapshot _moduleSnap({
  required int id,
  String state = 'stop',
  String lastState = 'stop',
  int penalty = 0,
  bool enabled = true,
  String mac = '',
  String? label,
}) {
  return ModuleSnapshot(
    moduleId: id,
    isEnabled: enabled,
    macAddress: mac,
    customLabel: label,
    state: state,
    lastState: lastState,
    penaltyTime: penalty,
  );
}

Map<String, dynamic> _scoreboardConfig({
  required String matchCode,
  required int version,
  bool homeIsLeft = true,
  int durationSeconds = 600,
  String homeTeamName = 'Home',
  String awayTeamName = 'Away',
}) =>
    {
      'match_code': matchCode,
      'home_team': homeTeamName,
      'away_team': awayTeamName,
      'home_is_left': homeIsLeft,
      'venue': 'Field 1',
      'scheduled_start': null,
      'duration_seconds': durationSeconds,
      'timezone': 'Europe/Prague',
      'version': version,
      'status': 'SCHEDULED',
    };

Future<void> _seedScoreboardPrefs(
  SharedPreferences prefs,
  Map<String, dynamic> config, {
  String? token,
  Uri? baseUri,
}) async {
  await prefs.setString('scoreboard_match_config', jsonEncode(config));
  if (token != null) {
    await prefs.setString('scoreboard_token', token);
  }
  if (baseUri != null) {
    await prefs.setString('scoreboard_base_url', baseUri.toString());
  }
}

Future<void> _seedOutbox(
  SharedPreferences prefs,
  List<ResultOutboxItem> items,
) async {
  await prefs.setString(
    'scoreboard_result_outbox',
    jsonEncode(items.map((item) => item.toJson()).toList()),
  );
}

ResultOutboxItem _outboxItem({
  required String matchCode,
  required ResultSubmissionState state,
  int? responseStatus,
  int homeGoals = 0,
  int awayGoals = 0,
  int version = 1,
}) =>
    ResultOutboxItem(
      id: 'item-$matchCode',
      baseUrl: 'http://127.0.0.1:9',
      token: 'test-token',
      matchCode: matchCode,
      homeGoals: homeGoals,
      awayGoals: awayGoals,
      version: version,
      idempotencyKey: 'idem-$matchCode',
      state: state,
      responseStatus: responseStatus,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

MatchSnapshot _snap({
  String stage = 'firstHalf',
  bool inGame = true,
  int remainingTime = 200,
  int scoreA = 0,
  int scoreB = 0,
  String nameA = 'Team A',
  String nameB = 'Team B',
  List<ModuleSnapshot> modules = const [],
  String firstTeamId = 'A',
  bool isRefereeMatch = false,
  String? scoreboardMatchCode,
  int? scoreboardVersion,
  String? scoreboardHomeTeamId,
  String? scoreboardAwayTeamId,
}) {
  final teamA = TeamSnapshot(id: 'A', name: nameA, score: scoreA);
  final teamB = TeamSnapshot(id: 'B', name: nameB, score: scoreB);
  return MatchSnapshot(
    stage: stage,
    remainingTime: remainingTime,
    isTimeRunning: false,
    inGame: inGame,
    timerButtonText: 'START',
    savedAtMs: 1000,
    isRefereeMatch: isRefereeMatch,
    scoreboardMatchCode: scoreboardMatchCode,
    scoreboardVersion: scoreboardVersion,
    scoreboardHomeTeamId: scoreboardHomeTeamId,
    scoreboardAwayTeamId: scoreboardAwayTeamId,
    teams: firstTeamId == 'A' ? [teamA, teamB] : [teamB, teamA],
    modules: modules,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  Future<void> persist(MatchSnapshot snapshot) async {
    await MatchStateStore(prefs).save(snapshot);
  }

  // Two pumps let the async _loadPrefs() (one getInstance await) finish.
  Future<void> settleLoad(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> settleScoreboardConfig(WidgetTester tester, Game game) async {
    for (var i = 0; i < 20; i++) {
      if (game.scoreboardResultService.matchConfig != null) return;
      await tester.pump(const Duration(milliseconds: 1));
    }
    fail('scoreboard match config did not load');
  }

  Future<MatchSnapshot> waitForSavedSnapshot(
    WidgetTester tester,
    bool Function(MatchSnapshot snapshot) matches,
  ) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump();
      final snapshot = MatchStateStore(prefs).load();
      if (snapshot != null && matches(snapshot)) return snapshot;
    }
    fail('expected saved snapshot was not written');
  }

  Future<ResultOutboxItem> waitForOutboxItem(
    WidgetTester tester,
    Game game,
    String matchCode,
  ) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump();
      final matches = game.scoreboardResultService.outbox
          .where((item) => item.matchCode == matchCode);
      if (matches.isNotEmpty) return matches.first;
    }
    fail('expected final result outbox item was not queued');
  }

  Future<void> expectNoOutboxItem(
    WidgetTester tester,
    Game game,
    String matchCode,
  ) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump();
      final hasMatch = game.scoreboardResultService.outbox
          .any((item) => item.matchCode == matchCode);
      expect(hasMatch, isFalse);
    }
  }

  Future<ResultOutboxItem> submitCurrentReview(
    WidgetTester tester,
    Game game,
    String matchCode,
  ) async {
    final review = game.buildScoreboardResultReview();
    expect(review.matchCode, matchCode);
    final submitted = await game.submitScoreboardResult(
      expectedSignature: review.signature,
      homeGoals: review.homeGoals,
      awayGoals: review.awayGoals,
      comment: null,
      homeConfirmed: false,
      awayConfirmed: false,
    );
    expect(submitted, isTrue);
    return waitForOutboxItem(tester, game, matchCode);
  }

  group('cold-launch detection', () {
    testWidgets('an in-progress snapshot is offered for resume',
        (tester) async {
      await persist(_snap(remainingTime: 200));
      final game = Game();
      await settleLoad(tester);
      expect(game.pendingResume, isNotNull);
      expect(game.pendingResume!.remainingTime, 200);
      game.dispose();
    });

    testWidgets('a fullTime snapshot is NOT offered for resume',
        (tester) async {
      await persist(_snap(stage: 'fullTime'));
      final game = Game();
      await settleLoad(tester);
      expect(game.pendingResume, isNull);
      game.dispose();
    });

    testWidgets('bootstrap gameInit does NOT wipe the on-disk snapshot',
        (tester) async {
      await persist(_snap(remainingTime: 200, scoreA: 3));
      final game = Game();
      await settleLoad(tester);

      final reloaded = MatchStateStore(prefs).load();
      expect(reloaded, isNotNull,
          reason: 'the suppressed bootstrap must not overwrite the snapshot');
      expect(reloaded!.remainingTime, 200);
      expect(reloaded.teams.firstWhere((t) => t.id == 'A').score, 3);
      game.dispose();
    });

    testWidgets('resume callback drains the pending prompt exactly once',
        (tester) async {
      await persist(_snap());
      final game = Game();
      await settleLoad(tester);
      expect(game.pendingResume, isNotNull);

      var fired = 0;
      game.onRequestResumeMatch = () => fired++;
      expect(fired, 1, reason: 'registering after stash should fire once');

      game.onRequestResumeMatch = () => fired++;
      expect(fired, 1, reason: 'a second registration must not re-fire');
      game.dispose();
    });
  });

  group('resumePendingMatch', () {
    testWidgets('freezes the clock at the persisted freeze point (firstHalf)',
        (tester) async {
      await persist(
          _snap(stage: 'firstHalf', remainingTime: 137, scoreA: 2, scoreB: 1));
      final game = Game();
      await settleLoad(tester);

      game.resumePendingMatch();
      await tester.pump();

      expect(game.remainingTime, 137,
          reason: 'no dead-time subtraction on cold resume');
      expect(game.isTimerRunning, isFalse);
      expect(game.currentStage, MatchStage.firstHalf);
      expect(game.getScore('A'), 2);
      expect(game.getScore('B'), 1);
      expect(game.pendingResume, isNull);
      game.dispose();
    });

    testWidgets(
        'normalizes play -> stop for BOTH state and lastState; keeps damage',
        (tester) async {
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 300,
        modules: [
          _moduleSnap(id: 0, state: 'play', lastState: 'play'),
          _moduleSnap(id: 1, state: 'damage', lastState: 'play', penalty: 20),
        ],
      ));
      final game = Game();
      await settleLoad(tester);

      game.resumePendingMatch();
      await tester.pump();

      final m0 = game.teams[0].modules[0];
      final m1 = game.teams[0].modules[1];
      expect(m0.state, ModuleState.stop);
      expect(m0.lastState, ModuleState.stop);
      // damage state preserved, but a `play` lastState is still normalized so
      // single-tap Module.stop() (switches on lastState) isn't a silent no-op.
      expect(m1.state, ModuleState.damage);
      expect(m1.lastState, ModuleState.stop);
      expect(m1.penaltyTime, 20);
      game.dispose();
    });

    testWidgets('referee START clears the per-module restore-notify one-shot',
        (tester) async {
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 300,
        modules: [_moduleSnap(id: 0, state: 'play', lastState: 'play')],
      ));
      final game = Game();
      await settleLoad(tester);

      game.resumePendingMatch();
      await tester.pump();
      final m0 = game.teams[0].modules[0];
      expect(m0.suppressNextRestoreNotify, isTrue,
          reason:
              'armed by restore so a frozen-window reconnect stays stopped');

      // A referee START path must cancel the suppression synchronously, so a
      // LATE reconnect after START reflects the real (playing) state instead of
      // sending a stale STOP.
      m0.playOrDamageAll();
      expect(m0.suppressNextRestoreNotify, isFalse);

      await tester.pump(const Duration(milliseconds: 400)); // drain fan-out
      game.dispose();
    });

    testWidgets('half-time resume keeps the break clock running (not skipped)',
        (tester) async {
      await persist(_snap(stage: 'halfTime', remainingTime: 90));
      final game = Game();
      await settleLoad(tester);

      game.resumePendingMatch();
      await tester.pump();

      expect(game.currentStage, MatchStage.halfTime);
      expect(game.isTimerRunning, isTrue,
          reason: 'break resumes running, not frozen/auto-skipped');
      expect(game.timerButtonText, 'SKIP');
      expect(game.remainingTime, 90);

      game.stopTimer(); // cancel the periodic timer started by the resume
      game.dispose();
    });

    testWidgets('half-time resume does not count down a restored penalty',
        (tester) async {
      // A penalty given during the break is unusual but possible; on resume the
      // break clock runs, so the penalty must NOT count down (and must never
      // auto-release the robot via play()) while off-field at half-time.
      await persist(_snap(
        stage: 'halfTime',
        remainingTime: 60,
        modules: [
          _moduleSnap(id: 0, state: 'damage', lastState: 'damage', penalty: 5),
        ],
      ));
      final game = Game();
      await settleLoad(tester);

      game.resumePendingMatch();
      await tester.pump();
      final m0 = game.teams[0].modules[0];
      expect(m0.state, ModuleState.damage);
      expect(m0.penaltyTime, 5);

      await tester.pump(const Duration(seconds: 1)); // one break tick
      expect(m0.penaltyTime, 5,
          reason: 'penalties must not count down during the half-time break');
      expect(m0.state, ModuleState.damage);

      game.stopTimer();
      game.dispose();
    });

    testWidgets('restores a swapped team order by id, not by index',
        (tester) async {
      // Saved with B on the physical left (teams[0].id == 'B').
      await persist(_snap(
        firstTeamId: 'B',
        scoreA: 1, // Team A (logical) scored 1
        scoreB: 4, // Team B (logical) scored 4
        nameA: 'Alpha',
        nameB: 'Bravo',
      ));
      final game = Game();
      await settleLoad(tester);

      game.resumePendingMatch();
      await tester.pump();

      // Physical left is now B; scores/names land by id regardless of side.
      expect(game.teams[0].id, 'B');
      expect(game.teams[0].name, 'Bravo');
      expect(game.teams[0].score, 4);
      expect(game.getScore('A'), 1);
      expect(game.getScore('B'), 4);
      game.dispose();
    });

    testWidgets('resume re-arms scoreboard binding for final result mapping',
        (tester) async {
      final config = _scoreboardConfig(matchCode: 'M-53', version: 4);
      await _seedScoreboardPrefs(
        prefs,
        config,
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 1,
        scoreA: 2,
        scoreB: 5,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-53',
        scoreboardVersion: 4,
        scoreboardHomeTeamId: 'B',
        scoreboardAwayTeamId: 'A',
      ));
      final game = Game();
      await settleLoad(tester);
      await settleScoreboardConfig(tester, game);

      game.resumePendingMatch();
      // savedAtMs > 1000 proves this is the snapshot RE-SAVED by resume, not the
      // seeded one (savedAtMs == 1000) that already had the binding.
      final saved = await waitForSavedSnapshot(
        tester,
        (snapshot) => snapshot.isRefereeMatch && snapshot.savedAtMs > 1000,
      );
      expect(saved.scoreboardMatchCode, 'M-53');
      expect(saved.scoreboardVersion, 4);
      expect(saved.scoreboardHomeTeamId, 'B');
      expect(saved.scoreboardAwayTeamId, 'A');

      var reviewRequests = 0;
      game.onRequestReviewScoreboardResult = () {
        reviewRequests++;
      };

      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      expect(game.currentStage, MatchStage.fullTime);
      expect(reviewRequests, 1);
      expect(game.needsScoreboardResultReview, isTrue);

      final review = game.buildScoreboardResultReview();
      expect(review.homeGoals, 5,
          reason: 'home score comes from restored team id B');
      expect(review.awayGoals, 2,
          reason: 'away score comes from restored team id A');

      final result = await submitCurrentReview(tester, game, 'M-53');

      expect(result.homeGoals, 5,
          reason: 'home score comes from restored team id B');
      expect(result.awayGoals, 2,
          reason: 'away score comes from restored team id A');
      expect(result.version, 4);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'late config on a suppressed in-game resume applies the venue field (#50)',
        (tester) async {
      // Resume a referee match WHILE its fixture config has not surfaced yet, so
      // the match runs suppressed on the manual/persisted field. When the bound
      // config later arrives, _applyScoreboardMatchConfig re-arms (bypassing the
      // dedupe) and must apply the venue field even though we are inGame — the
      // `if (!inGame) gameInit()` broadcast is skipped on this path.
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 200,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-FLD',
        scoreboardVersion: 1,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      expect(game.scoreboardResultService.matchConfig, isNull);

      game.resumePendingMatch(); // suppressed: no config yet
      // _scoreboardConfig uses venue 'Field 1'.
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-FLD', version: 1),
        ),
        token: 'test-token',
      );
      await tester.pump();

      expect(game.mqttService.topic, 'field_1');
      game.dispose();
    });

    testWidgets('swapped resume keeps scoreboard mapping by stable team id',
        (tester) async {
      final config = _scoreboardConfig(
        matchCode: 'M-SWAP',
        version: 2,
        homeIsLeft: false,
      );
      await _seedScoreboardPrefs(
        prefs,
        config,
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 1,
        firstTeamId: 'B',
        scoreA: 3,
        scoreB: 1,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-SWAP',
        scoreboardVersion: 2,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      await settleScoreboardConfig(tester, game);

      game.resumePendingMatch();
      final saved = await waitForSavedSnapshot(
        tester,
        (snapshot) =>
            snapshot.isRefereeMatch &&
            snapshot.savedAtMs > 1000 &&
            snapshot.teams.first.id == 'B',
      );
      expect(saved.scoreboardHomeTeamId, 'A');
      expect(saved.scoreboardAwayTeamId, 'B');
      expect(game.teams[0].id, 'B');

      var reviewRequests = 0;
      game.onRequestReviewScoreboardResult = () {
        reviewRequests++;
      };

      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      expect(game.currentStage, MatchStage.fullTime);
      expect(reviewRequests, 1);
      expect(game.needsScoreboardResultReview, isTrue);

      final review = game.buildScoreboardResultReview();
      expect(review.homeGoals, 3,
          reason: 'home score follows team A even after side swap');
      expect(review.awayGoals, 1,
          reason: 'away score follows team B even after side swap');

      final result = await submitCurrentReview(tester, game, 'M-SWAP');

      expect(result.homeGoals, 3,
          reason: 'home score follows team A even after side swap');
      expect(result.awayGoals, 1,
          reason: 'away score follows team B even after side swap');
      expect(result.version, 2);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets('drift guard drops stale scoreboard binding on resume',
        (tester) async {
      await _seedScoreboardPrefs(
        prefs,
        _scoreboardConfig(matchCode: 'Y', version: 2),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 1,
        isRefereeMatch: true,
        scoreboardMatchCode: 'X',
        scoreboardVersion: 1,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      await settleScoreboardConfig(tester, game);

      game.resumePendingMatch();
      final saved = await waitForSavedSnapshot(
        tester,
        (snapshot) => !snapshot.isRefereeMatch,
      );

      expect(saved.scoreboardMatchCode, isNull);
      expect(saved.scoreboardVersion, isNull);
      expect(saved.scoreboardHomeTeamId, isNull);
      expect(saved.scoreboardAwayTeamId, isNull);

      var reviewRequests = 0;
      game.onRequestReviewScoreboardResult = () {
        reviewRequests++;
      };

      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      expect(reviewRequests, 0);
      expect(game.needsScoreboardResultReview, isFalse);
      await expectNoOutboxItem(tester, game, 'Y');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets('resume re-arms on a same-fixture version bump (#53)',
        (tester) async {
      // Organizer edited the fixture during the kill window: same match_code,
      // newer version. The drift guard keys on match_code only, so this must
      // re-arm and submit the LIVE config version after review, not drift-suppress.
      await _seedScoreboardPrefs(
        prefs,
        _scoreboardConfig(matchCode: 'M-VER', version: 9),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 1,
        scoreA: 1,
        scoreB: 4,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-VER',
        scoreboardVersion: 4,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      await settleScoreboardConfig(tester, game);

      game.resumePendingMatch();
      var reviewRequests = 0;
      game.onRequestReviewScoreboardResult = () {
        reviewRequests++;
      };

      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      expect(reviewRequests, 1);
      expect(game.needsScoreboardResultReview, isTrue);
      final result = await submitCurrentReview(tester, game, 'M-VER');

      expect(result.homeGoals, 1);
      expect(result.awayGoals, 4);
      expect(result.version, 9,
          reason: 'submits the live config version, not the snapshot version');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'late-arriving fixture config re-arms a suppressed resume (#53)',
        (tester) async {
      // The scoreboard config loads via a separate unawaited initialize() and
      // may not have surfaced before the referee taps Resume. Resume then
      // suppresses; when the SAME fixture's config arrives it must re-arm (the
      // suppress latch is not one-way), and the final review must open.
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 1,
        scoreA: 6,
        scoreB: 0,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-LATE',
        scoreboardVersion: 3,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      // No scoreboard config seeded yet → matchConfig is null at resume time.
      expect(game.scoreboardResultService.matchConfig, isNull);

      game.resumePendingMatch(); // suppressed: bound fixture remembered as M-LATE

      // Now the fixture's config arrives and notifies listeners.
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-LATE', version: 3),
        ),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();

      var reviewRequests = 0;
      game.onRequestReviewScoreboardResult = () {
        reviewRequests++;
      };

      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      expect(reviewRequests, 1);
      expect(game.needsScoreboardResultReview, isTrue);

      final review = game.buildScoreboardResultReview();
      expect(review.homeGoals, 6, reason: 're-armed mapping: home is team A');
      expect(review.awayGoals, 0, reason: 're-armed mapping: away is team B');

      final result = await submitCurrentReview(tester, game, 'M-LATE');

      expect(result.homeGoals, 6, reason: 're-armed mapping: home is team A');
      expect(result.awayGoals, 0, reason: 're-armed mapping: away is team B');
      expect(result.version, 3);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'late config after full-time still opens review for suppressed resume (#53)',
        (tester) async {
      // Regression: a resumed referee match can reach full-time WHILE STILL
      // suppressed (its fixture config has not surfaced yet). The full-time
      // tick cannot open review while suppressed, and the same tick clears the
      // snapshot - so the late config must surface the review affordance.
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 1,
        scoreA: 4,
        scoreB: 2,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-LFT',
        scoreboardVersion: 3,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      // No scoreboard config seeded yet -> matchConfig is null at resume time.
      expect(game.scoreboardResultService.matchConfig, isNull);

      game.resumePendingMatch(); // suppressed: bound fixture remembered as M-LFT

      var reviewRequests = 0;
      game.onRequestReviewScoreboardResult = () {
        reviewRequests++;
      };

      // Drive to full-time BEFORE the config surfaces. The suppressed full-time
      // tick must NOT queue anything yet.
      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      expect(game.currentStage, MatchStage.fullTime);
      expect(reviewRequests, 0);
      expect(game.needsScoreboardResultReview, isFalse);
      await expectNoOutboxItem(tester, game, 'M-LFT');

      // Now the bound fixture's config finally arrives, after full-time.
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-LFT', version: 3),
        ),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();

      expect(reviewRequests, 1);
      expect(game.needsScoreboardResultReview, isTrue);

      final review = game.buildScoreboardResultReview();
      expect(review.homeGoals, 4, reason: 'home is team A');
      expect(review.awayGoals, 2, reason: 'away is team B');

      final result = await submitCurrentReview(tester, game, 'M-LFT');
      expect(result.homeGoals, 4, reason: 'home is team A');
      expect(result.awayGoals, 2, reason: 'away is team B');
      expect(result.version, 3);
      expect(
        game.scoreboardResultService.outbox
            .where((i) => i.matchCode == 'M-LFT')
            .length,
        1,
        reason: 'exactly one submission - the re-arm must not double-queue',
      );

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'suppressed resume re-persists the binding for a 2nd kill (#53)',
        (tester) async {
      // Config not loaded at resume → binding is suppressed. The snapshot it
      // RE-SAVES must still be a referee match with the binding intact, so a
      // second kill before the config surfaces recovers it (not a plain match).
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 1,
        scoreA: 2,
        scoreB: 2,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-PEND',
        scoreboardVersion: 5,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      expect(game.scoreboardResultService.matchConfig, isNull);

      game.resumePendingMatch(); // suppressed (no config yet)
      final saved = await waitForSavedSnapshot(
        tester,
        (snapshot) => snapshot.isRefereeMatch && snapshot.savedAtMs > 1000,
      );
      expect(saved.scoreboardMatchCode, 'M-PEND',
          reason: 'binding survives the suppressed window for a second kill');
      expect(saved.scoreboardVersion, 5);
      expect(saved.scoreboardHomeTeamId, 'A');
      expect(saved.scoreboardAwayTeamId, 'B');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets('late config re-arms a swapped resumed match correctly (#53)',
        (tester) async {
      // Swapped team order (firstTeamId B → teams[0] is B) but home is team A
      // (homeIsLeft true). home != teams[0], so a positional (teams[0]) mapping
      // bug would give the wrong score and fail this test. The late-config
      // re-arm must map home/away by STABLE team id, not position.
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 1,
        firstTeamId: 'B',
        scoreA: 1,
        scoreB: 7,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-LSWAP',
        scoreboardVersion: 2,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      expect(game.scoreboardResultService.matchConfig, isNull);

      game.resumePendingMatch(); // suppressed

      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-LSWAP', version: 2, homeIsLeft: true),
        ),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();
      expect(game.teams[0].id, 'B', reason: 'team order stayed swapped');

      var reviewRequests = 0;
      game.onRequestReviewScoreboardResult = () {
        reviewRequests++;
      };

      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      expect(reviewRequests, 1);
      expect(game.needsScoreboardResultReview, isTrue);

      final review = game.buildScoreboardResultReview();
      expect(review.homeGoals, 1,
          reason: 'home is team A (id), not teams[0] which is B');
      expect(review.awayGoals, 7, reason: 'away is team B');

      final result = await submitCurrentReview(tester, game, 'M-LSWAP');

      expect(result.homeGoals, 1,
          reason: 'home is team A (id), not teams[0] which is B');
      expect(result.awayGoals, 7, reason: 'away is team B');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'a different fixture mid-suppressed-resume cannot hijack it (#53)',
        (tester) async {
      // Resume bound to M-HX with no config yet (suppressed). Then a DIFFERENT
      // fixture M-HY opens mid-match. It must be rejected: the re-saved snapshot
      // must still be M-HX (a 2nd kill must NOT resume bound to M-HY), and no
      // result may be POSTed against M-HY.
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 1,
        scoreA: 3,
        scoreB: 2,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-HX',
        scoreboardVersion: 1,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      game.resumePendingMatch(); // suppressed, bound to M-HX

      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-HY', version: 9),
        ),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();

      // Force a fresh snapshot save now that the foreign config is loaded.
      game.notifyModulesScore();
      await tester.pump();
      await tester.pump();
      final saved = MatchStateStore(prefs).load();
      expect(saved, isNotNull);
      expect(saved!.isRefereeMatch, isTrue);
      expect(saved.scoreboardMatchCode, 'M-HX',
          reason: 'foreign fixture must not overwrite the bound one');

      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      await expectNoOutboxItem(tester, game, 'M-HY');
      await expectNoOutboxItem(tester, game, 'M-HX');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets('a live referee match persists its binding on first kill (#53)',
        (tester) async {
      // First-kill path (no prior snapshot): a deep-link config is applied to a
      // fresh match, the match starts, and the persisted snapshot must carry the
      // referee binding so it can be resumed + submitted.
      final game = Game();
      await settleLoad(tester);

      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-FIRST', version: 4),
        ),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();

      game.startTimer(); // inGame = true
      game.notifyModulesScore();
      await tester.pump();
      await tester.pump();

      final saved = MatchStateStore(prefs).load();
      expect(saved, isNotNull);
      expect(saved!.inGame, isTrue);
      expect(saved.isRefereeMatch, isTrue);
      expect(saved.scoreboardMatchCode, 'M-FIRST');
      expect(saved.scoreboardVersion, 4);
      expect(saved.scoreboardHomeTeamId, 'A');
      expect(saved.scoreboardAwayTeamId, 'B');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'non-referee swapped match resumes and never submits a result (#53)',
        (tester) async {
      // Regression guard: #53 touches the shared _buildSnapshot/resume paths.
      // A plain (non-deep-link) match with a SWAPPED team order must still
      // resume with its order+score intact AND must never enter the scoreboard
      // result path (no binding, no POST). No scoreboard prefs are seeded.
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 1,
        firstTeamId: 'B', // swapped: teams[0] is B
        scoreA: 3,
        scoreB: 1,
        // isRefereeMatch defaults to false (plain match).
      ));
      final game = Game();
      await settleLoad(tester);
      expect(game.scoreboardResultService.matchConfig, isNull);

      game.resumePendingMatch();

      // Team order + scores restored by stable id (not position).
      expect(game.teams[0].id, 'B', reason: 'swapped order restored');
      expect(game.teams.firstWhere((t) => t.id == 'A').score, 3);
      expect(game.teams.firstWhere((t) => t.id == 'B').score, 1);

      // The re-saved snapshot is a plain match: no referee binding leaks in.
      final saved = await waitForSavedSnapshot(
        tester,
        (snapshot) => snapshot.savedAtMs > 1000,
      );
      expect(saved.isRefereeMatch, isFalse);
      expect(saved.scoreboardMatchCode, isNull);
      expect(saved.scoreboardHomeTeamId, isNull);
      expect(saved.scoreboardAwayTeamId, isNull);

      // Drive to full-time: a non-referee match must POST nothing.
      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(game.scoreboardResultService.outbox, isEmpty,
          reason: 'a plain match must never queue a scoreboard result');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets('discardPendingMatch resets and clears the snapshot',
        (tester) async {
      await persist(_snap(remainingTime: 200, scoreA: 5));
      final game = Game();
      await settleLoad(tester);
      expect(game.pendingResume, isNotNull);

      await game.discardPendingMatch(); // awaits the clear (tombstone + remove)
      await tester.pump();

      expect(game.pendingResume, isNull);
      expect(game.getScore('A'), 0);
      expect(game.inGame, isFalse);

      expect(MatchStateStore(prefs).load(), isNull);
      game.dispose();
    });

    testWidgets(
        'confirm-on-load prompt fires when the callback is registered after '
        'the link surfaces', (tester) async {
      final game = Game();
      await settleLoad(tester);

      // A staged deep link surfaces BEFORE Home installs the confirm callback
      // (the constructor-initialize vs didChangeDependencies race).
      game.scoreboardResultService.debugApplyPendingMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-LOAD', version: 2),
        ),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();

      final prompts = <String>[];
      // The draining setter must fire the already-pending prompt on assignment.
      game.onRequestConfirmScoreboardMatch = (c) => prompts.add(c.matchCode);
      expect(prompts, ['M-LOAD']);

      // A redundant notify for the same pending config must not re-prompt.
      game.scoreboardResultService.debugApplyPendingMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-LOAD', version: 2),
        ),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();
      expect(prompts, ['M-LOAD']);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'submitScoreboardResult refuses when the committed fixture changed',
        (tester) async {
      final game = Game();
      await settleLoad(tester);

      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-ONE', version: 1),
        ),
        token: 'token-1',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();
      final review = game.buildScoreboardResultReview();
      expect(review.matchCode, 'M-ONE');

      // A new link is confirmed while the review screen (still showing M-ONE)
      // is open, changing the committed fixture underneath it.
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-TWO', version: 1),
        ),
        token: 'token-2',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();

      final ok = await game.submitScoreboardResult(
        expectedSignature: review.signature, // captured for M-ONE
        homeGoals: review.homeGoals,
        awayGoals: review.awayGoals,
        homeConfirmed: false,
        awayConfirmed: false,
      );
      expect(ok, isFalse, reason: 'must not POST M-ONE scores against M-TWO');
      expect(game.scoreboardResultService.outbox, isEmpty);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'submitScoreboardResult refuses a same-code config that changed sides',
        (tester) async {
      final game = Game();
      await settleLoad(tester);

      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-SIG', version: 1, homeIsLeft: true),
        ),
        token: 't',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();
      final review = game.buildScoreboardResultReview();

      // Same match code, but the organizer swapped sides (homeIsLeft false):
      // the captured review's signature no longer matches the live config.
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-SIG', version: 1, homeIsLeft: false),
        ),
        token: 't',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();

      final ok = await game.submitScoreboardResult(
        expectedSignature: review.signature,
        homeGoals: review.homeGoals,
        awayGoals: review.awayGoals,
        homeConfirmed: false,
        awayConfirmed: false,
      );
      expect(ok, isFalse,
          reason: 'a same-code side swap must invalidate the captured review');
      expect(game.scoreboardResultService.outbox, isEmpty);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'a fixture-revision change at full time invalidates the result review',
        (tester) async {
      // Reach full time bound to M-END v1 (the review subject is captured).
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 1,
        scoreA: 3,
        scoreB: 1,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-END',
        scoreboardVersion: 1,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      game.resumePendingMatch();
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-END', version: 1),
        ),
        token: 'token-end',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();
      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      expect(game.currentStage, MatchStage.fullTime);
      expect(game.needsScoreboardResultReview, isTrue);
      final review = game.buildScoreboardResultReview();
      expect(review.matchCode, 'M-END');

      // The SAME fixture surfaces at a new revision after full time (organizer
      // edit / refresh). matchCode still matches (so the #53 drift guard passes)
      // but the captured full-time signature does not.
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-END', version: 2),
        ),
        token: 'token-end',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();

      expect(game.needsScoreboardResultReview, isFalse,
          reason: 'a revision change after full time invalidates the review');
      final ok = await game.submitScoreboardResult(
        expectedSignature: review.signature, // captured for v1
        homeGoals: review.homeGoals,
        awayGoals: review.awayGoals,
        homeConfirmed: false,
        awayConfirmed: false,
      );
      expect(ok, isFalse,
          reason: 'must not post the v1 review against the v2 revision');
      await expectNoOutboxItem(tester, game, 'M-END');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets('onPendingMatchPromptClosed re-arms a still-pending prompt',
        (tester) async {
      final game = Game();
      await settleLoad(tester);

      final prompts = <String>[];
      game.onRequestConfirmScoreboardMatch = (c) => prompts.add(c.matchCode);

      game.scoreboardResultService.debugApplyPendingMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-RE', version: 1),
        ),
        token: 't',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();
      expect(prompts, ['M-RE']);

      // The dialog closed while the same link is still pending (e.g. a stale
      // no-op Load/Cancel): the prompt must re-arm for it.
      game.onPendingMatchPromptClosed();
      expect(prompts, ['M-RE', 'M-RE']);

      // Once the link is cleared, closing the prompt must NOT re-fire.
      game.scoreboardResultService.cancelPendingMatch();
      game.onPendingMatchPromptClosed();
      expect(prompts, ['M-RE', 'M-RE']);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });
  });

  group('result-delivery reset guard (RAVF001)', () {
    // Drive a live referee match to full time with its result eligible for
    // review. The resume path is used purely as a concise way to land at
    // secondHalf, 1 s from the end, with the scoreboard binding armed.
    Future<Game> liveRefereeAtFullTime(
      WidgetTester tester, {
      required String matchCode,
      int version = 1,
      int scoreA = 3,
      int scoreB = 1,
    }) async {
      await _seedScoreboardPrefs(
        prefs,
        _scoreboardConfig(matchCode: matchCode, version: version),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 1,
        scoreA: scoreA,
        scoreB: scoreB,
        isRefereeMatch: true,
        scoreboardMatchCode: matchCode,
        scoreboardVersion: version,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      await settleScoreboardConfig(tester, game);
      game.resumePendingMatch();
      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      expect(game.currentStage, MatchStage.fullTime);
      expect(game.needsScoreboardResultReview, isTrue);
      return game;
    }

    testWidgets('a late 200 after REPEAT does not reset the new live match',
        (tester) async {
      final game = await liveRefereeAtFullTime(tester, matchCode: 'M-RPT');
      await submitCurrentReview(tester, game, 'M-RPT');

      // Referee taps REPEAT: gameInit() starts a brand-new match and clears the
      // captured full-time signature. Make the new match visibly non-default so
      // a stray reset is observable.
      game.toggleTimer(); // GAME OVER branch -> gameInit
      expect(game.currentStage, MatchStage.firstHalf);
      game.teams[0].score = 7;
      game.startTimer();
      expect(game.inGame, isTrue);

      // The original queued result now lands (HTTP 200). It is still the
      // service's "current fixture", so the delivery callback fires - but the
      // referee has moved on, so it must NOT disconnect/reinit the live match.
      game.scoreboardResultService.onCurrentResultDelivered!();
      await tester
          .pump(); // drain the reset microtask (if the guard let it run)

      expect(game.teams[0].score, 7, reason: 'live match score must survive');
      expect(game.currentStage, MatchStage.firstHalf);
      expect(game.inGame, isTrue);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'a 200 while still on the full-time match resets to clean start',
        (tester) async {
      final game = await liveRefereeAtFullTime(tester,
          matchCode: 'M-DLV', scoreA: 5, scoreB: 2);
      // A custom name proves the reset restores defaults.
      game.teams.firstWhere((t) => t.id == 'A').name = 'Eagles';
      await submitCurrentReview(tester, game, 'M-DLV');

      game.scoreboardResultService.onCurrentResultDelivered!();
      await tester.pump(); // drain the reset microtask

      expect(game.currentStage, MatchStage.firstHalf);
      expect(game.inGame, isFalse);
      final teamA = game.teams.firstWhere((t) => t.id == 'A');
      expect(teamA.name, 'Team A');
      expect(teamA.score, 0);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'REPEAT of the same fixture does not re-arm while the prior result is '
        'in flight, so a late 200 cannot reset the second run', (tester) async {
      // REPEAT replays the SAME fixture: gameInit nulls the full-time signature
      // but the service keeps _matchConfig, so the second run reaches its own
      // full time with the SAME match_code+version still "current". A late 200
      // from the FIRST run must not reset/disconnect the second run (RAVF001,
      // REPEAT same-fixture edge).
      final game = await liveRefereeAtFullTime(tester, matchCode: 'M-REP');
      await submitCurrentReview(tester, game, 'M-REP'); // first result queued
      expect(
          game.scoreboardResultService.hasUnresolvedResultFor('M-REP'), isTrue,
          reason: 'the first run\'s result is still in flight after submit');

      // Shorten the halves so the second run reaches full time in a few ticks.
      game.periodTime = 1;
      game.halfTimeDuration = 1;

      game.toggleTimer(); // GAME OVER -> gameInit (firstHalf, signature cleared)
      expect(game.currentStage, MatchStage.firstHalf);

      // Drive the second run to full time via the clock only (no playAll fan-out
      // timers). firstHalf -> halfTime (auto-starts) -> secondHalf (referee
      // starts) -> fullTime.
      game.startTimer();
      await tester.pump(const Duration(seconds: 1)); // -> halfTime
      expect(game.currentStage, MatchStage.halfTime);
      await tester.pump(const Duration(seconds: 1)); // -> secondHalf
      expect(game.currentStage, MatchStage.secondHalf);
      game.teams[0].score = 5; // make the live second run visibly non-default
      game.startTimer();
      await tester.pump(const Duration(seconds: 1)); // -> fullTime
      expect(game.currentStage, MatchStage.fullTime);

      // The guard kept the reset signature un-armed (a prior same-fixture result
      // is still unresolved), so the late 200 is a no-op for the second run.
      game.scoreboardResultService.onCurrentResultDelivered!();
      await tester.pump(); // drain the reset microtask (if it wrongly ran)

      expect(game.teams[0].score, 5,
          reason: 'the second run must NOT be reset by the first run\'s 200');
      expect(game.currentStage, MatchStage.fullTime);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });
  });

  group('full-time result durability (RAVF003)', () {
    testWidgets('a killed full-time referee match is restored into the review',
        (tester) async {
      await _seedScoreboardPrefs(
        prefs,
        _scoreboardConfig(matchCode: 'M-KILL', version: 3),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      // A full-time referee snapshot: the match ended but the result was never
      // submitted before the app was killed.
      await persist(_snap(
        stage: 'fullTime',
        remainingTime: 0,
        scoreA: 4,
        scoreB: 2,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-KILL',
        scoreboardVersion: 3,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      await settleScoreboardConfig(tester, game);
      await tester.pump(); // let a suppressed restore re-arm via the config

      expect(game.pendingResume, isNull,
          reason: 'a finished match is not offered for a plain resume');
      expect(game.currentStage, MatchStage.fullTime);
      expect(game.needsScoreboardResultReview, isTrue);

      // The draining setter opens the review the moment Home registers it.
      var reviewRequests = 0;
      game.onRequestReviewScoreboardResult = () => reviewRequests++;
      expect(reviewRequests, 1);

      final review = game.buildScoreboardResultReview();
      expect(review.matchCode, 'M-KILL');
      expect(review.homeGoals, 4, reason: 'home is team A');
      expect(review.awayGoals, 2, reason: 'away is team B');

      final result = await submitCurrentReview(tester, game, 'M-KILL');
      expect(result.homeGoals, 4);
      expect(result.awayGoals, 2);
      expect(result.version, 3);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'the full-time tick persists a review snapshot, then REPEAT clears it',
        (tester) async {
      await _seedScoreboardPrefs(
        prefs,
        _scoreboardConfig(matchCode: 'M-DUR', version: 2),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await persist(_snap(
        stage: 'secondHalf',
        remainingTime: 1,
        scoreA: 3,
        scoreB: 0,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-DUR',
        scoreboardVersion: 2,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      await settleScoreboardConfig(tester, game);
      game.resumePendingMatch();

      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      expect(game.currentStage, MatchStage.fullTime);
      expect(game.needsScoreboardResultReview, isTrue);

      // The full-time tick PERSISTS a review snapshot (does not clear it), so a
      // kill before Submit is recoverable.
      final saved = await waitForSavedSnapshot(
        tester,
        (s) => s.stage == 'fullTime' && s.isRefereeMatch,
      );
      expect(saved.scoreboardMatchCode, 'M-DUR');
      expect(saved.teams.firstWhere((t) => t.id == 'A').score, 3);

      // Once the referee starts a fresh match (REPEAT), the snapshot is cleared.
      game.toggleTimer(); // GAME OVER branch -> gameInit + clear
      expect(game.currentStage, MatchStage.firstHalf);
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        if (MatchStateStore(prefs).load() == null) break;
      }
      expect(MatchStateStore(prefs).load(), isNull,
          reason: 'REPEAT must clear the persisted full-time snapshot');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'a side-swap during the kill window re-maps home/away on restore',
        (tester) async {
      // The match ended with team A (left) 4 - team B (right) 2 and was killed
      // before Submit. While the app was dead the organizer flipped the fixture
      // to home_is_left=false, so "home" is now the RIGHT side (team B). The
      // snapshot persisted the STALE mapping (home=A) AND the pre-swap names
      // (A='Reds'=home, B='Blues'=away); the restore must re-derive BOTH the
      // home/away->teamId mapping and the labels from the CURRENT config,
      // otherwise it would POST team A's 4 goals as "home" (the value bug) and/or
      // show 'Blues' as the home label (the label bug).
      await _seedScoreboardPrefs(
        prefs,
        _scoreboardConfig(
          matchCode: 'M-SIDESWAP',
          version: 3,
          homeIsLeft: false,
          homeTeamName: 'Reds',
          awayTeamName: 'Blues',
        ),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await persist(_snap(
        stage: 'fullTime',
        remainingTime: 0,
        scoreA: 4,
        scoreB: 2,
        nameA: 'Reds', // pre-swap labels (homeIsLeft was true: A=home=Reds)
        nameB: 'Blues',
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-SIDESWAP',
        scoreboardVersion: 3,
        scoreboardHomeTeamId: 'A', // stale pre-swap mapping
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      await settleScoreboardConfig(tester, game);
      await tester.pump();

      expect(game.currentStage, MatchStage.fullTime);
      expect(game.needsScoreboardResultReview, isTrue);

      final review = game.buildScoreboardResultReview();
      expect(review.matchCode, 'M-SIDESWAP');
      expect(review.homeGoals, 2,
          reason: 'home is now the right side (team B = 2) after the swap');
      expect(review.awayGoals, 4,
          reason: 'away is now the left side (team A = 4) after the swap');
      expect(review.homeName, 'Reds',
          reason:
              'home label must follow the re-derived mapping (team B=Reds)');
      expect(review.awayName, 'Blues',
          reason:
              'away label must follow the re-derived mapping (team A=Blues)');

      final result = await submitCurrentReview(tester, game, 'M-SIDESWAP');
      expect(result.homeGoals, 2);
      expect(result.awayGoals, 4);
      expect(result.version, 3);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'a restored full-time match with a pending result still resets when '
        'that genuine 200 finally lands', (tester) async {
      // Kill AFTER Submit but BEFORE the 200: on relaunch the outbox holds a
      // pending item for the on-screen fixture, so the review stays suppressed
      // (hasUnresolvedResultFor). But this restored match IS the one the result
      // belongs to, so the delivery-reset signature must still be armed — when
      // the genuine 200 arrives the finished match must reset/clear, not linger
      // with modules connected and a snapshot on disk. The RAVF001 arm-gate must
      // NOT swallow this (it only guards the live REPEAT tick).
      await _seedScoreboardPrefs(
        prefs,
        _scoreboardConfig(matchCode: 'M-P200', version: 2),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await _seedOutbox(prefs, [
        _outboxItem(
          matchCode: 'M-P200',
          state: ResultSubmissionState.pending,
          homeGoals: 2,
          awayGoals: 1,
          version: 2,
        ),
      ]);
      await persist(_snap(
        stage: 'fullTime',
        remainingTime: 0,
        scoreA: 2,
        scoreB: 1,
        nameA: 'Eagles', // a custom name proves the reset restores defaults
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-P200',
        scoreboardVersion: 2,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      await settleScoreboardConfig(tester, game);
      await tester.pump();

      // The pending item keeps the review closed...
      expect(game.needsScoreboardResultReview, isFalse,
          reason: 'a pending result suppresses the review affordance');

      // ...but the genuine 200 for that same fixture must still reset.
      game.scoreboardResultService.onCurrentResultDelivered!();
      await tester.pump(); // drain the reset microtask

      expect(game.currentStage, MatchStage.firstHalf,
          reason: 'the delivered first-run result must reset the match');
      expect(game.inGame, isFalse);
      final teamA = game.teams.firstWhere((t) => t.id == 'A');
      expect(teamA.name, 'Team A');
      expect(teamA.score, 0);
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        if (MatchStateStore(prefs).load() == null) break;
      }
      expect(MatchStateStore(prefs).load(), isNull,
          reason: 'a successful delivery must clear the persisted snapshot');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });
  });

  group('review re-open gate through Game (RAVF002 e2e)', () {
    testWidgets(
        'a terminal 401 in the outbox still re-opens the full-time review',
        (tester) async {
      await _seedScoreboardPrefs(
        prefs,
        _scoreboardConfig(matchCode: 'M-401E', version: 2),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await _seedOutbox(prefs, [
        _outboxItem(
          matchCode: 'M-401E',
          state: ResultSubmissionState.failed,
          responseStatus: 401,
          homeGoals: 2,
          awayGoals: 1,
          version: 2,
        ),
      ]);
      await persist(_snap(
        stage: 'fullTime',
        remainingTime: 0,
        scoreA: 2,
        scoreB: 1,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-401E',
        scoreboardVersion: 2,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      await settleScoreboardConfig(tester, game);
      await tester.pump();

      expect(game.needsScoreboardResultReview, isTrue,
          reason: 'a correctable 401 must leave the review reachable via Game');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets('a still-pending outbox item keeps the review blocked',
        (tester) async {
      await _seedScoreboardPrefs(
        prefs,
        _scoreboardConfig(matchCode: 'M-PEND', version: 2),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await _seedOutbox(prefs, [
        _outboxItem(
          matchCode: 'M-PEND',
          state: ResultSubmissionState.pending,
          homeGoals: 2,
          awayGoals: 1,
          version: 2,
        ),
      ]);
      await persist(_snap(
        stage: 'fullTime',
        remainingTime: 0,
        scoreA: 2,
        scoreB: 1,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-PEND',
        scoreboardVersion: 2,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      await settleScoreboardConfig(tester, game);
      await tester.pump();

      expect(game.needsScoreboardResultReview, isFalse,
          reason: 'an in-flight result must keep the review suppressed');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });
  });

  group('review-edit write-back (RAVF004)', () {
    testWidgets(
        'a corrected review score is written to the teams and snapshot so a '
        're-open shows the correction, not the original', (tester) async {
      await _seedScoreboardPrefs(
        prefs,
        _scoreboardConfig(matchCode: 'M-EDIT', version: 2),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      // Cold-launch straight into a full-time review (no outbox item yet).
      await persist(_snap(
        stage: 'fullTime',
        remainingTime: 0,
        scoreA: 2,
        scoreB: 1,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-EDIT',
        scoreboardVersion: 2,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      await settleScoreboardConfig(tester, game);
      await tester.pump();

      expect(game.needsScoreboardResultReview, isTrue);
      final review = game.buildScoreboardResultReview();
      expect(review.homeGoals, 2, reason: 'home is team A');
      expect(review.awayGoals, 1, reason: 'away is team B');

      // Referee corrects the score on the review screen before submitting.
      final submitted = await game.submitScoreboardResult(
        expectedSignature: review.signature,
        homeGoals: 5,
        awayGoals: 3,
        comment: null,
        homeConfirmed: false,
        awayConfirmed: false,
      );
      expect(submitted, isTrue);

      // The correction is written onto the live teams (home=A, away=B)...
      final teamA = game.teams.firstWhere((t) => t.id == 'A');
      final teamB = game.teams.firstWhere((t) => t.id == 'B');
      expect(teamA.score, 5, reason: 'home (team A) takes the corrected score');
      expect(teamB.score, 3, reason: 'away (team B) takes the corrected score');

      // ...the queued outbox item carries the corrected score...
      final item = await waitForOutboxItem(tester, game, 'M-EDIT');
      expect(item.homeGoals, 5);
      expect(item.awayGoals, 3);

      // ...and the persisted snapshot reflects it, so a kill+restore or a
      // terminal-rejection re-open shows 5-3, not the original 2-1 (RAVF004).
      final snap = await waitForSavedSnapshot(
        tester,
        (s) =>
            s.scoreboardMatchCode == 'M-EDIT' &&
            s.teams.firstWhere((t) => t.id == 'A').score == 5,
      );
      expect(snap.teams.firstWhere((t) => t.id == 'B').score, 3);

      // A fresh review (as re-opened after a 401/422) now reads the correction.
      final reopened = game.buildScoreboardResultReview();
      expect(reopened.homeGoals, 5);
      expect(reopened.awayGoals, 3);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });
  });

  group('clear-linked-match undelivered guard (RAVF003)', () {
    testWidgets('undeliveredCount counts every non-submitted outbox item',
        (tester) async {
      await _seedScoreboardPrefs(
        prefs,
        _scoreboardConfig(matchCode: 'M-CLR', version: 1),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await _seedOutbox(prefs, [
        _outboxItem(matchCode: 'P', state: ResultSubmissionState.pending),
        _outboxItem(matchCode: 'C', state: ResultSubmissionState.conflict),
        _outboxItem(
          matchCode: 'F',
          state: ResultSubmissionState.failed,
          responseStatus: 401,
        ),
        _outboxItem(matchCode: 'S', state: ResultSubmissionState.submitted),
      ]);
      final game = Game();
      await settleLoad(tester);
      await tester.pump();

      // The Settings "Clear linked match" confirm dialog keys on this: warn
      // only when undelivered results would be lost (pending/conflict/failed),
      // never counting an already-delivered (submitted) item.
      expect(game.scoreboardResultService.undeliveredCount, 3);
      expect(game.scoreboardResultService.submittedCount, 1);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });
  });

  group('new-fixture Load resets the live match (RAVF002)', () {
    // Drive the real confirm path: stage a pending deep link, then
    // game.confirmScoreboardMatch() (what Home's Load button calls). Only that
    // user-confirmed path resets a match in progress/finished.
    Future<void> confirmLoad(
      WidgetTester tester,
      Game game,
      Map<String, dynamic> config,
    ) async {
      game.scoreboardResultService.debugApplyPendingMatchConfig(
        ScoreboardMatchConfig.fromJson(config),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();
      await game.confirmScoreboardMatch();
      await tester.pump();
    }

    testWidgets(
        'a confirmed Load of the SAME fixture still resets (not deduped away)',
        (tester) async {
      final game = Game();
      await settleLoad(tester);
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
            _scoreboardConfig(matchCode: 'M-A', version: 1)),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();
      game.startTimer();
      await tester.pump();
      game.teams.firstWhere((t) => t.id == 'A').addScore(2);
      await tester.pump();
      expect(game.inGame, isTrue);

      // Re-stage + confirm the SAME fixture (identical signature to the one
      // already applied). The warned overwrite must still reset to a clean
      // start, not be deduped away.
      await confirmLoad(
          tester, game, _scoreboardConfig(matchCode: 'M-A', version: 1));

      expect(game.currentStage, MatchStage.firstHalf);
      expect(game.teams.firstWhere((t) => t.id == 'A').score, 0,
          reason: 'a confirmed Load resets even for the same fixture');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'a confirmed Load of a different fixture mid-match resets scores + '
        'team order but keeps the outbox', (tester) async {
      // A result the referee already submitted for the OLD fixture is queued.
      await _seedOutbox(prefs, [
        _outboxItem(
          matchCode: 'M-OLD',
          state: ResultSubmissionState.pending,
          homeGoals: 1,
          awayGoals: 0,
        ),
      ]);
      final game = Game();
      await settleLoad(tester);

      // Load + start the OLD fixture, swap order (as in a 2nd half), score 2-1.
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_scoreboardConfig(
          matchCode: 'M-OLD',
          version: 1,
          homeTeamName: 'Reds',
          awayTeamName: 'Blues',
        )),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();
      game.toggleTeamOrder(); // teams become [B, A]
      await tester.pump();
      game.startTimer();
      await tester.pump();
      game.teams.firstWhere((t) => t.id == 'A').addScore(2);
      game.teams.firstWhere((t) => t.id == 'B').addScore(1);
      await tester.pump();
      expect(game.inGame, isTrue);

      // Referee confirms loading a DIFFERENT fixture (the warned overwrite).
      await confirmLoad(
        tester,
        game,
        _scoreboardConfig(
          matchCode: 'M-NEW',
          version: 1,
          durationSeconds: 120,
          homeTeamName: 'Greens',
          awayTeamName: 'Yellows',
        ),
      );

      // Live match reset to a clean state bound to the NEW fixture.
      expect(game.inGame, isFalse, reason: 'reset to loaded-not-started');
      expect(game.currentStage, MatchStage.firstHalf);
      expect(game.teams.firstWhere((t) => t.id == 'A').score, 0);
      expect(game.teams.firstWhere((t) => t.id == 'B').score, 0);
      // New fixture is home_is_left:true → home=A=Greens, away=B=Yellows.
      expect(game.teams.firstWhere((t) => t.id == 'A').name, 'Greens');
      expect(game.teams.firstWhere((t) => t.id == 'B').name, 'Yellows');
      // Default team order restored for the new first half (not left swapped).
      expect(game.teams[0].id, 'A',
          reason: 'a swapped order must not carry into the new match');
      expect(game.teams[1].id, 'B');
      // The new fixture's match length was adopted (M-NEW is 120 s).
      expect(game.periodTime, 120,
          reason:
              'the new fixture duration replaces the previous match length');

      // The previous fixture's queued result is untouched (rule 3).
      expect(
        game.scoreboardResultService.outbox
            .where((i) => i.matchCode == 'M-OLD')
            .length,
        1,
        reason: 'loading a new match must never wipe the outbox',
      );

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'a same-fixture refresh mid-match preserves the scores (not a Load)',
        (tester) async {
      final game = Game();
      await settleLoad(tester);
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
            _scoreboardConfig(matchCode: 'M-SAME', version: 1)),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();
      game.startTimer();
      await tester.pump();
      game.teams.firstWhere((t) => t.id == 'A').addScore(3);
      await tester.pump();

      // SAME fixture, bumped version: an automatic refresh (no confirmed Load),
      // so it must NOT reset. signature includes version, so it re-applies.
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
            _scoreboardConfig(matchCode: 'M-SAME', version: 2)),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();

      expect(game.inGame, isTrue,
          reason: 'a same-fixture refresh must not reset the match');
      expect(game.teams.firstWhere((t) => t.id == 'A').score, 3,
          reason: 'just-played scores preserved on a same-fixture refresh');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'a confirmed Load overrides a still-suppressed resume and resets to it',
        (tester) async {
      // Cold-resume a referee match bound to M-RES whose config has NOT yet
      // surfaced (suppressed), in progress at 1-0.
      await persist(_snap(
        stage: 'firstHalf',
        remainingTime: 200,
        scoreA: 1,
        scoreB: 0,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-RES',
        scoreboardVersion: 1,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      expect(game.scoreboardResultService.matchConfig, isNull);
      game.resumePendingMatch(); // suppressed: bound to M-RES, no config
      await tester.pump();
      expect(game.inGame, isTrue);

      // User confirms loading a DIFFERENT fixture while still suppressed. The
      // suppressed-resume rejection must NOT block an explicit Load.
      await confirmLoad(
        tester,
        game,
        _scoreboardConfig(
          matchCode: 'M-OTHER',
          version: 1,
          homeTeamName: 'Greens',
          awayTeamName: 'Yellows',
        ),
      );

      expect(game.currentStage, MatchStage.firstHalf);
      expect(game.teams.firstWhere((t) => t.id == 'A').score, 0,
          reason: 'a confirmed Load overrides the suppressed-resume rejection');
      expect(game.teams.firstWhere((t) => t.id == 'A').name, 'Greens');
      expect(game.scoreboardResultService.matchConfig?.matchCode, 'M-OTHER');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'a delivered 200 still resets after the response bumped the committed '
        'version (no regression)', (tester) async {
      await _seedScoreboardPrefs(
        prefs,
        _scoreboardConfig(
          matchCode: 'M-BUMP',
          version: 2,
          homeTeamName: 'Reds',
          awayTeamName: 'Blues',
        ),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await persist(_snap(
        stage: 'fullTime',
        remainingTime: 0,
        scoreA: 2,
        scoreB: 1,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-BUMP',
        scoreboardVersion: 2,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      await settleScoreboardConfig(tester, game);
      await tester.pump();
      expect(game.needsScoreboardResultReview, isTrue);

      // A successful POST returns a NEW version, which the service applies to the
      // committed config (_updateMatchVersionFromResponse) BEFORE firing the
      // delivery callback. Reproduce that committed-version bump, then deliver.
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_scoreboardConfig(
          matchCode: 'M-BUMP',
          version: 3,
          homeTeamName: 'Reds',
          awayTeamName: 'Blues',
        )),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();

      game.scoreboardResultService.onCurrentResultDelivered?.call();
      await tester.pump();
      await tester.pump();

      // The genuine 200 must STILL reset the finished match to a clean start,
      // even though the committed version no longer equals the full-time
      // subject's (the reset keys on stage + a captured full-time signature, not
      // on the post-response committed signature).
      expect(game.currentStage, MatchStage.firstHalf,
          reason: 'a genuine 200 must reset even after a version bump');
      expect(game.teams.firstWhere((t) => t.id == 'A').name, 'Team A',
          reason: 'reset restores default team names');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'a STALE-dialog Load (rejected promotion) does not reset the live match',
        (tester) async {
      // Suppressed resume bound to M-RES (config not surfaced), in progress 1-0.
      await persist(_snap(
        stage: 'firstHalf',
        remainingTime: 200,
        scoreA: 1,
        scoreB: 0,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-RES',
        scoreboardVersion: 1,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      game.resumePendingMatch(); // suppressed, bound to M-RES
      await tester.pump();
      expect(game.inGame, isTrue);

      // A committed config for a DIFFERENT fixture arrives and is rejected by the
      // suppressed-resume guard: committed becomes M-OLD but is NOT applied
      // (so _lastAppliedScoreboardSignature stays unequal to it).
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
            _scoreboardConfig(matchCode: 'M-OLD', version: 1)),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();

      // A newer pending link is staged; the user taps a STALE Load whose
      // expectedSignature no longer matches the pending fixture, so the service
      // rejects the promotion. With a bare confirmed-load flag this would have
      // re-applied committed M-OLD as a "new fixture" and wiped the resume; the
      // signature-keyed signal must refuse (confirmed sig != applied sig).
      game.scoreboardResultService.debugApplyPendingMatchConfig(
        ScoreboardMatchConfig.fromJson(
            _scoreboardConfig(matchCode: 'M-B', version: 1)),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();
      await game.confirmScoreboardMatch(expectedSignature: 'stale-signature');
      await tester.pump();

      expect(game.inGame, isTrue,
          reason: 'a rejected stale Load must not reset');
      expect(game.teams.firstWhere((t) => t.id == 'A').score, 1,
          reason: 'the suppressed resume scores must be preserved');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'a stale Load whose pending shares the committed-but-unapplied '
        "fixture's signature still does not reset", (tester) async {
      await persist(_snap(
        stage: 'firstHalf',
        remainingTime: 200,
        scoreA: 1,
        scoreB: 0,
        isRefereeMatch: true,
        scoreboardMatchCode: 'M-RES',
        scoreboardVersion: 1,
        scoreboardHomeTeamId: 'A',
        scoreboardAwayTeamId: 'B',
      ));
      final game = Game();
      await settleLoad(tester);
      game.resumePendingMatch();
      await tester.pump();

      // Committed M-OLD arrives, rejected by the suppress guard (unapplied).
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
            _scoreboardConfig(matchCode: 'M-OLD', version: 1)),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();

      // Pending is now ALSO M-OLD (same signature as committed). The user taps a
      // STALE older dialog whose expectedSignature is a DIFFERENT fixture, so the
      // promotion is rejected. The confirmed signal must not arm (pending !=
      // expectedSignature), so no reset despite pending == committed signature.
      game.scoreboardResultService.debugApplyPendingMatchConfig(
        ScoreboardMatchConfig.fromJson(
            _scoreboardConfig(matchCode: 'M-OLD', version: 1)),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();
      await game.confirmScoreboardMatch(
          expectedSignature: 'stale-older-signature');
      await tester.pump();

      expect(game.inGame, isTrue,
          reason: 'a rejected stale Load must not reset');
      expect(game.teams.firstWhere((t) => t.id == 'A').score, 1,
          reason: 'preserved even when pending shares the committed signature');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });
  });

  group('scoreboard team naming (#53)', () {
    Team teamById(Game game, String id) =>
        game.teams.firstWhere((t) => t.id == id);

    testWidgets('config re-apply after a swap keeps names matched by team id',
        (tester) async {
      // Repro of the swap+full-time display bug: the post-submit version bump
      // re-applies the config while the order is swapped. Names must follow the
      // team identity (home name -> home team), not the list position.
      final game = Game();
      await settleLoad(tester);

      // Initial config (homeIsLeft true => home is team A).
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_scoreboardConfig(
          matchCode: 'M-NAME',
          version: 1,
          homeTeamName: 'Red Robots',
          awayTeamName: 'Blue Bots',
        )),
      );
      await tester.pump();
      expect(teamById(game, 'A').name, 'Red Robots');
      expect(teamById(game, 'B').name, 'Blue Bots');

      // Swap the order (2nd-half switch), then re-apply the SAME fixture with a
      // bumped version (mimics _updateMatchVersionFromResponse after a 200).
      game.toggleTeamOrder();
      await tester.pump();
      expect(game.teams[0].id, 'B', reason: 'order is now swapped');

      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_scoreboardConfig(
          matchCode: 'M-NAME',
          version: 2, // bumped => signature differs => re-applies
          homeTeamName: 'Red Robots',
          awayTeamName: 'Blue Bots',
        )),
      );
      await tester.pump();

      // Names must still be on the correct teams by id, NOT scrambled onto the
      // physical positions.
      expect(teamById(game, 'A').name, 'Red Robots',
          reason: 'home name stays on home team (id A) after swap');
      expect(teamById(game, 'B').name, 'Blue Bots',
          reason: 'away name stays on away team (id B) after swap');
      game.dispose();
    });

    testWidgets('home_is_left false + swap keeps home name on team B',
        (tester) async {
      // The home_is_left:false counterpart of the swap test above (home is team
      // B). Swapping then re-applying must keep the home name on team B; the old
      // positional code would put it on teams[0] (team A after swap) and fail.
      final game = Game();
      await settleLoad(tester);

      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_scoreboardConfig(
          matchCode: 'M-RIGHT',
          version: 1,
          homeIsLeft: false, // home is team B
          homeTeamName: 'Red Robots',
          awayTeamName: 'Blue Bots',
        )),
      );
      await tester.pump();
      expect(teamById(game, 'B').name, 'Red Robots',
          reason: 'home (id B when !homeIsLeft) gets the home name');
      expect(teamById(game, 'A').name, 'Blue Bots');

      game.toggleTeamOrder();
      await tester.pump();
      expect(game.teams[0].id, 'B');

      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(_scoreboardConfig(
          matchCode: 'M-RIGHT',
          version: 2, // bumped => re-applies while swapped
          homeIsLeft: false,
          homeTeamName: 'Red Robots',
          awayTeamName: 'Blue Bots',
        )),
      );
      await tester.pump();
      expect(teamById(game, 'B').name, 'Red Robots',
          reason: 'home name stays on team B after swap+reapply');
      expect(teamById(game, 'A').name, 'Blue Bots');
      game.dispose();
    });
  });

  group('persistence wiring', () {
    testWidgets('a score change persists into the snapshot', (tester) async {
      final game = Game();
      await settleLoad(tester);

      game.teams[0].addScore(1);
      game.notifyModulesScore();
      await tester.pump(); // run the scheduled microtask flush
      await tester.pump(); // let the async save() setString land

      final snapshot = MatchStateStore(prefs).load();
      expect(snapshot, isNotNull);
      expect(snapshot!.teams.firstWhere((t) => t.id == 'A').score, 1);
      game.dispose();
    });

    testWidgets('a manual remaining-time edit persists', (tester) async {
      final game = Game();
      await settleLoad(tester);

      game.currentStage = MatchStage.firstHalf;
      game.setRemainingTime(123);
      await tester.pump();
      await tester.pump();

      final loaded = MatchStateStore(prefs).load();
      expect(loaded, isNotNull);
      expect(loaded!.remainingTime, 123);
      game.dispose();
    });

    testWidgets('clearMatchSnapshot removes the snapshot (e.g. Settings reset)',
        (tester) async {
      await persist(_snap(remainingTime: 200));
      final game = Game();
      await settleLoad(tester);

      await game.clearMatchSnapshot();
      await tester.pump();

      expect(MatchStateStore(prefs).load(), isNull);
      game.dispose();
    });
  });

  group('penalty-preserve fix', () {
    testWidgets('penalty-aware start preserves an active penalty',
        (tester) async {
      final game = Game();
      await settleLoad(tester);
      final module = game.teams[0].modules[0];

      module.penalty(30);
      expect(module.state, ModuleState.damage);
      expect(module.penaltyTime, 30);

      // The path the master "START ALL ROBOTS" now uses (playAll(false) ->
      // playOrDamageAll). The penalty branch does not zero the penalty.
      module.playOrDamageAll();
      expect(module.state, ModuleState.damage);
      expect(module.penaltyTime, 30);
      game.dispose();
    });

    testWidgets('master STOP still clears an active penalty', (tester) async {
      final game = Game();
      await settleLoad(tester);
      final module = game.teams[0].modules[0];

      module.penalty(30);
      module.stopAll(true); // removePenalty: true
      expect(module.penaltyTime, 0);

      // Drain the 3x100ms staggered STOP fan-out delays so no Timer is pending.
      await tester.pump(const Duration(milliseconds: 400));
      game.dispose();
    });
  });
}
