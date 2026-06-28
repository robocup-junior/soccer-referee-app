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

      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      final result = await waitForOutboxItem(tester, game, 'M-53');

      expect(result.homeGoals, 5,
          reason: 'home score comes from restored team id B');
      expect(result.awayGoals, 2,
          reason: 'away score comes from restored team id A');
      expect(result.version, 4);

      await tester.pump(const Duration(milliseconds: 1500));
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

      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      final result = await waitForOutboxItem(tester, game, 'M-SWAP');

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

      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      await expectNoOutboxItem(tester, game, 'Y');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets('resume re-arms on a same-fixture version bump (#53)',
        (tester) async {
      // Organizer edited the fixture during the kill window: same match_code,
      // newer version. The drift guard keys on match_code only, so this must
      // re-arm and submit the LIVE config version, not drift-suppress.
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
      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      final result = await waitForOutboxItem(tester, game, 'M-VER');

      expect(result.homeGoals, 1);
      expect(result.awayGoals, 4);
      expect(result.version, 9,
          reason: 'submits the live config version, not the snapshot version');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets('late-arriving fixture config re-arms a suppressed resume (#53)',
        (tester) async {
      // The scoreboard config loads via a separate unawaited initialize() and
      // may not have surfaced before the referee taps Resume. Resume then
      // suppresses; when the SAME fixture's config arrives it must re-arm (the
      // suppress latch is not one-way), and the final POST must fire.
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

      // Now the fixture's config arrives and notifies listeners. A dead local
      // base URL makes the resulting submit network call fail instantly
      // (connection refused) instead of hitting the real host.
      game.scoreboardResultService.debugApplyMatchConfig(
        ScoreboardMatchConfig.fromJson(
          _scoreboardConfig(matchCode: 'M-LATE', version: 3),
        ),
        token: 'test-token',
        baseUri: Uri.parse('http://127.0.0.1:9'),
      );
      await tester.pump();

      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      final result = await waitForOutboxItem(tester, game, 'M-LATE');

      expect(result.homeGoals, 6,
          reason: 're-armed mapping: home is team A');
      expect(result.awayGoals, 0,
          reason: 're-armed mapping: away is team B');
      expect(result.version, 3);

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        'late config after full-time still submits a suppressed resume (#53)',
        (tester) async {
      // Regression: a resumed referee match can reach full-time WHILE STILL
      // suppressed (its fixture config has not surfaced yet). The sole
      // _queueFinalResultSubmission() call site is the secondHalf->fullTime
      // tick, which returns early under suppression, and the same tick clears
      // the snapshot - so without re-submitting on late config arrival the
      // result is lost forever. The late config must drive the POST.
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

      // Drive to full-time BEFORE the config surfaces. The suppressed full-time
      // tick must NOT queue anything yet.
      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      expect(game.currentStage, MatchStage.fullTime);
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

      final result = await waitForOutboxItem(tester, game, 'M-LFT');
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

    testWidgets('suppressed resume re-persists the binding for a 2nd kill (#53)',
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

      game.startTimer();
      await tester.pump(const Duration(seconds: 1));
      final result = await waitForOutboxItem(tester, game, 'M-LSWAP');

      expect(result.homeGoals, 1,
          reason: 'home is team A (id), not teams[0] which is B');
      expect(result.awayGoals, 7, reason: 'away is team B');

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets('a different fixture mid-suppressed-resume cannot hijack it (#53)',
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
