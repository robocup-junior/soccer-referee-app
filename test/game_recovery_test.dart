// Tests for match cold-resume (#45): persistence wiring + restore flow.
//
// Like game_remaining_time_test, these use testWidgets because the Game
// constructor stands up wakelock/notification/MQTT/bridge services whose
// platform-channel calls reject asynchronously in the headless test VM; the
// widget binding tolerates those pending replies. We avoid leaving real Timers
// pending (Timer.periodic from startTimer, and the 100 ms staggered fan-out
// delays) by either not starting the clock or cancelling/draining it before the
// test returns.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/module.dart';
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
      await persist(_snap(
          stage: 'firstHalf', remainingTime: 137, scoreA: 2, scoreB: 1));
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
          _moduleSnap(
              id: 1, state: 'damage', lastState: 'play', penalty: 20),
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
          reason: 'armed by restore so a frozen-window reconnect stays stopped');

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
