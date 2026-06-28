import 'package:flutter/widgets.dart';
import 'package:rcj_scoreboard/models/bridge_message.dart';
import 'package:rcj_scoreboard/models/module.dart';
import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'dart:async';
import 'package:rcj_scoreboard/models/team.dart';
import 'package:rcj_scoreboard/services/ble_adapter_monitor.dart';
import 'package:rcj_scoreboard/services/ble_bridge_service.dart';
import 'package:rcj_scoreboard/services/mqtt.dart';
import 'package:rcj_scoreboard/services/match_data.dart';
import 'package:rcj_scoreboard/services/notification_service.dart';
import 'package:rcj_scoreboard/services/vibration_service.dart';
import 'package:rcj_scoreboard/services/wakelock_service.dart';
import 'package:rcj_scoreboard/services/preset_service.dart';
import 'package:rcj_scoreboard/services/scoreboard_result_service.dart';
import 'package:rcj_scoreboard/services/match_state_store.dart';
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
  static const String _singleTapEnabledKey = 'gesture_single_tap_enabled';
  static const String _notifPermissionRequestedKey =
      'notif_permission_requested';

  String timerButtonText = 'START';
  final int _maxPlayer = 5;
  List<Team> teams = [];
  int _numberOfPlayers = 2;
  int _remainingTime = 0;
  int _penaltyTime = 60;
  int _periodTime = 600;
  int _halfTimeDuration = 300;
  bool _isGameRunning = false;
  bool inGame = false;
  bool isTimeRunning = false;
  int _numberOfPlaying = 0;
  MatchStage currentStage = MatchStage.firstHalf;
  Timer? _timer;
  DateTime? _runClockStartedAt;
  int? _runClockStartRemainingTime;
  // True only while the resume catch-up loop is replaying missed ticks in one
  // synchronous burst, so per-tick vibrations are suppressed (otherwise every
  // threshold crossed while backgrounded buzzes at once on return). State, MQTT
  // and module updates still run during replay.
  bool _replaying = false;
  // Single-tap gesture mode (issue #12). Default false => double-tap everywhere,
  // preserving the accidental-touch protection invariant. _pendingSingleTapWrite
  // guards the load-timing race: _loadPrefs() runs unawaited, so a toggle made
  // before it resolves must not be clobbered by the stored default (see setter
  // and _loadPrefs).
  bool _singleTapEnabled = false;
  bool _pendingSingleTapWrite = false;
  SharedPreferences? _prefs;

  // ---- Match cold-resume persistence (#45) ----
  MatchStateStore? _stateStore;
  // Coalesced persist marker: set on any recoverable change (trivial bool, safe
  // on the robot-command path); the snapshot build + jsonEncode happen later in
  // a flush, never inline on the START/STOP fan-out.
  bool _dirty = false;
  // Suppresses persistence during bootstrap/reset and during the multi-step
  // cold-resume restore, so an internal (non-referee) reset can't overwrite the
  // on-disk snapshot and a restore can't write a dozen partial snapshots.
  bool _suppressPersist = false;
  // The snapshot of an in-progress match found at cold launch, awaiting the
  // referee's Resume/Discard choice. Null when there is nothing to resume.
  MatchSnapshot? _pendingResume;
  // One-shot so the resume prompt fires exactly once (guards the
  // snapshot-stashed vs callback-registered race in _maybeFireResumePrompt).
  bool _resumePrompted = false;
  //MQTT
  MqttService mqttService = MqttService();
  BleBridgeService bleBridgeService = BleBridgeService();
  final BleAdapterMonitor bleAdapterMonitor = BleAdapterMonitor();
  MatchDataService matchDataService = MatchDataService();
  VibrationService vibrationService = VibrationService();
  WakelockService wakelockService = WakelockService();
  ScoreboardResultService scoreboardResultService = ScoreboardResultService();
  String? _lastAppliedScoreboardSignature;
  String? _scoreboardHomeTeamId;
  String? _scoreboardAwayTeamId;
  bool _suppressScoreboardFinalResult = false;
  // Identity of the fixture a RESUMED referee match is bound to (#53). Set on
  // resume (even when the binding is suppressed because the config has not
  // surfaced yet) so (a) a later-arriving config for the SAME fixture can re-arm
  // the final-result POST instead of being blocked forever by the suppress
  // latch, and (b) _buildSnapshot keeps re-persisting the binding through the
  // suppressed window, so a second kill before the config loads doesn't lose it.
  String? _resumedFixtureMatchCode;
  int? _resumedFixtureVersion;

  // Callback to request showing the dialog
  void Function()? onRequestSwitchTeamOrderDialog;

  // Callback to request showing the cold-resume prompt. A DRAINING setter:
  // main.dart constructs Game() before runApp and _loadPrefs() is async, so the
  // snapshot may be stashed before OR after Home registers this callback. On
  // assignment we fire immediately if a resume is already pending, so whichever
  // happens last triggers the prompt (guarded once by _resumePrompted).
  void Function()? _onRequestResumeMatch;
  void Function()? get onRequestResumeMatch => _onRequestResumeMatch;
  set onRequestResumeMatch(void Function()? callback) {
    _onRequestResumeMatch = callback;
    _maybeFireResumePrompt();
  }

  /// The match awaiting a Resume/Discard decision (null if none). Read by the
  /// home screen to render the prompt body (teams, score, stage, staleness).
  MatchSnapshot? get pendingResume => _pendingResume;

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
    scoreboardResultService.addListener(_onScoreboardServiceUpdate);
    unawaited(scoreboardResultService.initialize());
    unawaited(_loadPrefs());
  }

  Future<void> _loadPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    _stateStore = MatchStateStore(_prefs!);
    _periodTime = _prefs!.getInt(_periodTimeKey) ?? 600;
    _halfTimeDuration = _prefs!.getInt(_halfTimeDurationKey) ?? 300;
    _numberOfPlayers =
        (_prefs!.getInt(_numberOfPlayersKey) ?? 2).clamp(1, _maxPlayer).toInt();
    _penaltyTime = _prefs!.getInt(_penaltyTimeKey) ?? 60;

    // Single-tap pref: flush a pre-load toggle if one happened, otherwise adopt
    // the stored value. Reading unconditionally would clobber an early toggle.
    if (_pendingSingleTapWrite) {
      _prefs!.setBool(_singleTapEnabledKey, _singleTapEnabled);
      _pendingSingleTapWrite = false;
    } else {
      _singleTapEnabled = _prefs!.getBool(_singleTapEnabledKey) ?? false;
    }

    // Load any in-progress-match snapshot BEFORE the bootstrap gameInit() so the
    // bootstrap can't clobber it. gameInit() no longer clears the snapshot, and
    // its internal stopTimer() is a persist chokepoint, so wrap the bootstrap in
    // _suppressPersist — otherwise it would overwrite the snapshot with the
    // default (inGame=false) state via that indirect path.
    final snapshot = _stateStore!.load();
    if (!inGame) {
      _suppressPersist = true;
      try {
        gameInit();
      } finally {
        _suppressPersist = false;
      }
    }

    // A usable in-progress match (not already finished) → stash and prompt the
    // referee. Stage fullTime means the match was over, so nothing to resume.
    if (snapshot != null &&
        snapshot.inGame &&
        _stageFromName(snapshot.stage) != MatchStage.fullTime) {
      _pendingResume = snapshot;
      _maybeFireResumePrompt();
    }

    // Prompt for notification permission once on first launch (one-shot), now
    // that _prefs is available — keeps the OS dialog off the match-start path.
    _maybeRequestNotificationPermission();
    notifyListeners();
  }

  void _maybeFireResumePrompt() {
    if (_resumePrompted) return;
    if (_pendingResume == null) return;
    final callback = _onRequestResumeMatch;
    if (callback == null) return;
    _resumePrompted = true;
    callback();
  }

  void gameInit() {
    currentStage = MatchStage.firstHalf;
    _remainingTime = periodTime;
    isTimeRunning = false;
    _isGameRunning = false;
    timerButtonText = 'START';
    inGame = false;
    _suppressScoreboardFinalResult = false;
    _resumedFixtureMatchCode = null;
    _resumedFixtureVersion = null;

    stopTimer();

    // enable or disable players based on player number;
    for (var team in teams) {
      team.score = 0;
      for (var i = 0; i < _maxPlayer; i++) {
        i < numberOfPlayers
            ? team.modules[i].enable()
            : team.modules[i].disable();
        team.modules[i].init();
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

  // ---- Match cold-resume persistence (#45) ----

  /// Mark the match state dirty. Trivial bool set, intentionally cheap so it is
  /// safe to call from anywhere — including the robot-command fan-out — without
  /// touching the START/STOP latency invariant. No snapshot build, no JSON.
  /// No-op before the store exists (constructor bootstrap) or while suppressed.
  void markMatchStateDirty() {
    if (_suppressPersist || _stateStore == null) return;
    _dirty = true;
  }

  /// Mark dirty and schedule a coalesced flush AFTER the current synchronous
  /// work has run, via scheduleMicrotask — so the snapshot build + jsonEncode
  /// never run inline on the caller's frame. This is deliberate: callers like
  /// [Module.setLabel]/[Module.play] are reached from within larger synchronous
  /// operations, and the microtask hop keeps the build off that frame even
  /// though no current caller sits on the START/STOP fan-out itself (those use
  /// the bare flag [markMatchStateDirty]). Use [_flushMatchStateNow] when an
  /// immediate synchronous flush is wanted (heartbeat tick / resume commit).
  void _markDirtyFlush() {
    if (_suppressPersist || _stateStore == null) return;
    _dirty = true;
    scheduleMicrotask(_persistMatchState);
  }

  /// Public entry for off-hot-path collaborators (e.g. [Module.setLabel]) that
  /// want a change scheduled to disk now, not merely flagged for the next
  /// heartbeat. Never call from a robot-command path.
  void markMatchStateDirtyAndFlush() => _markDirtyFlush();

  /// Force an immediate, synchronous flush of the current state. `_dirty` alone
  /// is not enough — [_persistMatchState] no-ops unless dirty — so the two are
  /// always paired; this helper makes that contract explicit at every call site.
  void _flushMatchStateNow() {
    markMatchStateDirty();
    _persistMatchState();
  }

  /// Public clear for intentional fresh-start paths outside the resume flow
  /// (e.g. Settings "Reset current game"). gameInit() deliberately does not
  /// clear the snapshot, so those paths must clear it explicitly or a killed
  /// app would re-offer the reset match on next launch. Awaitable so a caller
  /// can confirm the clear landed (the destructive intent should not be lost on
  /// an immediate kill).
  Future<void> clearMatchSnapshot() => _clearMatchStateAndWait();

  /// Build the snapshot (if dirty) and enqueue the save. A no-op unless dirty,
  /// the store exists, and persistence isn't suppressed.
  void _persistMatchState() {
    if (_suppressPersist) return;
    if (!_dirty) return;
    final store = _stateStore;
    if (store == null) return;
    _dirty = false;
    unawaited(store.save(_buildSnapshot()));
  }

  /// Clear the persisted match (end of match / fresh start / discard). Drops the
  /// dirty flag so a pending flush can't immediately re-save, and tombstones the
  /// snapshot in the store.
  void _clearMatchState() {
    _dirty = false;
    unawaited(_stateStore?.clear());
  }

  /// Same as [_clearMatchState] but awaitable, for destructive UI paths that
  /// want to confirm the clear landed before dismissing.
  Future<void> _clearMatchStateAndWait() async {
    _dirty = false;
    await _stateStore?.clear();
  }

  MatchSnapshot _buildSnapshot() {
    final config = scoreboardResultService.matchConfig;
    final resumedCode = _resumedFixtureMatchCode;
    final boundToResumed = resumedCode != null && resumedCode.isNotEmpty;
    // For a RESUMED match the bound fixture is authoritative: the live config may
    // be a DIFFERENT fixture opened mid-match (rejected by the suppress guard in
    // _applyScoreboardMatchConfig but still held by the service), so it must NOT
    // define the persisted binding — otherwise a second kill would resume bound
    // to the wrong fixture and POST this match's scores against it.
    // A referee binding also needs a non-empty match code: it is the stable
    // fixture identity the drift guard and final-result POST key on. An empty
    // code (server omitted match_code) is not a submittable fixture.
    final configUsable = config != null &&
        config.matchCode.isNotEmpty &&
        (!boundToResumed || config.matchCode == resumedCode);
    final liveReferee = configUsable && _scoreboardHomeTeamId != null;
    // A resumed match whose fixture config hasn't surfaced yet is still a
    // referee match: persist its binding so a second kill in that load window
    // doesn't downgrade it to a plain match (which would silently drop the POST).
    final pendingReferee = boundToResumed && _scoreboardHomeTeamId != null;
    final isReferee = liveReferee || pendingReferee;
    final boundCode = liveReferee ? config.matchCode : resumedCode;
    final boundVersion = liveReferee ? config.version : _resumedFixtureVersion;
    return MatchSnapshot(
      stage: currentStage.name,
      remainingTime: _remainingTime,
      isTimeRunning: isTimeRunning,
      inGame: inGame,
      timerButtonText: timerButtonText,
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
      isRefereeMatch: isReferee,
      scoreboardMatchCode: isReferee ? boundCode : null,
      scoreboardVersion: isReferee ? boundVersion : null,
      scoreboardHomeTeamId: isReferee ? _scoreboardHomeTeamId : null,
      scoreboardAwayTeamId: isReferee ? _scoreboardAwayTeamId : null,
      teams: teams
          .map((t) => TeamSnapshot(id: t.id, name: t.name, score: t.score))
          .toList(),
      modules:
          teams.expand((t) => t.modules).map((m) => m.toSnapshot()).toList(),
    );
  }

  MatchStage _stageFromName(String name) => MatchStage.values.firstWhere(
        (s) => s.name == name,
        orElse: () => MatchStage.firstHalf,
      );

  /// Restore the match the referee chose to resume: full state, clock FROZEN at
  /// the persisted freeze point (no dead-time subtraction), robots STOPPED.
  /// Runs under _suppressPersist so it writes no partial snapshots; the single
  /// committed save happens after the scope closes.
  void resumePendingMatch() {
    final snapshot = _pendingResume;
    if (snapshot == null) return;

    _suppressPersist = true;
    try {
      final stage = _stageFromName(snapshot.stage);
      currentStage = stage;
      inGame = true;

      _restoreTeamOrderAndInfo(snapshot.teams);

      // Restore full per-module state (matched by stable moduleId). Late async
      // reconnects mutate only connection status (not a persisted field), so
      // they don't each trigger a save.
      final byId = {for (final m in snapshot.modules) m.moduleId: m};
      for (final team in teams) {
        for (final module in team.modules) {
          final moduleSnap = byId[module.moduleId];
          if (moduleSnap != null) module.restoreFromSnapshot(moduleSnap);
        }
      }

      // Restore the scoreboard binding (#53) so a resumed referee match still
      // fires the correct final-result POST at full-time. Drift guard: only
      // re-arm if the separately-persisted match config still matches the
      // fixture this match was bound to. If a newer deep link replaced the
      // config (or none is loaded), do NOT treat the resumed match as a referee
      // match - avoids POSTing against the wrong fixture.
      // Drift guard keys on match_code ONLY (the stable fixture identity), not
      // version: an organizer edit during the kill window bumps the version of
      // the SAME fixture, and enqueueFinalResult submits the live config version
      // anyway, so a version-only difference must NOT be treated as drift.
      final resumedCode = snapshot.scoreboardMatchCode;
      final config = scoreboardResultService.matchConfig;
      if (snapshot.isRefereeMatch &&
          resumedCode != null &&
          resumedCode.isNotEmpty &&
          !(config != null && config.matchCode != resumedCode)) {
        // Same fixture, or its config hasn't surfaced yet (loaded by a separate
        // unawaited initialize() that may lose the race with the Resume tap).
        // Restore the binding from the snapshot so it stays persisted (survives
        // another kill in the load window). Remember the fixture identity so
        // _buildSnapshot keeps re-persisting it and _applyScoreboardMatchConfig
        // re-arms when this fixture's config arrives.
        _scoreboardHomeTeamId = snapshot.scoreboardHomeTeamId;
        _scoreboardAwayTeamId = snapshot.scoreboardAwayTeamId;
        _resumedFixtureMatchCode = resumedCode;
        _resumedFixtureVersion = snapshot.scoreboardVersion;
        if (config != null) {
          // Matching config is present → arm the POST now.
          _lastAppliedScoreboardSignature =
              '${config.matchCode}:${config.version}:${config.durationSeconds}:'
              '${config.homeIsLeft ? 'L' : 'R'}:'
              '${config.homeTeamName}:${config.awayTeamName}';
          _suppressScoreboardFinalResult = false;
        } else {
          // Config not loaded yet → keep the POST suppressed until it arrives.
          _suppressScoreboardFinalResult = true;
        }
      } else {
        // Non-referee match, or true drift (a DIFFERENT fixture is loaded):
        // drop the binding entirely so we never POST against the wrong fixture.
        _scoreboardHomeTeamId = null;
        _scoreboardAwayTeamId = null;
        _resumedFixtureMatchCode = null;
        _resumedFixtureVersion = null;
        _suppressScoreboardFinalResult = snapshot.isRefereeMatch;
      }

      _remainingTime = snapshot.remainingTime;

      if (stage == MatchStage.halfTime) {
        // Resume the break RUNNING (option i): the half-time break drives no
        // robot play, so freezing it would strand the remaining break with no
        // way to continue. SKIP still lets the referee jump to the second half.
        timerButtonText = 'SKIP';
        startTimer();
      } else {
        // firstHalf / secondHalf: freeze where it died, robots stopped. The
        // referee resumes play manually via the existing double-tap START.
        isTimeRunning = false;
        _isGameRunning = false;
        _runClockStartedAt = null;
        _runClockStartRemainingTime = null;
        timerButtonText = 'START';
      }

      _broadcastFullState();
    } finally {
      _suppressPersist = false;
    }

    _pendingResume = null;
    // Commit the restored state ONCE, now that the suppress scope has closed (a
    // flush while suppressed is a no-op).
    _flushMatchStateNow();
    notifyListeners();
  }

  /// Referee chose Discard: fresh match and clear the persisted snapshot.
  /// Awaits the clear so the destructive flow doesn't dismiss while a failed/
  /// pending tombstone could still re-offer the match on next launch (this is a
  /// dialog action, not a robot-command path, so the await is safe).
  Future<void> discardPendingMatch() async {
    _pendingResume = null;
    gameInit();
    setTeamToDefaultOrder();
    await _clearMatchStateAndWait();
    notifyListeners();
  }

  void _restoreTeamOrderAndInfo(List<TeamSnapshot> teamSnaps) {
    // Game() always builds teams as [A, B]. A swapped match was reordered by
    // toggleTeamOrder() reversing the list, and _teamColorHex + the UI color
    // bars are keyed on team.id, so reverse the live list first when the
    // snapshot's first team is 'B', THEN assign names/scores by matching id
    // (never positionally) so they land on the correct physical side.
    if (teamSnaps.isNotEmpty &&
        teamSnaps.first.id == 'B' &&
        teams.length == 2 &&
        teams.first.id == 'A') {
      teams = teams.reversed.toList();
    }
    for (final snap in teamSnaps) {
      final matches = teams.where((t) => t.id == snap.id);
      if (matches.isEmpty) continue;
      final team = matches.first;
      team.name = snap.name;
      team.score = snap.score;
    }
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
    _markDirtyFlush();
  }

  void _tickTimer() {
    if (_remainingTime > 0) {
      _remainingTime--;
      _checkGameTimerVibration();
      notifyAllModulesTimer();
      mqttService.publishTime(_remainingTime);
      // ~5 s heartbeat for the clock freeze point. Placed only in the normal
      // decrement branch (before any stage-transition reset below), so the % 5
      // test never samples a freshly-reset boundary value. Skipped during the
      // warm-resume replay burst. Direct flush (not microtask): the 1 Hz tick is
      // a low-frequency callback, not a command path.
      if (!_replaying && _remainingTime % 5 == 0) {
        _flushMatchStateNow();
      }
    }

    if (_remainingTime <= 0) {
      _isGameRunning = false;
      isTimeRunning = false;
      _timer?.cancel();

      switch (currentStage) {
        case MatchStage.firstHalf:
          currentStage = MatchStage.halfTime;
          _remainingTime = halfTimeDuration;
          startTimer();
          timerButtonText = 'SKIP';
          halfTimeAll();
          _markDirtyFlush();
          // Trigger the callback to show the dialog
          if (onRequestSwitchTeamOrderDialog != null) {
            onRequestSwitchTeamOrderDialog!();
          }
          break;
        case MatchStage.halfTime:
          currentStage = MatchStage.secondHalf;
          _remainingTime = periodTime;
          stopAll(true, force: true);
          timerButtonText = 'START';
          _markDirtyFlush();
          break;
        case MatchStage.secondHalf:
          currentStage = MatchStage.fullTime;
          stopAll(true);
          timerButtonText = 'REPEAT';
          gameOverAll();
          _queueFinalResultSubmission();
          // The match is over: stop the OS autoConnect from chasing modules
          // that are powered down for good (e.g. a unit still off from a
          // late penalty). In-match these reconnect unbounded on purpose; at
          // full time we settle the ones still off to "Disconnected".
          disconnectInactiveModules();
          // Match just ended: clear the snapshot rather than persisting a
          // fullTime one (item 2 made this transition a persist point).
          _clearMatchState();
          break;
        default:
          debugPrint('unknown match stage');
      }

      _broadcastStageAndTime();
    }

    if (currentStage == MatchStage.halfTime && _remainingTime % 30 == 0) {
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
        stopAll(false);
      } else {
        timerButtonText = 'STOP';
        startTimer();
        playAll(false);
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
      stopAll(true, force: true);
      timerButtonText = 'START';

      _broadcastStageAndTime();

      notifyListeners();
      _markDirtyFlush();
    } else {
      // GAME OVER — starting a brand-new match, so clear the (fullTime)
      // snapshot. gameInit() must NOT clear it itself (it also runs on every
      // cold launch, before the resume path reads the snapshot). Clear LAST so
      // the scheduled flushes from gameInit()/notifyModulesScore() see a clean
      // dirty flag and don't re-write a snapshot after the clear.
      gameInit();
      setTeamToDefaultOrder();
      notifyListeners();
      notifyModulesScore();
      _clearMatchState();
    }
  }

  void toggleTeamOrder() {
    teams = teams.reversed.toList();

    notifyListeners();

    // Push swapped names/team/score+color to every sink immediately, otherwise
    // the bridge only reflects the new sides on the next goal.
    _broadcastTeamInfo();
    _broadcastScore();

    _markDirtyFlush();
  }

  /// Toggles all modules based on the current game stage.
  void toggleAllModules() {
    if (currentStage == MatchStage.fullTime) {
      disconnectAll();
    } else if (_numberOfPlaying > 0) {
      stopAll(true);
      // Master STOP clears penalties and changes module state without touching
      // the match clock, so the heartbeat may not be running; schedule a flush
      // (off the command path) so a crash right after STOP can't restore stale
      // penalties.
      _markDirtyFlush();
    } else {
      if (!_isGameRunning &&
          (currentStage == MatchStage.firstHalf ||
              currentStage == MatchStage.secondHalf)) {
        startTimer();
        timerButtonText = 'STOP';
      }
      // Penalty-preserve fix (#45): penalty-aware start, matching the central
      // timer START (toggleTimer -> playAll(false)). playAll(true) ->
      // Module.playAll()/play() would ZERO an active/restored _penaltyTime; the
      // master STOP still clears penalties (intended post-goal reset).
      playAll(false);
    }
  }

  void resetModuleNames(){
    for (var team in teams) {
      for (var module in team.modules.where((module) => module.isEnabled && module.hasCustomLabel)) {
        module.setLabel(module.defaultName);
      }
    }
  }

  void notifyAllModulesTimer() {
    // Penalties are a match-time concept; robots are off-field during the
    // half-time break, so never count a penalty down (and never auto-release it
    // via play()) while in halfTime. Normally modules are in halfTime state here
    // so the loop is a no-op anyway, but a cold resume can restore a module in
    // damage (a penalty given during the break) — guard against auto-PLAY there.
    if (currentStage == MatchStage.halfTime) return;

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
    _markDirtyFlush();
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
        // The per-tick heartbeat was suppressed during the replay burst, so
        // flush ONCE now — otherwise a crash right after a warm resume would
        // persist the stale pre-background freeze point and over-credit time on
        // the next cold resume. But if the replay reached fullTime, the
        // secondHalf->fullTime tick already CLEARED the snapshot; don't re-save a
        // terminal match (it would undo the clear-on-fullTime contract).
        if (currentStage != MatchStage.fullTime) {
          _flushMatchStateNow();
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
    mqttService.dispose();
    bleBridgeService.dispose();
    wakelockService.dispose();
    scoreboardResultService.removeListener(_onScoreboardServiceUpdate);
    scoreboardResultService.disposeService();
    super.dispose();
  }

  void _onScoreboardServiceUpdate() {
    final config = scoreboardResultService.matchConfig;
    if (config != null) {
      _applyScoreboardMatchConfig(config);
    }
    notifyListeners();
  }

  void _applyScoreboardMatchConfig(ScoreboardMatchConfig config) {
    final homeIsLeft = config.homeIsLeft;
    // Team names are part of the signature so a corrected schedule payload that
    // changes only a name (without bumping version/duration/side) still updates
    // the displayed names; the `if (!inGame)` guard below still gates timing.
    final signature =
        '${config.matchCode}:${config.version}:${config.durationSeconds}:${homeIsLeft ? 'L' : 'R'}:${config.homeTeamName}:${config.awayTeamName}';
    // Dedupe on an unchanged signature - EXCEPT while a resumed match is still
    // suppressed. `_lastAppliedScoreboardSignature` is in-memory and is never
    // cleared when the service drops `_matchConfig` to null (a token-changing
    // deep link or clearLinkedMatchData), so a suppressed resume can carry a
    // stale signature for its own fixture. If that same fixture's config then
    // re-arrives, an early dedupe return here would skip the re-arm below and
    // leave the final result suppressed forever (#53). While suppressed, fall
    // through to the re-arm guard, which re-arms the bound fixture or rejects a
    // different one.
    if (!(inGame && _suppressScoreboardFinalResult) &&
        _lastAppliedScoreboardSignature == signature) {
      return;
    }
    var reArmedFromSuppression = false;
    if (inGame && _suppressScoreboardFinalResult) {
      // A resumed match's final result is suppressed until its bound fixture's
      // config arrives. Re-arm ONLY for that same fixture (the unawaited config
      // load that lost the race with the Resume tap); any OTHER config must not
      // silently retarget a live match's final result.
      final resumedCode = _resumedFixtureMatchCode;
      if (resumedCode == null ||
          resumedCode.isEmpty ||
          config.matchCode != resumedCode) {
        return;
      }
      reArmedFromSuppression = true;
    }
    _lastAppliedScoreboardSignature = signature;
    _suppressScoreboardFinalResult = false;
    _scoreboardHomeTeamId = homeIsLeft ? 'A' : 'B';
    _scoreboardAwayTeamId = homeIsLeft ? 'B' : 'A';

    // Assign names by stable team ID, not by list position. If this re-runs
    // while the order is swapped (e.g. the version bump after a successful
    // submit re-applies the config at full-time), a positional assignment would
    // scramble the names onto the wrong teams. The score mapping already keys on
    // the team ID (_scoreboardHomeTeamId), so naming by ID keeps names and
    // scores consistent regardless of side.
    for (final team in teams) {
      team.name = team.id == _scoreboardHomeTeamId
          ? config.homeTeamName
          : config.awayTeamName;
    }

    // Apply the match's field number to the MQTT topic. This reuses the catigoal
    // field-extraction rule (`fieldNumberFromVenue`, shared with
    // `Match.fromJson`) but deliberately does NOT mirror `loadMatchData`'s
    // unconditional assignment: when the venue carries no number (e.g. "Center
    // Court") we leave the existing field untouched so a manually-set field is
    // preserved, instead of publishing to a bare "field_" (#50). Do not remove
    // this guard to "match" the catigoal path — the guard is the fix.
    final venueField = fieldNumberFromVenue(config.venueShortName);
    if (venueField.isNotEmpty) {
      mqttService.topicField = venueField;
    }

    // Apply remote timing presets only before a match starts (between matches,
    // after a reset). Never call gameInit() at full-time: a version-only update
    // from a successful result submission would otherwise zero the just-played
    // scores and broadcast a reset 0-0/first-half state over MQTT and the BLE
    // bridge. The full-time clock display stays in sync separately via the
    // periodTime setter when settings change.
    if (!inGame) {
      periodTime = config.durationSeconds;
      gameInit();
    } else if (reArmedFromSuppression &&
        currentStage == MatchStage.fullTime) {
      // The bound fixture's config only surfaced AFTER this resumed match had
      // already run to full-time while suppressed. The sole
      // _queueFinalResultSubmission() call site (the secondHalf -> fullTime
      // tick) returned early because the result was suppressed and the config
      // was absent, so nothing was ever queued and the snapshot was already
      // cleared - the result would be lost forever (#53). Now that the bound
      // fixture's config is here, submit it. enqueueFinalResult is idempotent
      // per match_code, so this is safe even if an item somehow already exists.
      _queueFinalResultSubmission();
    }
  }

  void _queueFinalResultSubmission() {
    final config = scoreboardResultService.matchConfig;
    // Final gate before the POST: need a submittable fixture (non-empty code)
    // and a non-suppressed binding.
    if (config == null || config.matchCode.isEmpty) return;
    if (_suppressScoreboardFinalResult) return;
    // A resumed match is bound to its fixture: never POST if the live config has
    // drifted to a different fixture (e.g. a deep link opened mid-match). Belt-
    // and-suspenders with the suppress guard above.
    final resumedCode = _resumedFixtureMatchCode;
    if (resumedCode != null &&
        resumedCode.isNotEmpty &&
        config.matchCode != resumedCode) {
      return;
    }

    final defaultHomeTeamId = config.homeIsLeft ? 'A' : 'B';
    final defaultAwayTeamId = config.homeIsLeft ? 'B' : 'A';
    final homeGoals = _scoreByTeamId(_scoreboardHomeTeamId ?? defaultHomeTeamId) ?? 0;
    final awayGoals = _scoreByTeamId(_scoreboardAwayTeamId ?? defaultAwayTeamId) ?? 0;

    unawaited(scoreboardResultService.enqueueFinalResult(
      homeGoals: homeGoals,
      awayGoals: awayGoals,
      comment: 'Submitted via RCJ Soccer RefMate',
    ));
  }

  int? _scoreByTeamId(String? teamId) {
    if (teamId == null) return null;
    for (final team in teams) {
      if (team.id == teamId) return team.score;
    }
    return null;
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
      // Include modules that are mid-reconnect (isConnecting), not just
      // currently-connected ones: issue #38 added a reconnecting state where
      // isConnected is false while autoConnect keeps retrying. Without this a
      // "disconnect all" would skip those modules, leaving them retrying and
      // later consuming GATT slots after the referee asked to disconnect.
      for (var module in team.modules.where(
          (module) => module.isEnabled && (module.isConnected || module.isConnecting))) {
        module.bleDisconnect();
      }
    }
  }

  // Tear down modules that are mid-reconnect (off / "Connecting...") so the OS
  // autoConnect installed by connect(autoConnect:true) stops chasing a unit
  // that is powered down for good. Connected modules are left alone (they show
  // game-over until the referee disconnects). Used at the full-time transition
  // — during a match these reconnects are unbounded on purpose (invariant #5).
  void disconnectInactiveModules() {
    for (var team in teams) {
      for (var module in team.modules.where(
          (module) => module.isEnabled && module.isConnecting)) {
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
    _markDirtyFlush();
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
    if (_numberOfPlaying > numberOfPlayers * 2) {
      _numberOfPlaying = numberOfPlayers * 2;
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
    if (currentStage == MatchStage.fullTime) {
      _remainingTime = value;
      notifyListeners();
      _broadcastStageAndTime();
    }
  }

  // Single-tap gesture mode (issue #12). Unlike periodTime, this setter MUST
  // notifyListeners() so the Home control buttons swap their gesture recognizer
  // live on toggle. The pending-write guard handles a toggle made before
  // _loadPrefs() resolves (see _loadPrefs).
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

  int get remainingTime => _remainingTime;

  // Manual correction of the remaining match time (issue #21), e.g. to give
  // back playing time lost to a stoppage. The UI only opens the editor while
  // the clock is stopped within an active first or second half
  // (Home._editRemainingTime), so the run-clock catch-up anchors
  // (_runClockStartedAt / _runClockStartRemainingTime) are already null and
  // need no reconciliation, and both editable stages cap at periodTime. This is
  // a one-time correction, not a tick: it does NOT call notifyAllModulesTimer()
  // (that decrements module damage timers) and does NOT trigger game-timer
  // vibration. Publishes stage+time to every sink like the other stopped-state
  // updates (_broadcastStageAndTime) — the BLE bridge carries no time topic.
  //
  // Floors at 1 second, not 0: the normal expiry path never leaves an active
  // half stopped at 0:00 (a tick at 0 transitions the stage), so allowing a
  // manual 0:00 would create a state where a later START double-tap fires
  // playAll() one tick before the stage transition stops the robots again.
  void setRemainingTime(int seconds) {
    _remainingTime = seconds.clamp(1, periodTime);
    notifyListeners();
    _broadcastStageAndTime();
    // A manual clock correction changes the exact freeze point cold resume
    // restores; persist it (off the hot path — the editor is only open while
    // the clock is stopped) so a crash before the next event can't lose it.
    _markDirtyFlush();
  }

  bool get isSomeonePlaying => _numberOfPlaying > 0 ? true : false;
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
      _markDirtyFlush();
    }
  }

  /// Set a team's name from the UI. Routes through here (instead of a direct
  /// `team.name =` + `notifyMQTT()`) so the change also persists into the
  /// cold-resume snapshot.
  void setTeamName(Team team, String value) {
    team.name = value;
    notifyMQTT();
    _markDirtyFlush();
  }

  /// Publish team info (names + IDs) to MQTT. Delegates to
  /// [_broadcastTeamInfo] so the fan-out stays consistent across all call
  /// sites. Note: team info is MQTT-only — unlike score, it is not mirrored
  /// to the BLE bridge.
  void notifyMQTT() {
    _broadcastTeamInfo();
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
