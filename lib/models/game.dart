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
        List.generate(_maxPlayers, (i) => Module(this, id, '$id${i + 1}', base + i)),
        id,
      ));
    }
    gameInit();
    scoreboardResultService.addListener(_onScoreboardServiceUpdate);
    scoreboardResultService.onCurrentResultDelivered = _onScoreboardResultDelivered;
    unawaited(scoreboardResultService.initialize());
    unawaited(_loadPrefs());
  }

  Future<void> _loadPrefs() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    persistence.attach(MatchStateStore(prefs));
    _periodTime = prefs.getInt(_periodTimeKey) ?? _defaultPeriodTime;
    _halfTimeDuration = prefs.getInt(_halfTimeDurationKey) ?? _defaultHalfTimeDuration;
    _numberOfPlayers = (prefs.getInt(_numberOfPlayersKey) ?? _defaultPlayersPerTeam)
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
    if (prefs == null || (prefs.getBool(_notifPermissionRequestedKey) ?? false)) {
      return;
    }
    if (!vibrationService.gameTimerEnabled && !vibrationService.damageTimerEnabled) {
      return;
    }
    prefs.setBool(_notifPermissionRequestedKey, true);
    unawaited(NotificationService.requestPermission());
  }

  // ---- lookups ----

  Iterable<Module> get modules => teams.expand((t) => t.modules);
  Iterable<Module> get _enabledModules => modules.where((m) => m.isEnabled);
  Module? _moduleById(int id) => modules.where((m) => m.moduleId == id).firstOrNull;
  Team? _teamById(String? id) => teams.where((t) => t.id == id).firstOrNull;
  Team _opponentOf(Team team) => teams.firstWhere((t) => t.id != team.id);
  bool get _inPlayHalf =>
      currentStage == MatchStage.firstHalf || currentStage == MatchStage.secondHalf;

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
        i < numberOfPlayers ? team.modules[i].enable() : team.modules[i].disable();
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
    bool stale() => !_fullTimeTeardownDone || currentStage != MatchStage.fullTime;
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
  String get noShowPenaltyScoringTeamName => _teamById(_noShowScoringTeamId)?.name ?? '';
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
    if (team.score - _opponentOf(team).score >= _maxNoShowGoalDifference) return;
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
    for (final module in _enabledModules.where((m) => m.state == ModuleState.damage)) {
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
    final alreadyApplied = (anchorRemaining - _remainingTime).clamp(0, anchorRemaining);
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
          NotificationService.scheduleGameAlerts(_remainingTime, vs.gameTimerAlerts);
          // The break auto-runs after the first half, so schedule its alerts
          // too, offset past the remaining first half.
          NotificationService.scheduleBreakAlerts(
              _remainingTime + halfTimeDuration, vs.gameTimerAlerts);
        case MatchStage.halfTime:
          NotificationService.scheduleBreakAlerts(_remainingTime, vs.gameTimerAlerts);
        case MatchStage.secondHalf:
          NotificationService.scheduleGameAlerts(_remainingTime, vs.gameTimerAlerts,
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

  // ---- cold resume (#45) ----

  MatchSnapshot _buildSnapshot() {
    final config = scoreboardResultService.matchConfig;
    // For a resumed match the bound fixture is authoritative: a different
    // fixture opened mid-match must not redefine the persisted binding.
    final configUsable = config != null &&
        config.matchCode.isNotEmpty &&
        (!_sb.isBoundToResumed || config.matchCode == _sb.resumedMatchCode);
    final liveReferee = configUsable && _sb.homeTeamId != null;
    // A resumed match whose config hasn't surfaced yet is still a referee match.
    final pendingReferee = _sb.isBoundToResumed && _sb.homeTeamId != null;
    final isReferee = liveReferee || pendingReferee;
    return MatchSnapshot(
      stage: currentStage.name,
      remainingTime: _remainingTime,
      isTimeRunning: isTimeRunning,
      inGame: inGame,
      timerButtonText: timerButtonText,
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
      isRefereeMatch: isReferee,
      scoreboardMatchCode:
          isReferee ? (liveReferee ? config.matchCode : _sb.resumedMatchCode) : null,
      scoreboardVersion:
          isReferee ? (liveReferee ? config.version : _sb.resumedVersion) : null,
      scoreboardHomeTeamId: isReferee ? _sb.homeTeamId : null,
      scoreboardAwayTeamId: isReferee ? _sb.awayTeamId : null,
      teams: teams
          .map((t) => TeamSnapshot(id: t.id, name: t.name, score: t.score))
          .toList(),
      modules: modules.map((m) => m.toSnapshot()).toList(),
    );
  }

  void _restoreTeamOrderAndInfo(List<TeamSnapshot> snaps) {
    // Game() builds [A, B]; a swapped match reversed the list. Reverse first,
    // then assign by id so names/scores land on the correct physical side.
    if (snaps.isNotEmpty && snaps.first.id == 'B' && teams.first.id == 'A') {
      teams = teams.reversed.toList();
    }
    for (final snap in snaps) {
      final team = _teamById(snap.id);
      if (team == null) continue;
      team.name = snap.name;
      team.score = snap.score;
    }
  }

  /// Restore the match the referee chose to resume: clock FROZEN at the
  /// persisted point, robots STOPPED (the break resumes running: it drives no
  /// robot play and SKIP is still available).
  void resumePendingMatch() {
    final snapshot = _pendingResume;
    if (snapshot == null) return;
    persistence.suppress(() {
      final stage = _stageFromName(snapshot.stage);
      currentStage = stage;
      inGame = true;
      _restoreTeamOrderAndInfo(snapshot.teams);

      final byId = {for (final m in snapshot.modules) m.moduleId: m};
      for (final module in modules) {
        final snap = byId[module.moduleId];
        if (snap != null) module.restoreFromSnapshot(snap);
      }
      if (useIosBleUuid) {
        // A slot saved while still awaiting its UUID: resume its resolution.
        for (final m in _enabledModules
            .where((m) => m.hardwareMac.isNotEmpty && m.macAddress.isEmpty)) {
          iosPairing.pairByMac(m, m.hardwareMac, label: m.hasCustomLabel ? m.name : '');
        }
      }
      _restoreScoreboardBinding(snapshot);

      _remainingTime = snapshot.remainingTime;
      if (stage == MatchStage.halfTime) {
        timerButtonText = 'SKIP';
        startTimer();
      } else {
        isTimeRunning = false;
        _isGameRunning = false;
        _runClockStartedAt = null;
        _runClockStartRemainingTime = null;
        timerButtonText = 'START';
      }
      broadcastFullState();
    });
    _pendingResume = null;
    persistence.flushNow();
    notifyListeners();
  }

  /// Re-arm the final-result POST for a resumed referee match (#53). Drift
  /// guard keys on match_code only: a version bump is the same fixture.
  void _restoreScoreboardBinding(MatchSnapshot snapshot) {
    final resumedCode = snapshot.scoreboardMatchCode;
    final config = scoreboardResultService.matchConfig;
    final sameOrUnknown = config == null || config.matchCode == resumedCode;
    if (!snapshot.isRefereeMatch || resumedCode == null || resumedCode.isEmpty ||
        !sameOrUnknown) {
      // Non-referee match, or a DIFFERENT fixture is loaded: never POST.
      _sb.bindResumed(homeTeamId: null, awayTeamId: null, matchCode: null, version: null);
      _sb.suppressFinalResult = snapshot.isRefereeMatch;
      return;
    }
    _sb.bindResumed(
      homeTeamId: snapshot.scoreboardHomeTeamId,
      awayTeamId: snapshot.scoreboardAwayTeamId,
      matchCode: resumedCode,
      version: snapshot.scoreboardVersion,
    );
    if (config == null) {
      // Config not loaded yet: keep the POST suppressed until it arrives.
      _sb.suppressFinalResult = true;
      return;
    }
    _sb.appliedSignature = config.signature;
    _sb.suppressFinalResult = false;
    // Seeding the signature dedupes the later apply, so set the field here.
    _applyVenueField(config);
  }

  /// Referee chose Discard: fresh match, snapshot cleared (awaited so an
  /// immediate kill can't re-offer the match).
  Future<void> discardPendingMatch() async {
    _pendingResume = null;
    gameInit();
    setTeamToDefaultOrder();
    await persistence.clearAndWait();
    notifyListeners();
  }

  /// Cold-launch restore of a referee match killed at full time before its
  /// result was submitted (RAVF003): scores, names/order and the binding only
  /// (the robots are off), then the review is re-offered.
  void _restoreFullTimeResultReview(MatchSnapshot snapshot) {
    persistence.suppress(() {
      currentStage = MatchStage.fullTime;
      inGame = true;
      timerButtonText = snapshot.timerButtonText;
      _remainingTime = snapshot.remainingTime;
      isTimeRunning = false;
      _isGameRunning = false;
      _restoreTeamOrderAndInfo(snapshot.teams);
      // Snapshot mapping: the fallback while the fixture config is not loaded.
      _sb.bindResumed(
        homeTeamId: snapshot.scoreboardHomeTeamId,
        awayTeamId: snapshot.scoreboardAwayTeamId,
        matchCode: snapshot.scoreboardMatchCode,
        version: snapshot.scoreboardVersion,
      );
      final config = scoreboardResultService.matchConfig;
      if (config != null && config.matchCode == snapshot.scoreboardMatchCode) {
        // The live config is authoritative for sides and names: an organizer
        // side-swap during the kill window must not post the wrong "home".
        _sb.deriveSides(config);
        _applyTeamNames(config);
        _sb.appliedSignature = config.signature;
        _sb.suppressFinalResult = false;
        // Arm the delivery reset directly: a RESTORED full-time match IS the
        // match its queued result belongs to, so the unresolved-result gate of
        // _enterFullTimeResultReview does not apply.
        if (_sb.canSubmit(config)) _sb.fullTimeSignature = config.signature;
        _requestScoreboardResultReview();
      } else {
        _sb.suppressFinalResult = true;
      }
      broadcastFullState();
    });
    notifyListeners();
  }

  // ---- scoreboard fixture (deep link) ----

  void _onScoreboardServiceUpdate() {
    if (scoreboardResultService.pendingMatchConfig == null) {
      _sb.promptedSignature = null;
    } else {
      _maybeFirePendingMatchPrompt();
    }
    final config = scoreboardResultService.matchConfig;
    if (config != null) {
      _applyScoreboardMatchConfig(config);
      // Pair after the apply so gameInit's enable state is settled; runs even
      // when the apply deduped, so a MAC-only refresh still pairs.
      _syncScoreboardModulePairing();
    }
    notifyListeners();
  }

  /// Raise "Load match?" exactly once per pending signature; only consumed when
  /// a callback actually fires (the draining setter re-runs this).
  void _maybeFirePendingMatchPrompt() {
    final callback = _onRequestConfirmScoreboardMatch;
    final pending = scoreboardResultService.pendingMatchConfig;
    if (callback == null || pending == null) return;
    if (_sb.promptedSignature == pending.signature) return;
    _sb.promptedSignature = pending.signature;
    callback(pending);
  }

  /// Home calls this when the "Load match?" dialog closes, so a link that
  /// arrived while it was open is prompted next.
  void onPendingMatchPromptClosed() {
    _sb.promptedSignature = null;
    _maybeFirePendingMatchPrompt();
  }

  /// Confirm the staged deep link (Home's Load button). Marks the resulting
  /// apply as a USER-CONFIRMED Load, which resets a match in progress
  /// (RAVF002); the reset's snapshot clear is awaited before returning.
  Future<void> confirmScoreboardMatch({String? expectedSignature}) async {
    final pending = scoreboardResultService.pendingMatchConfig?.signature;
    final armed = pending != null &&
        (expectedSignature == null || expectedSignature == pending);
    _sb.confirmedLoadSignature = armed ? pending : null;
    // A confirmed Load re-pairs even an unchanged MAC set (a manually
    // disconnected module must reconnect).
    if (armed) _sb.pairedMacsSignature = null;
    try {
      await scoreboardResultService.confirmPendingMatch(
          expectedSignature: expectedSignature);
      final clear = _sb.confirmedLoadClear;
      _sb.confirmedLoadClear = null;
      if (clear != null) await clear;
    } finally {
      _sb.confirmedLoadSignature = null;
      _sb.confirmedLoadClear = null;
    }
  }

  void _applyTeamNames(ScoreboardMatchConfig config) {
    // By stable id, never list position (the order may be swapped).
    for (final team in teams) {
      team.name =
          team.id == _sb.homeTeamId ? config.homeTeamName : config.awayTeamName;
    }
  }

  /// Point MQTT at the fixture's field. A venue without a number leaves a
  /// manually-set field untouched (#50). Returns true if the topic changed.
  bool _applyVenueField(ScoreboardMatchConfig config) {
    final field = fieldNumberFromVenue(config.venueShortName);
    if (field.isEmpty) return false;
    final previous = mqttService.topic;
    mqttService.topicField = field;
    return mqttService.topic != previous;
  }

  void _applyScoreboardMatchConfig(ScoreboardMatchConfig config) {
    final confirmed = _sb.confirmedLoadSignature;
    _sb.confirmedLoadSignature = null;
    final signature = config.signature;
    final isConfirmedLoad = confirmed != null && confirmed == signature && inGame;
    final suppressedResume = inGame && _sb.suppressFinalResult;

    // Dedupe an unchanged fixture, except while a resumed match still waits
    // for its own fixture's config (which may carry the same stale signature).
    if (!isConfirmedLoad && !suppressedResume && _sb.appliedSignature == signature) {
      return;
    }
    var reArmed = false;
    if (suppressedResume) {
      if (!_sb.isBoundToResumed || config.matchCode != _sb.resumedMatchCode) {
        // A DIFFERENT fixture surfaced: reject it unless the referee confirmed.
        if (!isConfirmedLoad) return;
      } else {
        reArmed = true;
      }
    }
    _sb.appliedSignature = signature;
    _sb.suppressFinalResult = false;
    _sb.deriveSides(config);
    _applyTeamNames(config);

    // A field change mid-match would otherwise leave the new retained topic
    // empty until the next event; a confirmed Load broadcasts via gameInit.
    if (_applyVenueField(config) && inGame && !isConfirmedLoad) {
      broadcastFullState();
    }

    if (!inGame) {
      _applyScoreboardTiming();
      gameInit();
      _maybeAutoConnectMqttOnMatchLoad();
    } else if (isConfirmedLoad) {
      // RAVF002: the dialog warned it replaces the match in progress.
      // gameInit before the order reset so the swap broadcasts zeroed scores.
      _applyScoreboardTiming();
      gameInit();
      setTeamToDefaultOrder();
      _sb.confirmedLoadClear = persistence.clearAndWait();
      _maybeAutoConnectMqttOnMatchLoad();
    } else if (reArmed && currentStage == MatchStage.fullTime) {
      // The bound fixture surfaced after the resumed match already ended.
      _enterFullTimeResultReview();
      _persistOrClearAtFullTime();
    }
  }

  // Live timing only; never persisted as the operator's defaults.
  void _applyScoreboardTiming() {
    _periodTime = _scoreboardHalf;
    _halfTimeDuration = _scoreboardBreak;
  }

  /// Pair the fixture's modules if its MAC set changed since the last pairing.
  /// Between matches only; [force] re-pairs after the player count loads.
  void _syncScoreboardModulePairing({bool force = false}) {
    final config = scoreboardResultService.matchConfig;
    if (config == null || inGame) return;
    final macSignature = ScoreboardBinding.macSignature(config);
    if (!force && macSignature == _sb.pairedMacsSignature) return;
    _sb.pairedMacsSignature = macSignature;

    // Home/away -> team id computed locally from homeIsLeft so pairing never
    // depends on an apply having run first. Only slots the server names are
    // touched. A same-identity re-pair preserves a referee-set label.
    final homeId = config.homeIsLeft ? 'A' : 'B';
    for (final team in teams) {
      final macs = team.id == homeId ? config.homeModuleMacs : config.awayModuleMacs;
      for (var i = 0; i < team.modules.length && i < macs.length; i++) {
        final module = team.modules[i];
        final mac = macs[i].toUpperCase();
        final sameIdentity = mac.isNotEmpty &&
            (module.hardwareMac == mac || module.macAddress.toUpperCase() == mac);
        final label = sameIdentity && module.hasCustomLabel ? module.name : '';
        if (useIosBleUuid && mac.isNotEmpty) {
          iosPairing.pairByMac(module, mac, label: label);
        } else {
          module.applyPresetConfig(macs[i], label);
        }
      }
    }
  }

  // ---- result review / submission ----

  /// "End match now" (#84) applies to a submittable fixture that has not
  /// reached full time and has no result of this run still in flight.
  bool get canEndMatchEarly {
    if (currentStage == MatchStage.fullTime) return false;
    final config = scoreboardResultService.matchConfig;
    if (config == null || config.matchCode.isEmpty) return false;
    if (!scoreboardResultService.hasToken) return false;
    if (scoreboardResultService.hasUnresolvedResultFor(config.matchCode)) return false;
    return _sb.canSubmit(config);
  }

  /// End the match NOW (forfeit) through the shared full-time transition.
  void endMatchEarly() {
    if (!canEndMatchEarly) return;
    final fromBreak = currentStage == MatchStage.halfTime;
    stopTimer();
    _remainingTime = 0;
    // An administratively ended match "happened": Home's return-from-Settings
    // and the RAVF003 snapshot both key on inGame.
    inGame = true;
    _completeMatchToFullTime(forceStop: fromBreak);
    _broadcastStageAndTime();
    notifyListeners();
  }

  bool get needsScoreboardResultReview {
    if (currentStage != MatchStage.fullTime || _sb.fullTimeSignature == null) {
      return false;
    }
    final config = scoreboardResultService.matchConfig;
    // The committed config must STILL be the fixture that just ended.
    if (config == null || config.signature != _sb.fullTimeSignature) return false;
    if (!_sb.canSubmit(config)) return false;
    // A terminal 401/422 rejection is correctable, so it keeps the review open.
    return !scoreboardResultService.hasUnresolvedResultFor(config.matchCode);
  }

  /// Inspection rows for [team]'s side of the linked fixture.
  List<InspectionRobot> inspectionRobotsForTeam(Team team) {
    final config = scoreboardResultService.matchConfig;
    if (config == null) return const [];
    if (team.id == _sb.homeTeamId) return config.homeInspectionRobots;
    if (team.id == _sb.awayTeamId) return config.awayInspectionRobots;
    return const [];
  }

  /// Capture the just-ended fixture as the review subject and raise the
  /// review. Not armed while a prior result for the same fixture is in flight
  /// (REPEAT): its late 200 must not reset the second run (RAVF001).
  void _enterFullTimeResultReview() {
    final config = scoreboardResultService.matchConfig;
    if (config != null &&
        _sb.canSubmit(config) &&
        !scoreboardResultService.hasUnresolvedResultFor(config.matchCode)) {
      _sb.fullTimeSignature = config.signature;
    }
    _requestScoreboardResultReview();
  }

  void _requestScoreboardResultReview() {
    if (needsScoreboardResultReview) _onRequestReviewScoreboardResult?.call();
  }

  /// At full time keep the snapshot only while a result can still be
  /// submitted from it (RAVF003), otherwise the match is terminal.
  void _persistOrClearAtFullTime() {
    final resumedCode = _sb.resumedMatchCode;
    // A resumed match can end while still suppressed (config not loaded):
    // keep the snapshot so the kill window stays recoverable, unless an outbox
    // item already owns this fixture's result.
    final keepSuppressed = _sb.suppressFinalResult &&
        resumedCode != null &&
        resumedCode.isNotEmpty &&
        !scoreboardResultService.hasUnresolvedResultFor(resumedCode);
    if (needsScoreboardResultReview || keepSuppressed) {
      persistence.flushNow();
    } else {
      persistence.clear();
    }
  }

  /// Home/away team ids, falling back to the config's side when unbound.
  (String home, String away) _sideTeamIds(ScoreboardMatchConfig? config) {
    final homeIsLeft = config?.homeIsLeft ?? true;
    return (
      _sb.homeTeamId ?? (homeIsLeft ? 'A' : 'B'),
      _sb.awayTeamId ?? (homeIsLeft ? 'B' : 'A'),
    );
  }

  ({
    String matchCode,
    String signature,
    String homeName,
    String awayName,
    int homeGoals,
    int awayGoals,
  }) buildScoreboardResultReview() {
    final config = scoreboardResultService.matchConfig;
    final (homeId, awayId) = _sideTeamIds(config);
    return (
      matchCode: config?.matchCode ?? '',
      signature: config?.signature ?? '',
      homeName: _teamById(homeId)?.name ?? config?.homeTeamName ?? 'Home',
      awayName: _teamById(awayId)?.name ?? config?.awayTeamName ?? 'Away',
      homeGoals: _teamById(homeId)?.score ?? 0,
      awayGoals: _teamById(awayId)?.score ?? 0,
    );
  }

  /// The actually-fielded modules of one team (#85): every enabled slot with
  /// its hardware MAC ('' when unknown) and live link state.
  List<ActualModuleReport> _actualModulesForTeam(String teamId) {
    final team = _teamById(teamId);
    if (team == null) return const [];
    return [
      for (final (i, m) in team.modules.indexed)
        if (m.isEnabled)
          ActualModuleReport(
            robot: i + 1,
            mac: ActualModuleReport.normalizeMac(m.hardwareMac.isNotEmpty
                ? m.hardwareMac
                : (isMacFormat(m.macAddress) ? m.macAddress : '')),
            connected: m.isConnected,
          ),
    ];
  }

  Future<bool> submitScoreboardResult({
    required String expectedSignature,
    required int homeGoals,
    required int awayGoals,
    String? comment,
    required bool homeConfirmed,
    required bool awayConfirmed,
  }) async {
    final config = scoreboardResultService.matchConfig;
    if (!_sb.canSubmit(config)) return false;
    // The review captured its scores for one fixture revision; refuse a
    // same-code change (side swap / version bump) so a fresh review is opened.
    if (config?.signature != expectedSignature) return false;

    // Capture sides and fielded modules BEFORE the await: a concurrent refresh
    // could flip homeIsLeft, and a retry must report submit-time state.
    final (homeId, awayId) = _sideTeamIds(config);
    final trimmed = comment?.trim();
    final submitted = await scoreboardResultService.enqueueFinalResult(
      homeGoals: homeGoals,
      awayGoals: awayGoals,
      comment: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      homeConfirmed: homeConfirmed,
      awayConfirmed: awayConfirmed,
      actualHomeModules: _actualModulesForTeam(homeId),
      actualAwayModules: _actualModulesForTeam(awayId),
    );
    if (submitted) {
      // Write the (possibly corrected) scores back so a terminal rejection
      // re-opens the review with them (RAVF004); durable before returning.
      _teamById(homeId)?.score = homeGoals;
      _teamById(awayId)?.score = awayGoals;
      await persistence.flushNowAndWait();
    }
    return submitted;
  }

  /// The service confirmed delivery (HTTP 200) of the current match's result.
  /// Only reset while still on the exact full-time match it belongs to (a
  /// REPEAT moved the stage and cleared the signature); deferred because it
  /// fires from inside the service's outbox loop.
  void _onScoreboardResultDelivered() {
    if (currentStage != MatchStage.fullTime || _sb.fullTimeSignature == null) return;
    scheduleMicrotask(_resetAfterScoreboardSubmission);
  }

  /// Clean start state after a delivered result: modules disconnected, default
  /// names/order/timing, fixture unlinked (outbox kept as audit), snapshot gone.
  void _resetAfterScoreboardSubmission() {
    disconnectAll();
    for (final team in teams) {
      team.name = '';
    }
    _sb.unbind();
    _periodTime = _prefs?.getInt(_periodTimeKey) ?? _defaultPeriodTime;
    _halfTimeDuration = _prefs?.getInt(_halfTimeDurationKey) ?? _defaultHalfTimeDuration;
    setTeamToDefaultOrder();
    gameInit();
    unawaited(scoreboardResultService.resetLinkedMatchAfterSubmission());
    persistence.clear();
    notifyListeners();
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
  Future<void> _stopThenEnter(MatchStage stage, void Function(Module) enter) async {
    stopAll(true);
    await Future.delayed(const Duration(seconds: 1));
    if (currentStage != stage) return;
    _enabledModules.forEach(enter);
    notifyListeners();
  }

  void halfTimeAll() => _stopThenEnter(MatchStage.halfTime, (m) => m.halfTime());
  void gameOverAll() => _stopThenEnter(MatchStage.fullTime, (m) => m.gameOver());

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
      bleBridgeService.publishTopic(BridgeTopics.color(i), AppColors.teamHex(team.id));
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
