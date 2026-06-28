import 'package:flutter/widgets.dart';
import 'package:rcj_scoreboard/models/bridge_message.dart';
import 'package:rcj_scoreboard/models/module.dart';
import 'dart:async';
import 'package:rcj_scoreboard/models/team.dart';
import 'package:rcj_scoreboard/services/ble_bridge_service.dart';
import 'package:rcj_scoreboard/services/mqtt.dart';
import 'package:rcj_scoreboard/services/match_data.dart';
import 'package:rcj_scoreboard/services/notification_service.dart';
import 'package:rcj_scoreboard/services/vibration_service.dart';
import 'package:rcj_scoreboard/services/wakelock_service.dart';
import 'package:rcj_scoreboard/services/preset_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MatchStage {
  firstHalf,
  halfTime,
  secondHalf,
  fullTime,
}

class Game with ChangeNotifier, WidgetsBindingObserver {
  static const String _periodTimeKey = 'game_period_time';
  static const String _halfTimeDurationKey = 'game_halftime_duration';
  static const String _numberOfPlayersKey = 'game_num_players';
  static const String _penaltyTimeKey = 'game_penalty_time';
  static const String _notifPermissionRequestedKey =
      'notif_permission_requested';
  static const int _defaultPeriodTimeSeconds = 600;
  static const int _defaultHalfTimeDurationSeconds = 300;
  static const int _defaultPenaltyTimeSeconds = 60;
  static const int _defaultPlayersPerTeam = 2;
  static const int _noShowPenaltyGoalIntervalSeconds = 30;
  static const int _maxNoShowPenaltyGoalDifference = 10;

  String timerButtonText = 'START';
  final int _maxPlayer = 5;
  List<Team> teams = [];
  int _numberOfPLayers = _defaultPlayersPerTeam;
  int _remainingTime = 0;
  int _penaltyTime = _defaultPenaltyTimeSeconds;
  int _periodTime = _defaultPeriodTimeSeconds;
  int _halfTimeDuration = _defaultHalfTimeDurationSeconds;
  bool _isGameRunning = false;
  bool inGame = false;
  bool isTimeRunning = false;
  int _numberOfPlaying = 0;
  bool _noShowPenaltyGoalsActive = false;
  String? _noShowPenaltyScoringTeamId;
  int _lastNoShowPenaltyGoalElapsed = 0;
  MatchStage currentStage = MatchStage.firstHalf;
  Timer? _timer;
  DateTime? _runClockStartedAt;
  int? _runClockStartRemainingTime;
  // True only while the resume catch-up loop is replaying missed ticks in one
  // synchronous burst, so per-tick vibrations are suppressed (otherwise every
  // threshold crossed while backgrounded buzzes at once on return). State, MQTT
  // and module updates still run during replay.
  bool _replaying = false;
  SharedPreferences? _prefs;
  //MQTT
  MqttService mqttService = MqttService();
  BleBridgeService bleBridgeService = BleBridgeService();
  MatchDataService matchDataService = MatchDataService();
  VibrationService vibrationService = VibrationService();
  WakelockService wakelockService = WakelockService();

  // Callback to request showing the dialog
  void Function()? onRequestSwitchTeamOrderDialog;

  Game() {
    WidgetsBinding.instance.addObserver(this);

    String teamID;

    // A team (0)
    teamID = 'A';
    Module moduleA1 = Module(this, teamID, 'A1', 0);
    Module moduleA2 = Module(this, teamID, 'A2', 1);
    Module moduleA3 = Module(this, teamID, 'A3', 2);
    Module moduleA4 = Module(this, teamID, 'A4', 3);
    Module moduleA5 = Module(this, teamID, 'A5', 4);
    teams.add(Team('Team A', [moduleA1, moduleA2, moduleA3, moduleA4 ,moduleA5], teamID));

    // B team (1)
    teamID = 'B';
    Module moduleB1 = Module(this, teamID, 'B1', 5);
    Module moduleB2 = Module(this, teamID, 'B2', 6);
    Module moduleB3 = Module(this, teamID, 'B3', 7);
    Module moduleB4 = Module(this, teamID, 'B4', 8);
    Module moduleB5 = Module(this, teamID, 'B5', 9);
    teams.add(Team('Team B', [moduleB1, moduleB2, moduleB3, moduleB4 ,moduleB5], teamID));


    gameInit();
    unawaited(_loadPrefs());
  }

  Future<void> _loadPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    _periodTime = _prefs!.getInt(_periodTimeKey) ?? _defaultPeriodTimeSeconds;
    _halfTimeDuration =
        _prefs!.getInt(_halfTimeDurationKey) ?? _defaultHalfTimeDurationSeconds;
    _numberOfPLayers = (_prefs!.getInt(_numberOfPlayersKey) ??
            _defaultPlayersPerTeam)
        .clamp(1, _maxPlayer)
        .toInt();
    _penaltyTime = _prefs!.getInt(_penaltyTimeKey) ?? _defaultPenaltyTimeSeconds;

    if (!inGame) {
      gameInit();
    }
    // Prompt for notification permission once on first launch (one-shot), now
    // that _prefs is available — keeps the OS dialog off the match-start path.
    _maybeRequestNotificationPermission();
    notifyListeners();
  }

  void gameInit({bool resetModules = true}) {
    currentStage = MatchStage.firstHalf;
    _remainingTime = periodTime;
    isTimeRunning = false;
    _isGameRunning = false;
    timerButtonText = 'START';
    inGame = false;
    _resetNoShowPenaltyGoals();

    stopTimer();

    // enable or disable players based on player number;
    for (var team in teams) {
      team.score = 0;
      if (resetModules) {
        for (var i = 0; i < _maxPlayer; i++) {
          i < numberOfPLayers
              ? team.modules[i].enable()
              : team.modules[i].disable();
          team.modules[i].init();
        }
      }
    }
    notifyListeners();

    // publish default values to every sink (mqtt + bridge)
    _broadcastFullState();
  }

  void gameRefresh() {
    // refresh all values on every sink (mqtt + bridge)
    _broadcastFullState();
  }

  // Timer

  // Request OS notification permission once on first launch (called from
  // _loadPrefs), so the default-on timer alerts (see [VibrationService]) can
  // fire when the app is backgrounded, without popping the OS dialog over the
  // screen at kickoff. The settings switches also request permission lazily on
  // an off->on toggle, but those default to true, so a referee who never opens
  // settings would otherwise never be prompted. Guarded by a persisted one-shot
  // flag and fired unawaited so it never blocks.
  void _maybeRequestNotificationPermission() {
    final prefs = _prefs;
    if (prefs == null) return;
    if (prefs.getBool(_notifPermissionRequestedKey) ?? false) return;
    if (!vibrationService.gameTimerEnabled &&
        !vibrationService.damageTimerEnabled) {
      return;
    }
    prefs.setBool(_notifPermissionRequestedKey, true);
    unawaited(NotificationService.requestPermission());
  }

  void startTimer() {
    _timer?.cancel();
    inGame = true;
    if (currentStage == MatchStage.firstHalf ||
        currentStage == MatchStage.secondHalf) {
      _isGameRunning = true;
    }
    isTimeRunning = true;
    _runClockStartedAt = DateTime.now();
    _runClockStartRemainingTime = _remainingTime;
    notifyListeners();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (isTimeRunning) {
        _tickTimer();
      }
    });
  }

  void _tickTimer() {
    if (_remainingTime > 0) {
      _remainingTime--;
      _checkGameTimerVibration();
      if (!_noShowPenaltyGoalsActive) {
        notifyAllModulesTimer();
      }
      mqttService.publishTime(_remainingTime);
      _maybeAwardNoShowPenaltyGoal();
    }

    if (_remainingTime <= 0) {
      _isGameRunning = false;
      isTimeRunning = false;
      _timer?.cancel();

      final noShowModeActive = _noShowPenaltyGoalsActive;
      switch (currentStage) {
        case MatchStage.firstHalf:
          currentStage = MatchStage.halfTime;
          _remainingTime = halfTimeDuration;
          startTimer();
          timerButtonText = 'SKIP';
          if (!noShowModeActive) {
            halfTimeAll();
            // Trigger the callback to show the dialog
            if (onRequestSwitchTeamOrderDialog != null) {
              onRequestSwitchTeamOrderDialog!();
            }
          }
          break;
        case MatchStage.halfTime:
          currentStage = MatchStage.secondHalf;
          _remainingTime = periodTime;
          _lastNoShowPenaltyGoalElapsed = 0;
          if (!noShowModeActive) {
            stopAll(true, force: true);
          }
          timerButtonText = 'START';
          break;
        case MatchStage.secondHalf:
          currentStage = MatchStage.fullTime;
          _resetNoShowPenaltyGoals();
          if (!noShowModeActive) {
            stopAll(true);
            gameOverAll();
          }
          timerButtonText = 'REPEAT';
          break;
        default:
          debugPrint('unknown match stage');
      }

      _broadcastStageAndTime();
    }

    if (!_noShowPenaltyGoalsActive &&
        currentStage == MatchStage.halfTime &&
        _remainingTime % 30 == 0) {
      halfTimeSyncTimeAll();
    }

    notifyListeners();
  }

  // Upper bound on background catch-up ticks: only the window the timer runs
  // *automatically*. The second-half timer is referee-started (the halfTime ->
  // secondHalf transition does NOT call startTimer()), so catch-up must stop at
  // that manual gate and never auto-run the second half. From the first half we
  // catch up through the first half + the half-time break; from the break, only
  // through the rest of the break.
  int _maxResumeCatchUpTicks() {
    switch (currentStage) {
      case MatchStage.firstHalf:
        return _remainingTime + halfTimeDuration;
      case MatchStage.halfTime:
        return _remainingTime;
      case MatchStage.secondHalf:
        return _remainingTime;
      case MatchStage.fullTime:
        return 0;
    }
  }

  void toggleTimer() {
    if (currentStage == MatchStage.firstHalf ||
        currentStage == MatchStage.secondHalf) {
      if (_isGameRunning) {
        stopTimer();
        timerButtonText = 'START';
        if (!_noShowPenaltyGoalsActive) {
          stopAll(false);
        }
      } else {
        timerButtonText = 'STOP';
        startTimer();
        if (!_noShowPenaltyGoalsActive) {
          playAll(false);
        }
      }
    } else if (currentStage == MatchStage.halfTime) {
      // SKIP
      _isGameRunning = false;
      isTimeRunning = false;
      _timer?.cancel();
      _runClockStartedAt = null;
      _runClockStartRemainingTime = null;
      currentStage = MatchStage.secondHalf;
      _remainingTime = periodTime;
      _lastNoShowPenaltyGoalElapsed = 0;
      if (!_noShowPenaltyGoalsActive) {
        stopAll(true, force: true);
      }
      timerButtonText = 'START';

      _broadcastStageAndTime();

      notifyListeners();
    } else {
      // GAME OVER
      gameInit();
      setTeamToDefaultOrder();
      notifyListeners();
      notifyModulesScore();
    }
  }

  void toggleTeamOrder() {
    teams = teams.reversed.toList();

    notifyListeners();

    // Push swapped names/team/score+color to every sink immediately, otherwise
    // the bridge only reflects the new sides on the next goal.
    _broadcastTeamInfo();
    _broadcastScore();
  }

  /// Toggles all modules based on the current game stage.
  void toggleAllModules() {
    if (_noShowPenaltyGoalsActive) {
      return;
    }
    if (currentStage == MatchStage.fullTime) {
      disconnectAll();
    } else if (_numberOfPlaying > 0) {
      stopAll(true);
    } else {
      if (!_isGameRunning &&
          (currentStage == MatchStage.firstHalf ||
              currentStage == MatchStage.secondHalf)) {
        startTimer();
        timerButtonText = 'STOP';
      }
      playAll(true);
    }
  }

  void resetModuleNames(){
    for (var team in teams) {
      for (var module in team.modules.where((module) => module.isEnabled && module.hasCustomLabel)) {
        module.setLabel(module.defaultName);
      }
    }
  }

  void _maybeAwardNoShowPenaltyGoal() {
    if (!_noShowPenaltyGoalsActive || !_isGameRunning) return;
    if (currentStage != MatchStage.firstHalf &&
        currentStage != MatchStage.secondHalf) {
      return;
    }

    final scoringTeamId = _noShowPenaltyScoringTeamId;
    if (scoringTeamId == null) return;

    final elapsed = periodTime - _remainingTime;
    if (elapsed <= 0 ||
        elapsed == _lastNoShowPenaltyGoalElapsed ||
        elapsed % _noShowPenaltyGoalIntervalSeconds != 0) {
      return;
    }

    final scoringTeam = _noShowPenaltyScoringTeam;
    if (scoringTeam == null || !_canAwardNoShowPenaltyGoal(scoringTeam)) {
      return;
    }

    scoringTeam.addScore(1);
    _lastNoShowPenaltyGoalElapsed = elapsed;
    notifyModulesScore();
  }

  void startNoShowPenaltyGoals(Team scoringTeam) {
    gameInit(resetModules: false);
    _noShowPenaltyGoalsActive = true;
    _noShowPenaltyScoringTeamId = scoringTeam.id;
    _lastNoShowPenaltyGoalElapsed = 0;
    timerButtonText = 'STOP';
    startTimer();
  }

  void stopNoShowPenaltyGoals() {
    _resetNoShowPenaltyGoals();
    timerButtonText = 'START';
    stopTimer();
  }

  void _resetNoShowPenaltyGoals() {
    _noShowPenaltyGoalsActive = false;
    _noShowPenaltyScoringTeamId = null;
    _lastNoShowPenaltyGoalElapsed = 0;
  }

  Team? get _noShowPenaltyScoringTeam {
    final scoringTeamId = _noShowPenaltyScoringTeamId;
    if (scoringTeamId == null) return null;
    for (final team in teams) {
      if (team.id == scoringTeamId) return team;
    }
    return null;
  }

  bool _canAwardNoShowPenaltyGoal(Team scoringTeam) {
    Team? opposingTeam;
    for (final team in teams) {
      if (team.id != scoringTeam.id) {
        opposingTeam = team;
        break;
      }
    }
    if (opposingTeam == null) return true;
    return scoringTeam.score - opposingTeam.score <
        _maxNoShowPenaltyGoalDifference;
  }

  void notifyAllModulesTimer() {
    // Use a flag so that at most one vibration fires per timer tick even if
    // multiple modules hit a threshold simultaneously.
    bool vibrateTriggered = false;

    for (var team in teams) {
      for (var module in team.modules.where((module) => module.isEnabled && module.state == ModuleState.damage)) {
        final penaltyBefore = module.penaltyTime;
        module.notifyTimer();

        if (!_replaying && !vibrateTriggered && vibrationService.damageTimerEnabled && penaltyBefore > 0) {
          final penaltyAfter = module.penaltyTime;
          if (vibrationService.damageTimerAlerts.contains(penaltyAfter)) {
            vibrateTriggered = true;
            vibrationService.vibrateDamageTimer();
          }
        }
      }
    }
  }

  void _checkGameTimerVibration() {
    if (_replaying) return;
    if (!vibrationService.gameTimerEnabled) return;
    if (currentStage != MatchStage.firstHalf &&
        currentStage != MatchStage.halfTime &&
        currentStage != MatchStage.secondHalf) {
      return;
    }
    if (!vibrationService.gameTimerAlerts.contains(_remainingTime)) return;

    vibrationService.vibrateGameTimer();
  }


  void stopTimer() {
    _isGameRunning = false;
    isTimeRunning = false;
    _timer?.cancel();
    _runClockStartedAt = null;
    _runClockStartRemainingTime = null;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!isTimeRunning) {
      return;
    }

    if (state == AppLifecycleState.paused) {
      // Schedule notifications for all active timers so the referee is alerted
      // even when the app is backgrounded or the screen is off.
      _scheduleBackgroundNotifications();
      return;
    }

    if (state == AppLifecycleState.resumed) {
      // Cancel scheduled notifications now that the app is active again –
      // the vibration mechanism handles in-app alerts.
      NotificationService.cancelAll();

      if (_runClockStartedAt != null && _runClockStartRemainingTime != null) {
        // Wall-clock seconds since the run clock was last anchored. Unclamped on
        // purpose: it may exceed the anchored stage's remaining time and is then
        // carried across the first-half -> half-time transition during catch-up.
        final elapsedSeconds =
            DateTime.now().difference(_runClockStartedAt!).inSeconds;
        // Ticks the live (foreground) timer already applied within the anchored
        // stage before the app was backgrounded.
        final alreadyApplied = (_runClockStartRemainingTime! - _remainingTime)
            .clamp(0, _runClockStartRemainingTime!)
            .toInt();
        // Outstanding ticks to replay, bounded by the auto-run window so we
        // never add time back (clamp floor 0) and never auto-start the
        // referee-controlled second half (_maxResumeCatchUpTicks halts at the
        // half-time -> second-half manual gate, reinforced by the isTimeRunning
        // guard below since that transition sets isTimeRunning = false).
        final ticksToProcess = (elapsedSeconds - alreadyApplied)
            .clamp(0, _maxResumeCatchUpTicks())
            .toInt();
        _replaying = true;
        for (var i = 0; i < ticksToProcess && isTimeRunning; i++) {
          _tickTimer();
        }
        _replaying = false;
        // Nothing replayed (local timer was at/ahead of wall clock): just
        // re-publish the authoritative state so every sink stays consistent.
        if (ticksToProcess == 0) {
          _broadcastStageAndTime();
          notifyListeners();
        }
      }
    }
  }

  // NOTE: background notifications are gated on the same enable flags as
  // vibration (see [VibrationService]) — a single user-facing "Vibration &
  // Notifications" setting controls both alert mechanisms.
  void _scheduleBackgroundNotifications() {
    // Game timer
    if (vibrationService.gameTimerEnabled) {
      switch (currentStage) {
        case MatchStage.firstHalf:
          NotificationService.scheduleGameAlerts(
              _remainingTime, vibrationService.gameTimerAlerts);
          // The first half + half-time break auto-run as one window on resume
          // (see _maxResumeCatchUpTicks), so also schedule the break alerts now,
          // offset past the remaining first half, otherwise a referee who stays
          // backgrounded across the break never gets the "start second half"
          // alert. Distinct notification IDs keep these from clobbering the
          // first-half game alerts.
          NotificationService.scheduleBreakAlerts(
              _remainingTime + halfTimeDuration,
              vibrationService.gameTimerAlerts);
          break;
        case MatchStage.halfTime:
          NotificationService.scheduleBreakAlerts(
              _remainingTime, vibrationService.gameTimerAlerts);
          break;
        case MatchStage.secondHalf:
          NotificationService.scheduleGameAlerts(
              _remainingTime, vibrationService.gameTimerAlerts,
              isFinalPeriod: true);
          break;
        default:
          debugPrint('unknown match stage');
      }
    }
    // Damage timers – one notification set per module currently in damage state.
    if (vibrationService.damageTimerEnabled) {
      for (final team in teams) {
        for (final module in team.modules.where(
            (m) => m.isEnabled && m.state == ModuleState.damage && m.penaltyTime > 0)) {
          NotificationService.scheduleDamageAlerts(
              module.moduleId, module.name, module.penaltyTime,
              vibrationService.damageTimerAlerts);
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }



  void playAll(bool removeDamage) async {
    for (var team in teams) {
      for (var module in team.modules.where((module) => module.isEnabled)) {
        if (removeDamage) {
          module.playAll();
        } else {
          module.playOrDamageAll();
        }
      }
    }
    notifyListeners();
  }

  void stopAll(bool removePenalty, {bool force = false}) {
    for (var team in teams) {
      for (var module in team.modules.where((module) => module.isEnabled)) {
        module.stopAll(removePenalty, force: force);
      }
    }
    notifyListeners();
  }

  void disconnectAll() {
    for (var team in teams) {
      for (var module in team.modules
          .where((module) => module.isEnabled && module.isConnected)) {
        module.bleDisconnect();
      }
    }
  }

  void halfTimeAll() async {
    stopAll(true);
    await Future.delayed(const Duration(seconds: 1));
    // The resume catch-up loop replays missed ticks synchronously, so it can
    // advance past half-time into the second half during this 1s delay. Skip
    // the now-stale half-time fan-out if the game already moved on, otherwise
    // we'd shove the robots back into a half-time countdown.
    if (currentStage != MatchStage.halfTime) return;

    for (var team in teams) {
      for (var module in team.modules.where((module) => module.isEnabled)) {
        module.halfTime();
      }
    }
    notifyListeners();
  }

  void gameOverAll() async {
    stopAll(true);
    await Future.delayed(const Duration(seconds: 1));
    // See halfTimeAll: bail out if the stage advanced during the delay so a
    // stale game-over fan-out can't fire against a new match.
    if (currentStage != MatchStage.fullTime) return;

    for (var team in teams) {
      for (var module in team.modules.where((module) => module.isEnabled)) {
        module.gameOver();
      }
    }
    notifyListeners();
  }

  void halfTimeSyncTimeAll() {
    for (var team in teams) {
      for (var module in team.modules
          .where((module) => module.isEnabled && module.isConnected)) {
        module.halfTimeSyncTime();
      }
    }
  }

  int getScore(String team, {bool oppositeTeam = false}) {
    final foundTeam = teams.firstWhere(
      (t) => oppositeTeam ? t.id != team : t.id == team,
      orElse: () => throw Exception('Team not found'),
    );
    return foundTeam.score;
  }

  void notifyModulesScore() {
    for (var team in teams) {
      for (var module in team.modules
          .where((module) => module.isEnabled && module.isConnected)) {
        module.bleSendScore();
        debugPrint('score sent');
      }
    }
    _broadcastScore();
  }

  String _teamColorHex(Team team) => team.id == 'A' ? '77FF00' : 'FF00FF';

  void _publishScoreToBridge() {
    bleBridgeService.publishTopic(
        BridgeTopics.team1Score, teams[0].score.toString());
    bleBridgeService.publishTopic(
        BridgeTopics.team2Score, teams[1].score.toString());
    bleBridgeService.publishTopic(
        BridgeTopics.team1Color, _teamColorHex(teams[0]));
    bleBridgeService.publishTopic(
        BridgeTopics.team2Color, _teamColorHex(teams[1]));
  }

  // ---- Publish fan-out helpers ----
  // Group every sink (MQTT + BLE bridge) per event so a sink can't be forgotten
  // at one call site (which is exactly how the team-swap-to-bridge bug slipped in).

  void _broadcastTeamInfo() {
    mqttService.publishTeamNames(teams);
    mqttService.publishTeam(teams);
  }

  void _broadcastScore() {
    mqttService.publishScore(teams);
    _publishScoreToBridge();
  }

  void _broadcastStageAndTime() {
    mqttService.publishGameState(currentStage);
    mqttService.publishTime(_remainingTime);
  }

  void _broadcastFullState() {
    _broadcastStageAndTime();
    _broadcastTeamInfo();
    _broadcastScore();
  }

  void changeNumberOfPlaying(int add) {
    _numberOfPlaying += add;

    if (_numberOfPlaying < 0) _numberOfPlaying = 0;
    if (_numberOfPlaying > numberOfPLayers * 2) {
      _numberOfPlaying = numberOfPLayers * 2;
    }

    if (_numberOfPlaying < 2) notifyListeners();
  }

  // void checkNumOfPlaying() {
  //   bool current = false;
  //   for (var team in teams) {
  //     for (var module in team.modules.where((module) => module.isEnabled)) {
  //       if (module.isPlaying) {
  //         current = true;
  //         break;
  //       }
  //       if(current) break;
  //     }
  //   }
  //
  //   //if (!current) stopAll();
  //
  //   if (current != _isSomeonePlaying) {
  //     _isSomeonePlaying = current;
  //     notifyListeners();
  //   }
  //
  // }

  void setTeamToDefaultOrder() {
    // check team order and if necessary switch them
    if (teams.length == 2 && teams[0].id == 'B' && teams[1].id == 'A') {
      toggleTeamOrder();
    }

    // // set default team names
    // teams[0].name = 'Team A';
    // teams[1].name = 'Team B';
  }

  int get periodTime => _periodTime;
  set periodTime(int value) {
    _periodTime = value;
    _prefs?.setInt(_periodTimeKey, value);
  }

  int get halfTimeDuration => _halfTimeDuration;
  set halfTimeDuration(int value) {
    _halfTimeDuration = value;
    _prefs?.setInt(_halfTimeDurationKey, value);
  }

  int get numberOfPLayers => _numberOfPLayers;
  set numberOfPLayers(int value) {
    _numberOfPLayers = value;
    _prefs?.setInt(_numberOfPlayersKey, value);
  }

  int get penaltyTime => _penaltyTime;
  set penaltyTime(int value) {
    _penaltyTime = value;
    _prefs?.setInt(_penaltyTimeKey, value);
  }

  int get remainingTime => _remainingTime;
  bool get noShowPenaltyGoalsActive => _noShowPenaltyGoalsActive;
  String get noShowPenaltyGoalIntervalLabel {
    if (_noShowPenaltyGoalIntervalSeconds % 60 == 0) {
      const minutes = _noShowPenaltyGoalIntervalSeconds ~/ 60;
      return minutes == 1 ? '1 goal/min' : '1 goal/$minutes min';
    }
    return '1 goal/$_noShowPenaltyGoalIntervalSeconds sec';
  }
  String get noShowPenaltyScoringTeamName =>
      _noShowPenaltyScoringTeam?.name ?? '';
  bool get isSomeonePlaying => _numberOfPlaying > 0 ? true : false;
  // True iff at least one enabled module is connected across either team.
  // Gates the no-module penalty path (issue #22): when the app is used purely
  // for time/score/penalty tracking with no robots, a module double-tap records
  // a penalty directly instead of "starting" a robot that does not exist. The
  // isEnabled filter mirrors the other connection/fan-out scans in this file.
  bool get anyModuleConnected => teams.any((team) =>
      team.modules.any((module) => module.isEnabled && module.isConnected));
  bool get noModuleConnected => !anyModuleConnected;
  bool get isTimerRunning => isTimeRunning;
  bool get isGameRunning => _isGameRunning;
  String get gameStageString {
    switch (currentStage) {
      case MatchStage.firstHalf:
        return '1';
      case MatchStage.halfTime:
        return 'Half-Time';
      case MatchStage.secondHalf:
        return '2';
      case MatchStage.fullTime:
        return 'Game Over';
    }
  }

  void loadMatchData() async {
    var match = await matchDataService.loadMatch();
    notifyListeners();

    if (match != null) {
      teams[0].name = match.team1;
      teams[1].name = match.team2;
      
      mqttService.topicField = match.field;
      
      _broadcastTeamInfo();
    }
  }

  void notifyMQTT() {
    // mqttService.publishGameState(currentStage);
    // mqttService.publishTime(_remainingTime);
    mqttService.publishTeamNames(teams);
    // mqttService.publishTeam(teams);
    // mqttService.publishScore(teams);
  }

  GamePreset createPreset(String name) {
    final configs = teams
        .expand((t) => t.modules)
        .where((m) => m.macAddress.isNotEmpty)
        .map((m) => ModuleConfig(
              moduleId: m.moduleId,
              macAddress: m.macAddress,
              label: m.hasCustomLabel ? m.name : '',
            ))
        .toList();
    return GamePreset.create(name, configs);
  }

  void applyPreset(GamePreset preset) {
    for (final config in preset.modules) {
      final module = teams
          .expand((t) => t.modules)
          .where((m) => m.moduleId == config.moduleId)
          .firstOrNull;
      module?.applyPresetConfig(config.macAddress, config.label);
    }
    notifyListeners();
  }

}
