import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:rcj_scoreboard/models/bridge_message.dart';
import 'package:rcj_scoreboard/models/ios_mac_pairing.dart';
import 'package:rcj_scoreboard/models/match_persistence.dart';
import 'package:rcj_scoreboard/models/module.dart';
import 'package:rcj_scoreboard/models/scoreboard_binding.dart';
import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/models/team.dart';
import 'package:rcj_scoreboard/services/ble_adapter_monitor.dart';
import 'package:rcj_scoreboard/services/ble_bridge_service.dart';
import 'package:rcj_scoreboard/services/match_data.dart';
import 'package:rcj_scoreboard/services/match_state_store.dart';
import 'package:rcj_scoreboard/services/mqtt.dart';
import 'package:rcj_scoreboard/services/notification_service.dart';
import 'package:rcj_scoreboard/services/preset_service.dart';
import 'package:rcj_scoreboard/services/scoreboard_result_service.dart';
import 'package:rcj_scoreboard/services/vibration_service.dart';
import 'package:rcj_scoreboard/services/wakelock_service.dart';
import 'package:rcj_scoreboard/utils/ble_address.dart';
import 'package:rcj_scoreboard/utils/colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'game_resume.dart';
part 'game_scoreboard.dart';

enum MatchStage { firstHalf, halfTime, secondHalf, fullTime }

/// Root match state: two teams of five robot slots, the match clock and stage
/// machine, the robot fan-out, and the sinks (MQTT + BLE bridge) every change
/// is published to. Cold-resume persistence lives in [MatchPersistence], iOS
/// pairing in [IosMacPairing], and the scoreboard-fixture link in
/// [ScoreboardBinding]; this class orchestrates them.
class Game with ChangeNotifier, WidgetsBindingObserver {
  static const _periodTimeKey = 'game_period_time';
  static const _halfTimeDurationKey = 'game_halftime_duration';
  static const _numberOfPlayersKey = 'game_num_players';
  static const _penaltyTimeKey = 'game_penalty_time';
  static const _singleTapEnabledKey = 'gesture_single_tap_enabled';
  static const _notifPermissionRequestedKey = 'notif_permission_requested';
  static const _defaultPeriodTime = 600;
  static const _defaultHalfTimeDuration = 300;
  static const _defaultPenaltyTime = 60;
  static const _defaultPlayersPerTeam = 2;
  static const _maxPlayers = 5;
  static const _noShowGoalInterval = 30;
  static const _maxNoShowGoalDifference = 10;
  // A scoreboard fixture's `duration_seconds` is the scheduling SLOT, not the
  // play time: every scoreboard match is 10 + 5 + 10 (#71).
  static const _scoreboardHalf = 600;
  static const _scoreboardBreak = 300;

  // ---- services ----
  MqttService mqttService = MqttService();
  BleBridgeService bleBridgeService = BleBridgeService();
  final BleAdapterMonitor bleAdapterMonitor = BleAdapterMonitor();
  MatchDataService matchDataService = MatchDataService();
  VibrationService vibrationService = VibrationService();
  WakelockService wakelockService = WakelockService();
  ScoreboardResultService scoreboardResultService = ScoreboardResultService();
  late final MatchPersistence persistence = MatchPersistence(_buildSnapshot);
  late final IosMacPairing iosPairing = IosMacPairing(
    moduleById: _moduleById,
    canScanNow: () => !_isGameRunning && currentStage != MatchStage.fullTime,
  );
  final ScoreboardBinding _sb = ScoreboardBinding();
  SharedPreferences? _prefs;

  // ---- match state ----
  List<Team> teams = [];
  MatchStage currentStage = MatchStage.firstHalf;
  String timerButtonText = 'START';
  bool inGame = false;
  bool isTimeRunning = false;
  bool _isGameRunning = false;
  int _remainingTime = 0;
  int _numberOfPlaying = 0;
  Timer? _timer;
  // Wall-clock anchor for the background catch-up in didChangeAppLifecycleState.
  DateTime? _runClockStartedAt;
  int? _runClockStartRemainingTime;
  // True while the resume catch-up replays missed ticks in one burst (no
  // per-tick vibration / heartbeat).
  bool _replaying = false;
  bool _fullTimeTeardownDone = false;

  // ---- settings ----
  int _periodTime = _defaultPeriodTime;
  int _halfTimeDuration = _defaultHalfTimeDuration;
  int _penaltyTime = _defaultPenaltyTime;
  int _numberOfPlayers = _defaultPlayersPerTeam;
  bool _singleTapEnabled = false;
  // _loadPrefs runs unawaited; a toggle made before it resolves must win.
  bool _pendingSingleTapWrite = false;

  // ---- no-show penalty goals (#8) ----
  bool _noShowActive = false;
  String? _noShowScoringTeamId;
  int _lastNoShowGoalElapsed = 0;

  // ---- cold resume ----
  MatchSnapshot? _pendingResume;
  bool _resumePrompted = false;

  /// The match awaiting a Resume/Discard decision, if any.
  MatchSnapshot? get pendingResume => _pendingResume;

  // ---- UI callbacks ----
  // The last three are DRAINING setters: the request can be raised (by an
  // async load) before Home registers the callback, so assignment re-fires a
  // pending request; each target is idempotent.
  void Function()? onRequestSwitchTeamOrderDialog;

  void Function()? _onRequestResumeMatch;
  void Function()? get onRequestResumeMatch => _onRequestResumeMatch;
  set onRequestResumeMatch(void Function()? callback) {
    _onRequestResumeMatch = callback;
    _maybeFireResumePrompt();
  }

  void Function(ScoreboardMatchConfig)? _onRequestConfirmScoreboardMatch;
  void Function(ScoreboardMatchConfig)? get onRequestConfirmScoreboardMatch =>
      _onRequestConfirmScoreboardMatch;
  set onRequestConfirmScoreboardMatch(
      void Function(ScoreboardMatchConfig)? callback) {
    _onRequestConfirmScoreboardMatch = callback;
    _maybeFirePendingMatchPrompt();
  }

  void Function()? _onRequestReviewScoreboardResult;
  void Function()? get onRequestReviewScoreboardResult =>
      _onRequestReviewScoreboardResult;
  set onRequestReviewScoreboardResult(void Function()? callback) {
    _onRequestReviewScoreboardResult = callback;
    if (callback != null) _requestScoreboardResultReview();
  }

  Game() {
    WidgetsBinding.instance.addObserver(this);
    for (final id in ['A', 'B']) {
      final base = id == 'A' ? 0 : _maxPlayers;
      teams.add(Team(
        'Team $id',
        List.generate(
            _maxPlayers, (i) => Module(this, id, '$id${i + 1}', base + i)),
        id,
      ));
    }
    gameInit();
    scoreboardResultService.addListener(_onScoreboardServiceUpdate);
    scoreboardResultService.onCurrentResultDelivered =
        _onScoreboardResultDelivered;
    unawaited(scoreboardResultService.initialize());
    unawaited(_loadPrefs());
  }

  Future<void> _loadPrefs() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    persistence.attach(MatchStateStore(prefs));
    _periodTime = prefs.getInt(_periodTimeKey) ?? _defaultPeriodTime;
    _halfTimeDuration =
        prefs.getInt(_halfTimeDurationKey) ?? _defaultHalfTimeDuration;
    _numberOfPlayers =
        (prefs.getInt(_numberOfPlayersKey) ?? _defaultPlayersPerTeam)
            .clamp(1, _maxPlayers);
    _penaltyTime = prefs.getInt(_penaltyTimeKey) ?? _defaultPenaltyTime;
    iosPairing.loadCache(prefs);

    if (_pendingSingleTapWrite) {
      prefs.setBool(_singleTapEnabledKey, _singleTapEnabled);
      _pendingSingleTapWrite = false;
    } else {
      _singleTapEnabled = prefs.getBool(_singleTapEnabledKey) ?? false;
    }

    // Read the snapshot BEFORE the bootstrap gameInit (which must not persist
    // its default state over it).
    final snapshot = persistence.load();
    if (!inGame) persistence.suppress(gameInit);

    if (snapshot != null && snapshot.inGame) {
      if (_stageFromName(snapshot.stage) != MatchStage.fullTime) {
        _pendingResume = snapshot;
        _maybeFireResumePrompt();
      } else if (snapshot.isRefereeMatch &&
          (snapshot.scoreboardMatchCode?.isNotEmpty ?? false)) {
        _restoreFullTimeResultReview(snapshot);
      }
    }
    // The scoreboard service may have paired modules while numberOfPlayers
    // was still the default; re-pair against the real count (#70).
    if (_pendingResume == null) _syncScoreboardModulePairing(force: true);
    _maybeRequestNotificationPermission();
    notifyListeners();
  }

  void _maybeFireResumePrompt() {
    if (_resumePrompted || _pendingResume == null) return;
    final callback = _onRequestResumeMatch;
    if (callback == null) return;
    _resumePrompted = true;
    callback();
  }

  // Request OS notification permission once, off the match-start path.
  void _maybeRequestNotificationPermission() {
    final prefs = _prefs;
    if (prefs == null ||
        (prefs.getBool(_notifPermissionRequestedKey) ?? false)) {
      return;
    }
    if (!vibrationService.gameTimerEnabled &&
        !vibrationService.damageTimerEnabled) {
      return;
    }
    prefs.setBool(_notifPermissionRequestedKey, true);
    unawaited(NotificationService.requestPermission());
  }

  // ---- lookups ----

  // The part-file extensions cannot call the protected notifyListeners().
  void _notify() => notifyListeners();

  Iterable<Module> get modules => teams.expand((t) => t.modules);
  Iterable<Module> get _enabledModules => modules.where((m) => m.isEnabled);
  Module? _moduleById(int id) =>
      modules.where((m) => m.moduleId == id).firstOrNull;
  Team? _teamById(String? id) => teams.where((t) => t.id == id).firstOrNull;
  Team _opponentOf(Team team) => teams.firstWhere((t) => t.id != team.id);
  bool get _inPlayHalf =>
      currentStage == MatchStage.firstHalf ||
      currentStage == MatchStage.secondHalf;

  static MatchStage _stageFromName(String name) => MatchStage.values
      .firstWhere((s) => s.name == name, orElse: () => MatchStage.firstHalf);

  int getScore(String team, {bool oppositeTeam = false}) => teams
      .firstWhere((t) => oppositeTeam ? t.id != team : t.id == team,
          orElse: () => throw Exception('Team not found'))
      .score;

  // ---- match lifecycle ----

  /// Fresh match at the current fixture: first half, 0-0, robots stopped.
  /// Does NOT clear the resume snapshot (it also runs on every cold launch).
  void gameInit({bool resetModules = true}) {
    currentStage = MatchStage.firstHalf;
    _remainingTime = periodTime;
    isTimeRunning = false;
    _isGameRunning = false;
    timerButtonText = 'START';
    inGame = false;
    iosPairing.resolver.reset();
    _sb.resetForNewMatch();
    _fullTimeTeardownDone = false;
    _resetNoShowPenaltyGoals();
    stopTimer();
    for (final team in teams) {
      team.score = 0;
      if (!resetModules) continue;
      for (var i = 0; i < _maxPlayers; i++) {
        i < numberOfPlayers
            ? team.modules[i].enable()
            : team.modules[i].disable();
        team.modules[i].init();
      }
    }
    notifyListeners();
    broadcastFullState();
  }

  void startTimer() {
    _timer?.cancel();
    inGame = true;
    if (_inPlayHalf) {
      _isGameRunning = true;
      // Kickoff: no more iOS resolve scans for the rest of the match (a scan
      // competes with the radio used for START/STOP, invariant #1).
      if (useIosBleUuid) iosPairing.resolver.stopForMatch();
    }
    isTimeRunning = true;
    _runClockStartedAt = DateTime.now();
    _runClockStartRemainingTime = _remainingTime;
    notifyListeners();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (isTimeRunning) _tickTimer();
    });
    persistence.markDirtyAndFlush();
  }

  void stopTimer() {
    _isGameRunning = false;
    isTimeRunning = false;
    _timer?.cancel();
    _runClockStartedAt = null;
    _runClockStartRemainingTime = null;
    notifyListeners();
    persistence.markDirtyAndFlush();
  }

  void _tickTimer() {
    if (_remainingTime > 0) {
      _remainingTime--;
      _checkGameTimerVibration();
      if (!_noShowActive) notifyAllModulesTimer();
      mqttService.publishTime(_remainingTime);
      // ~5 s heartbeat for the clock freeze point (skipped during replay).
      if (!_replaying && _remainingTime % 5 == 0) persistence.flushNow();
      _maybeAwardNoShowPenaltyGoal();
    }

    if (_remainingTime <= 0) {
      _isGameRunning = false;
      isTimeRunning = false;
      _timer?.cancel();
      final robotsIdle = _noShowActive;
      switch (currentStage) {
        case MatchStage.firstHalf:
          currentStage = MatchStage.halfTime;
          _remainingTime = halfTimeDuration;
          startTimer();
          timerButtonText = 'SKIP';
          if (!robotsIdle) {
            halfTimeAll();
            onRequestSwitchTeamOrderDialog?.call();
          }
          persistence.markDirtyAndFlush();
        case MatchStage.halfTime:
          _startSecondHalf(robotsIdle: robotsIdle);
        case MatchStage.secondHalf:
          _completeMatchToFullTime();
        case MatchStage.fullTime:
          debugPrint('tick at full time');
      }
      _broadcastStageAndTime();
    }

    if (!_noShowActive &&
        currentStage == MatchStage.halfTime &&
        _remainingTime % 30 == 0) {
      halfTimeSyncTimeAll();
    }
    notifyListeners();
  }

  /// halfTime -> secondHalf (break expiry or SKIP). The second half is
  /// referee-started, so the clock stays stopped.
  void _startSecondHalf({required bool robotsIdle}) {
    currentStage = MatchStage.secondHalf;
    _remainingTime = periodTime;
    _lastNoShowGoalElapsed = 0;
    // Modules parked in halfTime need the forced STOP dispatch.
    if (!robotsIdle) stopAll(true, force: true);
    timerButtonText = 'START';
    persistence.markDirtyAndFlush();
  }

  /// The one true *->fullTime transition, shared by the natural second-half
  /// expiry and [endMatchEarly]. Callers broadcast + notify afterwards.
  void _completeMatchToFullTime({bool forceStop = false}) {
    final robotsIdle = _noShowActive;
    currentStage = MatchStage.fullTime;
    _resetNoShowPenaltyGoals();
    if (!robotsIdle) {
      stopAll(true, force: forceStop);
      gameOverAll();
    }
    timerButtonText = 'REPEAT';
    _enterFullTimeResultReview();
    // Stop the OS autoConnect from chasing modules powered down for good.
    disconnectInactiveModules();
    iosPairing.resolver.reset();
    _persistOrClearAtFullTime();
    unawaited(_teardownFieldTransportsAtFullTime());
  }

  /// Release the field infrastructure at full time (#87) so the next phone can
  /// take over the bridge/MQTT session. Delayed 1 s (after the final "Game
  /// Over" publish) and aborted if a new match started meanwhile.
  Future<void> _teardownFieldTransportsAtFullTime() async {
    if (_fullTimeTeardownDone) return;
    _fullTimeTeardownDone = true;
    await Future<void>.delayed(const Duration(seconds: 1));
    bool stale() =>
        !_fullTimeTeardownDone || currentStage != MatchStage.fullTime;
    if (stale()) return;
    switch (bleBridgeService.connectionStateNotifier.value) {
      case BridgeConnectionState.connected:
        await bleBridgeService.disconnectAfterDrain(shouldAbort: stale);
      case BridgeConnectionState.connecting:
        await bleBridgeService.disconnect();
      default:
        break;
    }
    if (stale()) return;
    mqttService.disconnect();
  }

  /// Claim the field's MQTT topics on a fresh/confirmed match load (#88).
  /// Fire-and-forget; on success the current state is rebroadcast because the
  /// load-time broadcasts ran while still disconnected.
  void _maybeAutoConnectMqttOnMatchLoad() {
    if (!mqttService.isEnabled || mqttService.isConnected) return;
    // No field topic -> no auto-connect, or retained state would land on the
    // venue-shared base namespace (review #94).
    if (mqttService.topic.isEmpty) return;
    unawaited(mqttService.connect().then((connected) {
      if (connected) broadcastFullState();
    }).catchError((Object e) {
      debugPrint('MQTT auto-connect failed: $e');
    }, test: (e) => e is Exception));
  }

  void toggleTimer() {
    switch (currentStage) {
      case MatchStage.firstHalf:
      case MatchStage.secondHalf:
        if (_isGameRunning) {
          stopTimer();
          timerButtonText = 'START';
          if (!_noShowActive) stopAll(false);
        } else {
          timerButtonText = 'STOP';
          startTimer();
          if (!_noShowActive) playAll(clearPenalties: false);
        }
      case MatchStage.halfTime: // SKIP
        _isGameRunning = false;
        isTimeRunning = false;
        _timer?.cancel();
        _runClockStartedAt = null;
        _runClockStartRemainingTime = null;
        _startSecondHalf(robotsIdle: _noShowActive);
        _broadcastStageAndTime();
        notifyListeners();
      case MatchStage.fullTime: // REPEAT
        gameInit();
        setTeamToDefaultOrder();
        // Same fixture, no config re-apply: re-run the pairing sync here so
        // unresolved iOS slots are searched again for the rematch.
        _syncScoreboardModulePairing();
        notifyListeners();
        notifyModulesScore();
        // Clear LAST so the flushes scheduled above can't re-save.
        persistence.clear();
    }
  }

  void toggleTeamOrder() {
    teams = teams.reversed.toList();
    notifyListeners();
    _broadcastTeamInfo();
    _broadcastScore();
    persistence.markDirtyAndFlush();
  }

  void setTeamToDefaultOrder() {
    if (teams.length == 2 && teams[0].id == 'B') toggleTeamOrder();
  }

  /// The START/STOP ALL ROBOTS button.
  void toggleAllModules() {
    if (_noShowActive) return;
    if (currentStage == MatchStage.fullTime) {
      disconnectAll();
    } else if (_numberOfPlaying > 0) {
      stopAll(true);
      persistence.markDirtyAndFlush();
    } else {
      if (!_isGameRunning && _inPlayHalf) {
        startTimer();
        timerButtonText = 'STOP';
      }
      // Penalty-aware, like the central START: never zero a live penalty.
      playAll(clearPenalties: false);
    }
  }

  // ---- manual clock correction (#21) ----

  /// One-time correction while the clock is stopped in a half. Floors at 1 s:
  /// an active half is never left stopped at 0:00.
  void setRemainingTime(int seconds) {
    _remainingTime = seconds.clamp(1, periodTime);
    notifyListeners();
    _broadcastStageAndTime();
    persistence.markDirtyAndFlush();
  }

  // ---- no-show penalty goals (#8) ----

  bool get noShowPenaltyGoalsActive => _noShowActive;
  String get noShowPenaltyScoringTeamName =>
      _teamById(_noShowScoringTeamId)?.name ?? '';
  String get noShowPenaltyGoalIntervalLabel {
    if (_noShowGoalInterval % 60 != 0) return '1 goal/$_noShowGoalInterval sec';
    const minutes = _noShowGoalInterval ~/ 60;
    return minutes == 1 ? '1 goal/min' : '1 goal/$minutes min';
  }

  void startNoShowPenaltyGoals(Team scoringTeam) {
    gameInit(resetModules: false);
    _noShowActive = true;
    _noShowScoringTeamId = scoringTeam.id;
    _lastNoShowGoalElapsed = 0;
    timerButtonText = 'STOP';
    startTimer();
  }

  void stopNoShowPenaltyGoals() {
    _resetNoShowPenaltyGoals();
    timerButtonText = 'START';
    stopTimer();
  }

  void _resetNoShowPenaltyGoals() {
    _noShowActive = false;
    _noShowScoringTeamId = null;
    _lastNoShowGoalElapsed = 0;
  }

  void _maybeAwardNoShowPenaltyGoal() {
    if (!_noShowActive || !_isGameRunning || !_inPlayHalf) return;
    final team = _teamById(_noShowScoringTeamId);
    if (team == null) return;
    final elapsed = periodTime - _remainingTime;
    if (elapsed <= 0 ||
        elapsed == _lastNoShowGoalElapsed ||
        elapsed % _noShowGoalInterval != 0) {
      return;
    }
    if (team.score - _opponentOf(team).score >= _maxNoShowGoalDifference) {
      return;
    }
    team.addScore(1);
    _lastNoShowGoalElapsed = elapsed;
    notifyModulesScore();
  }

  // ---- alerts ----

  /// One second of penalty countdown on every penalised robot. Never during the
  /// break: robots are off-field, and a restored `damage` module must not
  /// auto-release there.
  void notifyAllModulesTimer() {
    if (currentStage == MatchStage.halfTime) return;
    var vibrated = false;
    for (final module
        in _enabledModules.where((m) => m.state == ModuleState.damage)) {
      final before = module.penaltyTime;
      module.notifyTimer();
      if (!_replaying &&
          !vibrated &&
          vibrationService.damageTimerEnabled &&
          before > 0 &&
          vibrationService.damageTimerAlerts.contains(module.penaltyTime)) {
        vibrated = true;
        vibrationService.vibrateDamageTimer();
      }
    }
  }

  void _checkGameTimerVibration() {
    if (_replaying || !vibrationService.gameTimerEnabled) return;
    if (currentStage == MatchStage.fullTime) return;
    if (vibrationService.gameTimerAlerts.contains(_remainingTime)) {
      vibrationService.vibrateGameTimer();
    }
  }

  // Upper bound on background catch-up: only the window the clock runs
  // automatically (first half + break, or the rest of the break). The second
  // half is referee-started and is never auto-run.
  int _maxResumeCatchUpTicks() => switch (currentStage) {
        MatchStage.firstHalf => _remainingTime + halfTimeDuration,
        MatchStage.halfTime || MatchStage.secondHalf => _remainingTime,
        MatchStage.fullTime => 0,
      };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!isTimeRunning) return;
    if (state == AppLifecycleState.paused) {
      _scheduleBackgroundNotifications();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    NotificationService.cancelAll();
    final anchor = _runClockStartedAt;
    final anchorRemaining = _runClockStartRemainingTime;
    if (anchor == null || anchorRemaining == null) return;

    final elapsed = DateTime.now().difference(anchor).inSeconds;
    final alreadyApplied =
        (anchorRemaining - _remainingTime).clamp(0, anchorRemaining);
    final ticks = (elapsed - alreadyApplied).clamp(0, _maxResumeCatchUpTicks());
    _replaying = true;
    for (var i = 0; i < ticks && isTimeRunning; i++) {
      _tickTimer();
    }
    _replaying = false;
    if (ticks == 0) {
      _broadcastStageAndTime();
      notifyListeners();
    }
    // Heartbeat was suppressed during replay; flush once, unless the replay
    // reached full time (that tick already cleared the snapshot).
    if (currentStage != MatchStage.fullTime) persistence.flushNow();
  }

  void _scheduleBackgroundNotifications() {
    final vs = vibrationService;
    if (vs.gameTimerEnabled) {
      switch (currentStage) {
        case MatchStage.firstHalf:
          NotificationService.scheduleGameAlerts(
              _remainingTime, vs.gameTimerAlerts);
          // The break auto-runs after the first half, so schedule its alerts
          // too, offset past the remaining first half.
          NotificationService.scheduleBreakAlerts(
              _remainingTime + halfTimeDuration, vs.gameTimerAlerts);
        case MatchStage.halfTime:
          NotificationService.scheduleBreakAlerts(
              _remainingTime, vs.gameTimerAlerts);
        case MatchStage.secondHalf:
          NotificationService.scheduleGameAlerts(
              _remainingTime, vs.gameTimerAlerts,
              isFinalPeriod: true);
        case MatchStage.fullTime:
          break;
      }
    }
    if (vs.damageTimerEnabled) {
      for (final m in _enabledModules
          .where((m) => m.state == ModuleState.damage && m.penaltyTime > 0)) {
        NotificationService.scheduleDamageAlerts(
            m.moduleId, m.name, m.penaltyTime, vs.damageTimerAlerts);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    iosPairing.dispose();
    mqttService.dispose();
    bleBridgeService.dispose();
    wakelockService.dispose();
    scoreboardResultService.removeListener(_onScoreboardServiceUpdate);
    scoreboardResultService.disposeService();
    super.dispose();
  }

  // ---- robot fan-out (invariant #1: never await a module command) ----

  void playAll({required bool clearPenalties}) {
    for (final m in _enabledModules) {
      m.playAll(clearPenalty: clearPenalties);
    }
    notifyListeners();
  }

  void stopAll(bool removePenalty, {bool force = false}) {
    for (final m in _enabledModules) {
      m.stopAll(removePenalty, force: force);
    }
    notifyListeners();
  }

  /// Disconnect every enabled module, including ones still reconnecting or
  /// searching, so nothing the referee dismissed can come back on its own.
  void disconnectAll() {
    for (final m in _enabledModules
        .where((m) => m.isConnected || m.isConnecting || m.isSearching)) {
      m.bleDisconnect();
    }
  }

  /// Full-time teardown of modules still mid-reconnect (powered down for good).
  /// In-match these reconnects are unbounded on purpose (invariant #5).
  void disconnectInactiveModules() {
    for (final m in _enabledModules.where((m) => m.isConnecting)) {
      m.bleDisconnect();
    }
  }

  /// STOP, then after 1 s the stage-specific frame, unless the stage moved on
  /// meanwhile (the resume replay can cross stages within the delay).
  Future<void> _stopThenEnter(
      MatchStage stage, void Function(Module) enter) async {
    stopAll(true);
    await Future.delayed(const Duration(seconds: 1));
    if (currentStage != stage) return;
    _enabledModules.forEach(enter);
    notifyListeners();
  }

  void halfTimeAll() =>
      _stopThenEnter(MatchStage.halfTime, (m) => m.halfTime());
  void gameOverAll() =>
      _stopThenEnter(MatchStage.fullTime, (m) => m.gameOver());

  void halfTimeSyncTimeAll() {
    for (final m in _enabledModules.where((m) => m.isConnected)) {
      m.halfTimeSyncTime();
    }
  }

  void notifyModulesScore() {
    for (final m in _enabledModules.where((m) => m.isConnected)) {
      m.bleSendScore();
    }
    _broadcastScore();
    persistence.markDirtyAndFlush();
  }

  void resetModuleNames() {
    for (final m in _enabledModules.where((m) => m.hasCustomLabel)) {
      m.setLabel(m.defaultName);
    }
  }

  void changeNumberOfPlaying(int delta) {
    _numberOfPlaying = (_numberOfPlaying + delta).clamp(0, numberOfPlayers * 2);
    if (_numberOfPlaying < 2) notifyListeners();
  }

  // ---- sinks: MQTT + BLE bridge, always published together ----

  void _broadcastTeamInfo() {
    mqttService.publishTeamNames(teams);
    mqttService.publishTeam(teams);
  }

  void _broadcastScore() {
    mqttService.publishScore(teams);
    for (final (i, team) in teams.indexed) {
      bleBridgeService.publishTopic(BridgeTopics.score(i), '${team.score}');
      bleBridgeService.publishTopic(
          BridgeTopics.color(i), AppColors.teamHex(team.id));
    }
  }

  void _broadcastStageAndTime() {
    mqttService.publishGameState(currentStage);
    mqttService.publishTime(_remainingTime);
  }

  void broadcastFullState() {
    _broadcastStageAndTime();
    _broadcastTeamInfo();
    _broadcastScore();
  }

  // ---- settings ----

  int get periodTime => _periodTime;
  set periodTime(int value) {
    _periodTime = value;
    _prefs?.setInt(_periodTimeKey, value);
    if (currentStage == MatchStage.fullTime) {
      _remainingTime = value;
      notifyListeners();
      _broadcastStageAndTime();
    }
  }

  int get halfTimeDuration => _halfTimeDuration;
  set halfTimeDuration(int value) {
    _halfTimeDuration = value;
    _prefs?.setInt(_halfTimeDurationKey, value);
  }

  int get numberOfPlayers => _numberOfPlayers;
  set numberOfPlayers(int value) {
    _numberOfPlayers = value;
    _prefs?.setInt(_numberOfPlayersKey, value);
  }

  int get penaltyTime => _penaltyTime;
  set penaltyTime(int value) {
    _penaltyTime = value;
    _prefs?.setInt(_penaltyTimeKey, value);
  }

  /// Single-tap mode (#12). Default false = double-tap everywhere. Notifies so
  /// the Home controls swap their gesture recognizer live.
  bool get singleTapEnabled => _singleTapEnabled;
  set singleTapEnabled(bool value) {
    if (_singleTapEnabled == value) return;
    _singleTapEnabled = value;
    if (_prefs != null) {
      _prefs!.setBool(_singleTapEnabledKey, value);
    } else {
      _pendingSingleTapWrite = true;
    }
    notifyListeners();
  }

  int get remainingTime => _remainingTime;
  bool get isSomeonePlaying => _numberOfPlaying > 0;
  bool get isTimerRunning => isTimeRunning;
  bool get isGameRunning => _isGameRunning;

  /// No enabled module connected: a module double-tap records a penalty
  /// directly instead of "starting" a robot that does not exist (#22).
  bool get noModuleConnected => !_enabledModules.any((m) => m.isConnected);

  String get gameStageString => switch (currentStage) {
        MatchStage.firstHalf => '1',
        MatchStage.halfTime => 'Half-Time',
        MatchStage.secondHalf => '2',
        MatchStage.fullTime => 'Game Over',
      };

  // ---- team names / catigoal match data ----

  void loadMatchData() async {
    final match = await matchDataService.loadMatch();
    notifyListeners();
    if (match == null) return;
    teams[0].name = match.team1;
    teams[1].name = match.team2;
    mqttService.topicField = match.field;
    _broadcastTeamInfo();
    persistence.markDirtyAndFlush();
  }

  void setTeamName(Team team, String value) {
    team.name = value;
    _broadcastTeamInfo();
    persistence.markDirtyAndFlush();
  }

  // ---- presets ----

  GamePreset createPreset(String name) => GamePreset.create(
        name,
        [
          for (final m in modules)
            if (m.macAddress.isNotEmpty || m.hardwareMac.isNotEmpty)
              ModuleConfig(
                moduleId: m.moduleId,
                macAddress: m.macAddress,
                hardwareMac: m.hardwareMac,
                label: m.hasCustomLabel ? m.name : '',
              ),
        ],
      );

  void applyPreset(GamePreset preset) {
    for (final config in preset.modules) {
      final module = _moduleById(config.moduleId);
      if (module == null) continue;
      if (useIosBleUuid && config.hardwareMac.isNotEmpty) {
        // The stored connection id is this phone's best-known UUID for the MAC.
        iosPairing.seed(config.hardwareMac, config.macAddress);
        iosPairing.pairByMac(module, config.hardwareMac, label: config.label);
      } else {
        module.applyPresetConfig(config.macAddress, config.label,
            hardwareMac: config.hardwareMac);
      }
    }
    notifyListeners();
  }
}
