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
  static const int _defaultPeriodTimeSeconds = 600;
  static const int _defaultHalfTimeDurationSeconds = 300;
  static const int _defaultPenaltyTimeSeconds = 60;
  static const int _defaultPlayersPerTeam = 2;
  static const int _noShowPenaltyGoalIntervalSeconds = 30;
  static const int _maxNoShowPenaltyGoalDifference = 10;
  // A scoreboard fixture's `duration_seconds` is the SCHEDULING SLOT (e.g. the
  // 40-min slot; was 25 — rcj-scoreboard#108), NOT the play time. A standard RCJ
  // Soccer match is always 10 + 5 + 10 (two 10-min halves + a 5-min half-time
  // break) regardless of the slot length, so every scoreboard match is forced to
  // that and the payload duration is ignored (#71). TODO: expose these as an
  // operator setting if an event ever needs a different format.
  static const int _scoreboardHalfSeconds = 10 * 60; // 600
  static const int _scoreboardHalfTimeSeconds = 5 * 60; // 300

  String timerButtonText = 'START';
  final int _maxPlayer = 5;
  List<Team> teams = [];
  int _numberOfPlayers = _defaultPlayersPerTeam;
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
  // MAC-set fingerprint of the last module auto-pair (see
  // _syncScoreboardModulePairing). Separate from _lastAppliedScoreboardSignature
  // so a MAC-only change (e.g. a refresh on the upgrade path) still re-pairs even
  // when the fixture signature is unchanged.
  String? _lastPairedModuleMacsSignature;
  // Signature of the fixture the user just CONFIRMED loading (set by
  // [confirmScoreboardMatch]). Lets _applyScoreboardMatchConfig tell a
  // user-confirmed new-fixture Load — which must reset a match in
  // progress/finished (RAVF002) — apart from an automatic same-fixture refresh
  // (version bump / #50 venue correction), which preserves the just-played
  // scores. Keyed on the signature (not a bare flag) so a stale-dialog reject,
  // which re-applies the UNCHANGED committed config, can never be mistaken for
  // the confirmed Load. Consumed on the next apply.
  String? _confirmedLoadSignature;
  // Future of the resumable-snapshot clear started by a confirmed new-fixture
  // Load reset (RAVF002). _applyScoreboardMatchConfig runs synchronously inside
  // confirmPendingMatch's notify, so it cannot await the tombstone itself;
  // instead it stashes the awaitable clear here and confirmScoreboardMatch (the
  // only path that can reach the reset branch) awaits it before the Load dialog
  // dismisses. An immediate kill must not preserve the snapshot of the match the
  // referee just replaced — mirrors discardPendingMatch's awaited clear.
  Future<void>? _confirmedLoadClear;
  String? _lastPromptedPendingSignature;
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
  // Signature of the fixture whose result is eligible for review at full time.
  // Captured the moment the match ends (or the bound fixture's config surfaces
  // post-full-time for a suppressed resume). The result-review affordance is
  // gated on the committed config STILL matching this, so loading a different
  // link at full time can't bind the just-ended match's scores to the new
  // fixture. Cleared on a fresh match (gameInit).
  String? _fullTimeResultSignature;
  bool _fullTimeTransportTeardownDone = false;

  // Callback to request showing the dialog
  void Function()? onRequestSwitchTeamOrderDialog;

  // Callback to open the full-screen result review. A DRAINING setter (mirrors
  // [onRequestResumeMatch]): a cold launch can restore a killed referee match
  // that reached full time with an unsubmitted result (RAVF003) and raise the
  // review BEFORE Home registers this callback in didChangeDependencies. Firing
  // on assignment lets whichever happens last (restore vs registration) open the
  // review. The registered callback re-checks needsScoreboardResultReview and is
  // idempotent, so firing on every assignment is safe.
  void Function()? _onRequestReviewScoreboardResult;
  void Function()? get onRequestReviewScoreboardResult =>
      _onRequestReviewScoreboardResult;
  set onRequestReviewScoreboardResult(void Function()? callback) {
    _onRequestReviewScoreboardResult = callback;
    if (callback != null) _requestScoreboardResultReview();
  }

  // Callback to request the confirm-on-load ("Load match?") dialog. A DRAINING
  // setter, mirroring [onRequestResumeMatch]: scoreboardResultService.initialize()
  // is kicked off in the Game constructor and can surface a staged deep link
  // (pendingMatchConfig) BEFORE Home registers this callback in
  // didChangeDependencies. A plain field would let _onScoreboardServiceUpdate
  // mark the prompt consumed against a null callback, stranding the staged match
  // with no dialog and no re-fire. Firing on assignment lets whichever happens
  // last (config arrival vs callback registration) raise the prompt.
  void Function(ScoreboardMatchConfig config)? _onRequestConfirmScoreboardMatch;
  void Function(ScoreboardMatchConfig config)?
      get onRequestConfirmScoreboardMatch => _onRequestConfirmScoreboardMatch;
  set onRequestConfirmScoreboardMatch(
      void Function(ScoreboardMatchConfig config)? callback) {
    _onRequestConfirmScoreboardMatch = callback;
    _maybeFirePendingMatchPrompt();
  }

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
    teams.add(Team(
        'Team A', [moduleA1, moduleA2, moduleA3, moduleA4, moduleA5], teamID));

    // B team (1)
    teamID = 'B';
    Module moduleB1 = Module(this, teamID, 'B1', 5);
    Module moduleB2 = Module(this, teamID, 'B2', 6);
    Module moduleB3 = Module(this, teamID, 'B3', 7);
    Module moduleB4 = Module(this, teamID, 'B4', 8);
    Module moduleB5 = Module(this, teamID, 'B5', 9);
    teams.add(Team(
        'Team B', [moduleB1, moduleB2, moduleB3, moduleB4, moduleB5], teamID));

    gameInit();
    scoreboardResultService.addListener(_onScoreboardServiceUpdate);
    scoreboardResultService.onCurrentResultDelivered =
        _onScoreboardResultDelivered;
    unawaited(scoreboardResultService.initialize());
    unawaited(_loadPrefs());
  }

  Future<void> _loadPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    _stateStore = MatchStateStore(_prefs!);
    _periodTime = _prefs!.getInt(_periodTimeKey) ?? _defaultPeriodTimeSeconds;
    _halfTimeDuration =
        _prefs!.getInt(_halfTimeDurationKey) ?? _defaultHalfTimeDurationSeconds;
    _numberOfPlayers =
        (_prefs!.getInt(_numberOfPlayersKey) ?? _defaultPlayersPerTeam)
            .clamp(1, _maxPlayer)
            .toInt();
    _penaltyTime =
        _prefs!.getInt(_penaltyTimeKey) ?? _defaultPenaltyTimeSeconds;

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

    // A usable snapshot → either offer a resume (mid-match) or, for a referee
    // match killed at full time before its result was submitted, restore enough
    // to re-offer the result review (RAVF003). A non-referee fullTime snapshot
    // is terminal — nothing to resume — and is ignored as before.
    if (snapshot != null && snapshot.inGame) {
      final stage = _stageFromName(snapshot.stage);
      if (stage != MatchStage.fullTime) {
        _pendingResume = snapshot;
        _maybeFireResumePrompt();
      } else if (snapshot.isRefereeMatch &&
          (snapshot.scoreboardMatchCode?.isNotEmpty ?? false)) {
        _restoreFullTimeResultReview(snapshot);
      }
    }

    // #70: re-pair the linked fixture's modules now that the saved player count
    // is loaded. On a cold start scoreboardResultService.initialize() may have
    // run the first pairing while numberOfPlayers was still the default, leaving
    // the extra slots disabled and unconnected; force a re-pair against the real
    // count. Skip it when a mid-match resume is pending — that path restores
    // modules from the snapshot, not from the fixture MACs.
    if (_pendingResume == null) {
      _syncScoreboardModulePairing(force: true);
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

  void gameInit({bool resetModules = true}) {
    currentStage = MatchStage.firstHalf;
    _remainingTime = periodTime;
    isTimeRunning = false;
    _isGameRunning = false;
    timerButtonText = 'START';
    inGame = false;
    _suppressScoreboardFinalResult = false;
    _resumedFixtureMatchCode = null;
    _resumedFixtureVersion = null;
    _fullTimeResultSignature = null;
    _fullTimeTransportTeardownDone = false;
    _resetNoShowPenaltyGoals();

    stopTimer();

    // enable or disable players based on player number;
    for (var team in teams) {
      team.score = 0;
      if (resetModules) {
        for (var i = 0; i < _maxPlayer; i++) {
          i < numberOfPlayers
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

  /// Same as [_flushMatchStateNow] but awaits the underlying store write, for
  /// paths where the persisted snapshot must be DURABLE before the caller
  /// continues — e.g. the RAVF004 corrected-score write-back, whose whole
  /// purpose is that a kill cannot resurface the pre-correction score on a later
  /// terminal-rejection re-open. Forces the save (the explicit-flush intent),
  /// bypassing the `_dirty` short-circuit, but still honours `_suppressPersist`
  /// and a null store. Awaitable callers must be off the robot START/STOP hot
  /// path (invariant #1).
  Future<void> _flushMatchStateNowAndWait() async {
    if (_suppressPersist) return;
    final store = _stateStore;
    if (store == null) return;
    _dirty = false;
    await store.save(_buildSnapshot());
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
          // Matching config is present → arm the POST now. Use the shared
          // ScoreboardMatchConfig.signature so this stays in lock-step with
          // _applyScoreboardMatchConfig; a drift here re-applies spuriously.
          _lastAppliedScoreboardSignature = config.signature;
          _suppressScoreboardFinalResult = false;
          // Apply the venue field here too. Seeding the signature above means a
          // later scoreboard-service notification dedupe-returns in
          // _applyScoreboardMatchConfig BEFORE its field assignment runs, so on
          // the race where Resume is tapped inside the unawaited initialize()
          // window (config already set, listeners not yet notified) the resumed
          // referee match would otherwise keep publishing on a stale/manual MQTT
          // field (#50). Mirrors _applyScoreboardMatchConfig's field logic and is
          // idempotent if that path already ran. Same race the binding above is
          // restored for.
          final venueField = fieldNumberFromVenue(config.venueShortName);
          if (venueField.isNotEmpty) {
            mqttService.topicField = venueField;
          }
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

  /// Cold-launch restore of a referee match that was killed at full time with
  /// an unsubmitted result (RAVF003). Restores only what the result review needs
  /// — final scores, team names/order and the scoreboard binding — at stage
  /// fullTime, then re-offers the review (now, or when the bound fixture's config
  /// surfaces). Deliberately does NOT restore modules or reconnect: the match is
  /// over and the robots are off; the only thing being recovered is the result.
  /// The snapshot stays on disk until the result is delivered (reset clears it)
  /// or the referee starts a fresh match (REPEAT), so even a second kill in this
  /// window is survivable.
  void _restoreFullTimeResultReview(MatchSnapshot snapshot) {
    _suppressPersist = true;
    try {
      currentStage = MatchStage.fullTime;
      inGame = true;
      timerButtonText = snapshot.timerButtonText;
      _remainingTime = snapshot.remainingTime;
      isTimeRunning = false;
      _isGameRunning = false;
      _restoreTeamOrderAndInfo(snapshot.teams);

      // Snapshot-sourced mapping: this is the fallback for the config-NOT-loaded
      // branch below (it keeps the binding persisted across another kill until
      // the fixture surfaces). When the config IS already loaded, the branch
      // below re-derives the mapping from the live config (a side swap during
      // the kill window makes the snapshot mapping stale), so do not "simplify"
      // by removing these.
      _scoreboardHomeTeamId = snapshot.scoreboardHomeTeamId;
      _scoreboardAwayTeamId = snapshot.scoreboardAwayTeamId;
      _resumedFixtureMatchCode = snapshot.scoreboardMatchCode;
      _resumedFixtureVersion = snapshot.scoreboardVersion;

      final config = scoreboardResultService.matchConfig;
      if (config != null && config.matchCode == snapshot.scoreboardMatchCode) {
        // The bound fixture's config is already loaded → arm now and offer the
        // review immediately. Re-derive the home/away->team-id mapping from the
        // CURRENT config rather than trusting the snapshot's persisted mapping:
        // the snapshot keeps match_code/version/team-ids but NOT the captured
        // signature, so an organizer side-swap (homeIsLeft flip) or home-
        // redefining rename during the kill window would otherwise read the
        // final scores under the stale _scoreboardHomeTeamId mapping and POST the
        // wrong team's goals as "home". The config is the live authority and the
        // physical scores are keyed on the (fixed) team ids, so deriving the
        // mapping fresh here keeps home/away correct on a swap. Mirrors
        // _applyScoreboardMatchConfig; the config-not-loaded branch below already
        // re-derives via that path when the fixture surfaces.
        _deriveScoreboardSideMapping(config);
        // Re-label the teams from the CURRENT config too (by stable id, exactly
        // like _applyScoreboardMatchConfig): _restoreTeamOrderAndInfo above
        // restored the snapshot's PRE-swap names, so without this a side swap
        // would show the old team's name next to the value submitted as the new
        // "home" and mislabel the confirm checkboxes. Goals already follow the
        // re-derived mapping; the displayed names must follow it as well.
        for (final team in teams) {
          team.name = team.id == _scoreboardHomeTeamId
              ? config.homeTeamName
              : config.awayTeamName;
        }
        _lastAppliedScoreboardSignature = config.signature;
        _suppressScoreboardFinalResult = false;
        // Arm the delivery-reset signature DIRECTLY here, not via
        // _enterFullTimeResultReview's unresolved-result gate. That gate guards
        // the LIVE full-time tick so a REPEAT of the same fixture isn't reset by
        // the first run's late 200 (RAVF001). But a *restored* full-time match IS
        // the exact match its queued result belongs to: if the app was killed
        // after Submit but before the 200, the outbox already holds a pending
        // item (hasUnresolvedResultFor → true), and the gate would leave the
        // signature null so the genuine 200 would never reset/clear the finished
        // match. Review *visibility* is governed separately by
        // needsScoreboardResultReview's own unresolved-result clause, so arming
        // here does not surface the review while a result is in flight.
        if (_canSubmitScoreboardResult(config)) {
          _fullTimeResultSignature = config.signature;
        }
        _requestScoreboardResultReview();
      } else {
        // Config not loaded yet (the service's unawaited initialize() races the
        // snapshot load) → keep suppressed; _applyScoreboardMatchConfig re-arms
        // and raises the review at fullTime once the bound fixture surfaces.
        _suppressScoreboardFinalResult = true;
      }

      _broadcastFullState();
    } finally {
      _suppressPersist = false;
    }
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
      if (!_noShowPenaltyGoalsActive) {
        notifyAllModulesTimer();
      }
      mqttService.publishTime(_remainingTime);
      // ~5 s heartbeat for the clock freeze point. Placed only in the normal
      // decrement branch (before any stage-transition reset below), so the % 5
      // test never samples a freshly-reset boundary value. Skipped during the
      // warm-resume replay burst. Direct flush (not microtask): the 1 Hz tick is
      // a low-frequency callback, not a command path.
      if (!_replaying && _remainingTime % 5 == 0) {
        _flushMatchStateNow();
      }
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
          _markDirtyFlush();
          break;
        case MatchStage.halfTime:
          currentStage = MatchStage.secondHalf;
          _remainingTime = periodTime;
          _lastNoShowPenaltyGoalElapsed = 0;
          if (!noShowModeActive) {
            stopAll(true, force: true);
          }
          timerButtonText = 'START';
          _markDirtyFlush();
          break;
        case MatchStage.secondHalf:
          _completeMatchToFullTime();
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

  /// The one true *->fullTime transition. Runs the full set of full-time
  /// side-effects: stage flip, no-show reset, robot stop + game-over (skipped
  /// when no-show mode owned the robots), REPEAT affordance, result review
  /// arming (RAVF003 snapshot + unresolved-result gate), module teardown, and
  /// snapshot persist-or-clear. Called from the natural second-half tick
  /// expiry and from endMatchEarly() (#84) — never build a bespoke shortcut
  /// around it. [forceStop] is for ending early out of the half-time break:
  /// modules parked there have _lastState == halfTime, which an unforced
  /// Module.stopAll re-dispatches to halfTime() (a fresh break countdown)
  /// instead of STOP — the same reason the halfTime->secondHalf paths use
  /// stopAll(true, force: true). The natural second-half expiry keeps the
  /// unforced call it always had. Callers own _broadcastStageAndTime() +
  /// notifyListeners() afterwards (the natural tick does both once at the end
  /// of _tickTimer, shared with the other stage transitions).
  void _completeMatchToFullTime({bool forceStop = false}) {
    // Captured before _resetNoShowPenaltyGoals() below clears the flag; when
    // no-show mode owned the robots they were never started, so the stop +
    // game-over fan-out is skipped exactly as the pre-#84 tick block did.
    final noShowModeActive = _noShowPenaltyGoalsActive;
    currentStage = MatchStage.fullTime;
    _resetNoShowPenaltyGoals();
    if (!noShowModeActive) {
      stopAll(true, force: forceStop);
      gameOverAll();
    }
    timerButtonText = 'REPEAT';
    _enterFullTimeResultReview();
    // The match is over: stop the OS autoConnect from chasing modules
    // that are powered down for good (e.g. a unit still off from a
    // late penalty). In-match these reconnect unbounded on purpose; at
    // full time we settle the ones still off to "Disconnected".
    disconnectInactiveModules();
    _persistOrClearAtFullTime();
    unawaited(_teardownFieldTransportsAtFullTime());
  }

  // Release the field infrastructure at full time (#87): referees rotate
  // phones per field, and the bridge accepts a single central — while the old
  // phone holds it (or the MQTT session), the next phone can't take over.
  // Launched unawaited from _completeMatchToFullTime so both the natural
  // second-half expiry and endMatchEarly() (#84) inherit it, and nothing on
  // the robot STOP path waits on it (invariant #1). The 1 s delay + stage
  // re-check mirror gameOverAll(): the callers' synchronous final
  // _broadcastStageAndTime() runs before the first await resumes, so the
  // final "Game Over" publish always precedes the MQTT disconnect, and a
  // REPEAT during the delay aborts the teardown. One-shot per match
  // (re-armed by gameInit) so a second entry into the full-time block no-ops.
  Future<void> _teardownFieldTransportsAtFullTime() async {
    if (_fullTimeTransportTeardownDone) return;
    _fullTimeTransportTeardownDone = true;
    await Future<void>.delayed(const Duration(seconds: 1));
    if (currentStage != MatchStage.fullTime) return;

    // Tear down a connected OR still-connecting bridge link — the same
    // stop-chasing-a-powered-down-unit policy disconnectInactiveModules()
    // applies to robot modules. The bounded drain lets the last queued score
    // frame reach the scoreboard before the link drops.
    final bridgeState = bleBridgeService.connectionStateNotifier.value;
    if (bridgeState == BridgeConnectionState.connected ||
        bridgeState == BridgeConnectionState.connecting) {
      await bleBridgeService.disconnectAfterDrain();
    }
    mqttService.disconnect();
  }

  // Load-only reconnect: a same-match full-time refresh must not undo #87's
  // teardown, but a fresh or confirmed match load should claim the field.
  void _maybeAutoConnectMqttOnMatchLoad() {
    if (!mqttService.isEnabled) return;
    if (mqttService.isConnected) return;
    if (mqttService.connectionStateNotifier.value ==
        MqttConnectionStateEx.connecting) {
      return;
    }
    // Fire-and-forget: a broker outage must not delay match load, and the
    // Settings status label reports the outcome.
    unawaited(mqttService.connect());
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
    if (_noShowPenaltyGoalsActive) {
      return;
    }
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

  void resetModuleNames() {
    for (var team in teams) {
      for (var module in team.modules
          .where((module) => module.isEnabled && module.hasCustomLabel)) {
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
      for (var module in team.modules.where(
          (module) => module.isEnabled && module.state == ModuleState.damage)) {
        final penaltyBefore = module.penaltyTime;
        module.notifyTimer();

        if (!_replaying &&
            !vibrateTriggered &&
            vibrationService.damageTimerEnabled &&
            penaltyBefore > 0) {
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
        for (final module in team.modules.where((m) =>
            m.isEnabled &&
            m.state == ModuleState.damage &&
            m.penaltyTime > 0)) {
          NotificationService.scheduleDamageAlerts(module.moduleId, module.name,
              module.penaltyTime, vibrationService.damageTimerAlerts);
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

  /// Called by the service the moment the active match's result is confirmed
  /// delivered (HTTP 200). Defer the actual reset to a microtask: this fires
  /// from inside the service's processOutbox, so resetting (which mutates the
  /// service) inline would be re-entrant.
  void _onScoreboardResultDelivered() {
    // A queued result can be delivered (200) only AFTER the referee has already
    // left the post-match screen — e.g. tapped REPEAT to start a fresh match,
    // which keeps the committed binding so the late 200 still reads as the
    // "current fixture" in the service. Resetting then would disconnectAll() +
    // gameInit() the new, live in-progress match (RAVF001). Only reset while we
    // are STILL on the exact full-time match this delivery belongs to: REPEAT /
    // a new match move the stage off fullTime and clear the captured full-time
    // signature (gameInit), so this guard cleanly distinguishes the two. A late
    // 200 for a result queued against a SINCE-REPLACED fixture can't reach here
    // either: a confirmed new-fixture Load resets to firstHalf (RAVF002), so the
    // stage guard rejects it, and the service only fires this for an item still
    // matching the committed fixture.
    if (currentStage != MatchStage.fullTime ||
        _fullTimeResultSignature == null) {
      return;
    }
    scheduleMicrotask(_resetAfterScoreboardSubmission);
  }

  /// Return to the clean start state after a referee result is delivered, ready
  /// for the next match (as if freshly launched): disconnect modules, restore
  /// default team names/order, the operator's configured match length, and a
  /// fresh 0-0 first half; drop the linked match (keeping the outbox audit) and
  /// any saved snapshot. Only reached on a successful submission, so a queued or
  /// failed result keeps the match on screen with its status instead.
  void _resetAfterScoreboardSubmission() {
    disconnectAll();
    for (final team in teams) {
      team.name = team.id == 'A' ? 'Team A' : 'Team B';
    }
    _lastAppliedScoreboardSignature = null;
    _lastPairedModuleMacsSignature = null;
    _scoreboardHomeTeamId = null;
    _scoreboardAwayTeamId = null;
    _fullTimeResultSignature = null;
    _resumedFixtureMatchCode = null;
    _resumedFixtureVersion = null;
    _suppressScoreboardFinalResult = false;
    // The deep link had overridden the live period + half-time; restore the
    // operator's configured defaults (or the app defaults 600 s / 300 s).
    _periodTime = _prefs?.getInt(_periodTimeKey) ?? 600;
    _halfTimeDuration = _prefs?.getInt(_halfTimeDurationKey) ?? 300;
    setTeamToDefaultOrder();
    gameInit();
    unawaited(scoreboardResultService.resetLinkedMatchAfterSubmission());
    _clearMatchState();
    notifyListeners();
  }

  void _onScoreboardServiceUpdate() {
    if (scoreboardResultService.pendingMatchConfig == null) {
      // Pending cleared (confirmed/cancelled): reset the dedup so re-opening the
      // same link later prompts again.
      _lastPromptedPendingSignature = null;
    } else {
      _maybeFirePendingMatchPrompt();
    }

    final config = scoreboardResultService.matchConfig;
    if (config != null) {
      _applyScoreboardMatchConfig(config);
      // Pair modules AFTER the apply so gameInit()'s enable/disable state is
      // settled. Runs even when _applyScoreboardMatchConfig deduped on an
      // unchanged fixture signature, so a refresh that only adds MACs (the
      // upgrade path) still pairs — the MAC-signature dedupe inside keeps it a
      // no-op otherwise.
      _syncScoreboardModulePairing();
    }
    notifyListeners();
  }

  /// Raise the "Load match?" prompt for a staged deep link, exactly once per
  /// pending signature. Only advances [_lastPromptedPendingSignature] when the
  /// callback is actually invoked, so a config that surfaces before Home
  /// installs the callback is not silently consumed (the draining setter
  /// re-runs this on registration).
  void _maybeFirePendingMatchPrompt() {
    final callback = _onRequestConfirmScoreboardMatch;
    if (callback == null) return;
    final pending = scoreboardResultService.pendingMatchConfig;
    if (pending == null) return;
    final signature = pending.signature;
    if (_lastPromptedPendingSignature == signature) return;
    _lastPromptedPendingSignature = signature;
    callback(pending);
  }

  /// Called by Home when the "Load match?" dialog closes. Re-arms the prompt so
  /// a newer link that arrived while the dialog was open (and was suppressed by
  /// the dialog's re-entrancy guard) is shown next, and a stale Load/Cancel that
  /// no-opped against a changed fixture doesn't strand the current pending one.
  void onPendingMatchPromptClosed() {
    _lastPromptedPendingSignature = null;
    _maybeFirePendingMatchPrompt();
  }

  /// Confirm the staged "Load match?" deep link (called by Home's Load button).
  /// Wraps the service promotion so the resulting _applyScoreboardMatchConfig
  /// knows this is a USER-CONFIRMED Load — which must reset a match already in
  /// progress/finished (RAVF002) — rather than an automatic same-fixture
  /// refresh. confirmPendingMatch promotes + notifies SYNCHRONOUSLY, so the flag
  /// is in place when the apply runs. After the await we await the snapshot clear
  /// the reset stashed (RAVF002 durability), and the `finally` clears the
  /// confirmed-load signals so a rejected/no-op promotion leaves nothing armed
  /// for a later apply.
  Future<void> confirmScoreboardMatch({String? expectedSignature}) async {
    // Capture the signature of the fixture being confirmed so the resulting
    // apply only treats THAT exact fixture as a confirmed Load. confirmPendingMatch
    // promotes + notifies synchronously, so the apply runs while this is set; the
    // finally clears it if a stale-dialog reject promoted nothing. Mirror
    // confirmPendingMatch's own stale-dialog guard: only arm when the current
    // pending fixture matches the dialog's expectedSignature, otherwise the
    // promotion will be rejected and we must NOT arm (else a stale Load whose
    // pending happens to share an unapplied committed config's signature could
    // still trigger a reset).
    final pendingSignature =
        scoreboardResultService.pendingMatchConfig?.signature;
    _confirmedLoadSignature = (pendingSignature != null &&
            (expectedSignature == null ||
                expectedSignature == pendingSignature))
        ? pendingSignature
        : null;
    try {
      await scoreboardResultService.confirmPendingMatch(
          expectedSignature: expectedSignature);
      // If the synchronous apply above reset a live match (RAVF002), it stashed
      // the awaitable snapshot clear; await it so the Load dialog does not dismiss
      // before the tombstone lands. This await is on the dialog/Load path only,
      // never the robot START/STOP hot path (invariant #1).
      final clear = _confirmedLoadClear;
      _confirmedLoadClear = null;
      if (clear != null) await clear;
    } finally {
      _confirmedLoadSignature = null;
      _confirmedLoadClear = null;
    }
  }

  // Set the LIVE match timing for a scoreboard match: ALWAYS 10-min halves +
  // 5-min half-time break, regardless of the payload's `duration_seconds` (which
  // is the scheduling slot, not play time — see the constants above). Sets the
  // fields directly (NOT via the periodTime/halfTimeDuration setters) so it
  // applies to this match only and is never persisted as the operator defaults.
  // `config` is accepted for a stable call site / future per-event override.
  void _applyScoreboardTiming(ScoreboardMatchConfig config) {
    _periodTime = _scoreboardHalfSeconds;
    _halfTimeDuration = _scoreboardHalfTimeSeconds;
  }

  void _applyScoreboardMatchConfig(ScoreboardMatchConfig config) {
    // Team names AND venue are part of the signature (see
    // ScoreboardMatchConfig.signature) so a corrected schedule payload that
    // changes only a name or the venue (without bumping version/duration/side)
    // still updates the displayed names and the MQTT field (#50); the
    // `if (!inGame)` guard below still gates timing.
    // Consume the "user confirmed a Load" signal up front so it never leaks to a
    // later apply. It is the signature of the fixture the user confirmed: a
    // confirmed Load (the warned "Load match?" overwrite) resets a match in
    // progress/finished (RAVF002) whenever the applied config IS that fixture —
    // including re-loading the SAME fixture (the dialog warns it replaces the
    // match, so the intent is a clean start regardless of whether the fixture
    // changed). A stale-dialog reject re-applies the unchanged committed config,
    // whose signature won't match the confirmed one, so it never resets.
    final confirmedSignature = _confirmedLoadSignature;
    _confirmedLoadSignature = null;
    final signature = config.signature;
    final isConfirmedNewFixtureLoad =
        confirmedSignature != null && confirmedSignature == signature && inGame;
    // Dedupe on an unchanged signature - EXCEPT while a resumed match is still
    // suppressed. `_lastAppliedScoreboardSignature` is in-memory and is never
    // cleared when the service drops `_matchConfig` to null (a token-changing
    // deep link or clearLinkedMatchData), so a suppressed resume can carry a
    // stale signature for its own fixture. If that same fixture's config then
    // re-arrives, an early dedupe return here would skip the re-arm below and
    // leave the final result suppressed forever (#53). While suppressed, fall
    // through to the re-arm guard, which re-arms the bound fixture or rejects a
    // different one. A confirmed Load is never deduped away — re-loading the
    // SAME fixture (same signature) must still reset.
    if (!isConfirmedNewFixtureLoad &&
        !(inGame && _suppressScoreboardFinalResult) &&
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
        // A DIFFERENT fixture surfaced while this resume is still suppressed.
        // Normally reject it (an automatic config must not retarget a suppressed
        // match's result), but a user-CONFIRMED Load means the referee chose to
        // abandon the resume for this fixture — fall through to the reset below.
        if (!isConfirmedNewFixtureLoad) return;
      } else {
        reArmedFromSuppression = true;
      }
    }
    _lastAppliedScoreboardSignature = signature;
    _suppressScoreboardFinalResult = false;
    _deriveScoreboardSideMapping(config);

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
      final previousTopic = mqttService.topic;
      mqttService.topicField = venueField;
      // If the field changes while a match is already underway — a mid-game
      // venue correction, or the late-config re-arm of a suppressed resume — the
      // `if (!inGame)` gameInit() broadcast below is skipped, so nothing would
      // repopulate the NEW retained MQTT topic. Since publishes are retained,
      // subscribers on the corrected field_N would otherwise see a previous
      // match's retained data (or nothing) until the next score/stage event.
      // Rebroadcast current state once, only when the topic actually changed, so
      // an idempotent re-apply of the same field doesn't spam the bus. Skip it
      // for a confirmed new-fixture Load: that resets below and gameInit()
      // broadcasts the clean 0-0 state to the new field — rebroadcasting here
      // would briefly publish the PREVIOUS match's scores under the new fixture.
      // _broadcastFullState is off the robot START/STOP hot path (invariant #1).
      if (inGame &&
          !isConfirmedNewFixtureLoad &&
          mqttService.topic != previousTopic) {
        _broadcastFullState();
      }
    }

    // Apply remote timing presets only before a match starts (between matches,
    // after a reset). Never call gameInit() at full-time: a version-only update
    // from a successful result submission would otherwise zero the just-played
    // scores and broadcast a reset 0-0/first-half state over MQTT and the BLE
    // bridge. The full-time clock display stays in sync separately via the
    // periodTime setter when settings change.
    if (!inGame) {
      // Set the LIVE match length from the link, but do NOT persist it as the
      // operator's configured default (the `periodTime` setter would write it to
      // prefs and clobber their setting). gameInit() applies it to the clock.
      // #71: a 25-min scheduling slot is mapped to a 10-min half + 5-min break.
      _applyScoreboardTiming(config);
      gameInit();
      _maybeAutoConnectMqttOnMatchLoad();
    } else if (isConfirmedNewFixtureLoad) {
      // RAVF002: the referee confirmed the "Load match?" overwrite while a match
      // is in progress or finished. The dialog warns it "replaces the match in
      // progress", so reset to a clean match bound to the new fixture.
      // gameInit() zeroes scores/clock/stage and clears the old full-time review
      // subject + resumed binding (_fullTimeResultSignature,
      // _resumedFixtureMatchCode, _suppressScoreboardFinalResult); the new
      // fixture's names/side mapping were applied above and gameInit() leaves
      // names untouched. gameInit() runs BEFORE setTeamToDefaultOrder() so the
      // scores are already zeroed when the order toggle broadcasts — otherwise a
      // second-half-swapped order would publish the previous match's scores
      // under the new fixture's names. setTeamToDefaultOrder() then restores the
      // default order for the new first half. gameInit() never touches the
      // outbox, so an already-submitted result for the PREVIOUS fixture survives
      // and keeps retrying; its late 200 no longer matches the committed
      // fixture, so it can't reset this match (rule 3). Clear the stale snapshot
      // so a kill resumes the new match.
      // #71: a 25-min scheduling slot is mapped to a 10-min half + 5-min break.
      _applyScoreboardTiming(config);
      gameInit();
      setTeamToDefaultOrder();
      // Use the AWAITABLE clear (not the fire-and-forget _clearMatchState) and
      // stash its future so confirmScoreboardMatch can await the tombstone before
      // the Load dialog dismisses (RAVF002 durability). discardPendingMatch — the
      // sibling destructive "replace the match" path — awaits its clear for the
      // same reason: an immediate kill must not re-offer the replaced match. The
      // synchronous part (_dirty=false + initiating the tombstone write) runs now;
      // only the disk completion is awaited later, off the robot hot path.
      _confirmedLoadClear = _clearMatchStateAndWait();
      _maybeAutoConnectMqttOnMatchLoad();
    } else if (reArmedFromSuppression && currentStage == MatchStage.fullTime) {
      // The bound fixture's config only surfaced AFTER this resumed match had
      // already run to full-time while suppressed. Now that the bound fixture's
      // config is here, capture it as the review subject and surface the review
      // flow instead of silently enqueueing. The full-time tick cleared the
      // snapshot while suppressed (nothing to review yet); re-persist it now so a
      // kill before Submit can resume the review (RAVF003).
      _enterFullTimeResultReview();
      _persistOrClearAtFullTime();
    }
  }

  void _autoPairScoreboardModules(ScoreboardMatchConfig config) {
    // Map each side's MACs onto that side's fixed module slots, keyed by team ID
    // (not list position) so a swapped team order can't cross the sides. The
    // home->id rule mirrors _deriveScoreboardSideMapping but is computed locally
    // from config.homeIsLeft so pairing never depends on _scoreboardHomeTeamId
    // being derived first (it can run before/independently of an apply). Only
    // the slots the server supplies a MAC for are touched, so a partial list
    // never clobbers a hand-paired spare slot; the server config is
    // authoritative only for the modules it actually names. The empty label lets
    // each slot fall back to its default name (A1..A5) via Module.name;
    // applyPresetConfig is idempotent (skips a slot already on that MAC) so a
    // re-pair won't churn live BLE links.
    final homeId = config.homeIsLeft ? 'A' : 'B';
    for (final team in teams) {
      final macs =
          team.id == homeId ? config.homeModuleMacs : config.awayModuleMacs;
      for (var i = 0; i < team.modules.length && i < macs.length; i++) {
        team.modules[i].applyPresetConfig(macs[i], '');
      }
    }
  }

  /// Pair the linked fixture's modules if the MAC set (or side) changed since the
  /// last pairing. Runs only between matches (`!inGame`) so a live match keeps
  /// whatever the referee has connected. Deduped on a MAC signature — NOT the
  /// fixture signature — so a refresh that adds MACs to an already-applied
  /// fixture (e.g. the upgrade path where the persisted config predates the MAC
  /// fields) still pairs even though `_applyScoreboardMatchConfig` deduped it
  /// away. `force` bypasses the dedupe to re-pair after the saved player count
  /// loads on a cold start (the first pass may have run while numberOfPlayers was
  /// still the default, leaving the extra slots disabled and unconnected).
  void _syncScoreboardModulePairing({bool force = false}) {
    final config = scoreboardResultService.matchConfig;
    if (config == null || inGame) return;
    // A MAC-set fingerprint. MACs are validated hex + colons, so ','/'|' can't
    // occur in them and this delimiter join can't alias two different sets
    // (avoids pulling in dart:convert for a jsonEncode).
    final macSignature = '${config.homeIsLeft}'
        '|${config.homeModuleMacs.join(',')}'
        '|${config.awayModuleMacs.join(',')}';
    if (!force && macSignature == _lastPairedModuleMacsSignature) return;
    _lastPairedModuleMacsSignature = macSignature;
    _autoPairScoreboardModules(config);
  }

  bool _canSubmitScoreboardResult([ScoreboardMatchConfig? config]) {
    final matchConfig = config ?? scoreboardResultService.matchConfig;
    // Final gate before the POST: need a submittable fixture (non-empty code)
    // and a non-suppressed binding.
    if (matchConfig == null || matchConfig.matchCode.isEmpty) return false;
    if (_suppressScoreboardFinalResult) return false;
    // A resumed match is bound to its fixture: never POST if the live config has
    // drifted to a different fixture (e.g. a deep link opened mid-match). Belt-
    // and-suspenders with the suppress guard above.
    final resumedCode = _resumedFixtureMatchCode;
    if (resumedCode != null &&
        resumedCode.isNotEmpty &&
        matchConfig.matchCode != resumedCode) {
      return false;
    }
    return true;
  }

  /// Whether the "End match now" early-end affordance (#84) applies: a
  /// deep-link (scoreboard) fixture is loaded and submittable, and the match
  /// has not already reached full time (also makes endMatchEarly idempotent).
  /// Manual matches have nothing to confirm/submit, so they never qualify.
  bool get canEndMatchEarly {
    if (currentStage == MatchStage.fullTime) return false;
    final config = scoreboardResultService.matchConfig;
    if (config == null || config.matchCode.isEmpty) return false;
    if (!scoreboardResultService.hasToken) return false;
    // A still-unresolved prior result for this fixture (REPEAT while the first
    // run's POST is in flight) means _enterFullTimeResultReview would refuse
    // to arm the review — ending early would strand the referee at full time
    // with no result editor, breaking the dialog's promise. Hide the button
    // instead, matching the review suppression at a natural full time.
    if (scoreboardResultService.hasUnresolvedResultFor(config.matchCode)) {
      return false;
    }
    return _canSubmitScoreboardResult(config);
  }

  /// End the match NOW (#84: team no-show -> forfeit/contumation win) and jump
  /// to the result review. Works from any stage, clock running or not, and
  /// reuses the exact secondHalf->fullTime side-effects so every full-time
  /// invariant (RAVF003 kill-before-submit snapshot, unresolved-result gate,
  /// REPEAT behaviour, module teardown) holds. Gated on [canEndMatchEarly], so
  /// it is a no-op for manual matches and once already at full time.
  void endMatchEarly() {
    if (!canEndMatchEarly) return;
    // Modules parked in the half-time break need the forced STOP dispatch —
    // decided here, before the transition below moves the stage off halfTime.
    final endedFromHalfTime = currentStage == MatchStage.halfTime;
    // Cancels a running half clock OR the half-time break countdown, and
    // clears the background run-clock anchors so a backgrounded app cannot
    // catch the ended match up later.
    stopTimer();
    // Every natural path reaches fullTime only when the clock hits 0:00, and
    // Home, the MQTT/bridge sinks, and the persisted RAVF003 snapshot all
    // surface _remainingTime as-is — an early end must not present "full time
    // with 10:00 left".
    _remainingTime = 0;
    // A match ended administratively "happened" even if the clock never
    // started (during live play inGame is otherwise only set by startTimer;
    // the cold-resume restore paths set it too). Required twice
    // over: Home's return-from-Settings path calls gameInit() when !inGame,
    // which would wipe the full-time state just set below; and the cold-resume
    // path only restores a snapshot when snapshot.inGame is true, so the
    // RAVF003 kill-before-submit review snapshot must record an in-game match.
    inGame = true;
    _completeMatchToFullTime(forceStop: endedFromHalfTime);
    _broadcastStageAndTime();
    notifyListeners();
  }

  bool get needsScoreboardResultReview {
    final config = scoreboardResultService.matchConfig;
    if (currentStage != MatchStage.fullTime) return false;
    // The committed config must STILL be the exact fixture that just ended.
    // Loading a different link at full time changes matchConfig, but its
    // signature won't match the one captured at full time, so we never offer to
    // submit the just-ended scores against a newly-loaded fixture.
    if (_fullTimeResultSignature == null) return false;
    if (config == null || config.signature != _fullTimeResultSignature) {
      return false;
    }
    if (!_canSubmitScoreboardResult(config)) return false;
    // A terminally-rejected (HTTP 401/422) result must NOT hide the review:
    // it is correctable, and enqueueFinalResult accepts a fresh re-submit, so
    // the referee needs a route back to the review screen (RAVF002). Any other
    // tracked state (pending / conflict / submitted / retry-exhausted) still
    // suppresses the affordance.
    return !scoreboardResultService.hasUnresolvedResultFor(config.matchCode);
  }

  /// Capture the just-ended fixture as the result-review subject, then raise the
  /// review affordance. Called at the secondHalf->fullTime tick and, for a
  /// suppressed resume, when the bound fixture's config surfaces post-full-time.
  /// Map the scoreboard home/away roles onto the fixed physical team ids.
  /// Team 'A' is always the left side and 'B' the right; `homeIsLeft` decides
  /// which physical team is "home". The single source of this rule — a stale or
  /// out-of-sync mapping is exactly what POSTs the wrong team's goals as "home".
  void _deriveScoreboardSideMapping(ScoreboardMatchConfig config) {
    _scoreboardHomeTeamId = config.homeIsLeft ? 'A' : 'B';
    _scoreboardAwayTeamId = config.homeIsLeft ? 'B' : 'A';
  }

  /// The scoreboard's per-robot inspection rows for [team]'s side of the linked
  /// fixture, so the loaded-match team-settings view can surface inspection
  /// status during a match (not only in the "Load match?" dialog). Returns an
  /// empty list when no fixture is linked or the side mapping is unresolved.
  /// Routes through the home/away->team-id mapping ([_deriveScoreboardSideMapping])
  /// so callers never re-derive that rule and can't cross the sides.
  List<InspectionRobot> inspectionRobotsForTeam(Team team) {
    final config = scoreboardResultService.matchConfig;
    if (config == null) return const [];
    if (team.id == _scoreboardHomeTeamId) return config.homeInspectionRobots;
    if (team.id == _scoreboardAwayTeamId) return config.awayInspectionRobots;
    return const [];
  }

  void _enterFullTimeResultReview() {
    final config = scoreboardResultService.matchConfig;
    if (config != null &&
        _canSubmitScoreboardResult(config) &&
        // Don't arm the reset signature while a prior result for the SAME
        // fixture is still in flight. REPEAT replays the same fixture: gameInit
        // nulls _fullTimeResultSignature but the service keeps _matchConfig, so
        // the second run's full time would otherwise re-arm — and a late 200
        // from the FIRST run (same code+version -> isCurrentFixture) would then
        // reset/disconnect the live second match. The fixture token is
        // single-use, so a still-unresolved prior result already owns it and the
        // review stays correctly suppressed (RAVF001, REPEAT same-fixture).
        !scoreboardResultService.hasUnresolvedResultFor(config.matchCode)) {
      _fullTimeResultSignature = config.signature;
    }
    _requestScoreboardResultReview();
  }

  void _requestScoreboardResultReview() {
    if (!needsScoreboardResultReview) return;
    _onRequestReviewScoreboardResult?.call();
  }

  /// At full time (or when a suppressed resume's fixture config surfaces
  /// post-full-time), decide whether to persist or clear the snapshot. A referee
  /// match with an unsubmitted result PERSISTS a full-time review snapshot so a
  /// kill before Submit can resume the review (RAVF003) — nothing POSTs from the
  /// snapshot; it only keeps the result alive for re-submission. Otherwise the
  /// match is terminal and the snapshot is cleared (the #45 contract that a
  /// finished match isn't resumed). Once the result is submitted/delivered the
  /// outbox owns durability and the reset (or REPEAT) clears the snapshot.
  void _persistOrClearAtFullTime() {
    if (needsScoreboardResultReview) {
      _flushMatchStateNow();
    } else if (_suppressScoreboardFinalResult &&
        (_resumedFixtureMatchCode?.isNotEmpty ?? false) &&
        !scoreboardResultService
            .hasUnresolvedResultFor(_resumedFixtureMatchCode!)) {
      // A resumed referee match can reach full time while STILL suppressed (its
      // bound fixture's config hasn't surfaced yet), so needsScoreboardResultReview
      // can't be true at this tick. Clearing here would make a kill in the
      // config-load window unrecoverable: there is no outbox item yet (nothing
      // POSTs until Submit) and the snapshot would be gone. Keep the snapshot
      // instead — _buildSnapshot still records it as a referee binding
      // (pendingReferee), a full-time referee snapshot is routed to
      // _restoreFullTimeResultReview on cold launch, and the late config re-arms
      // and re-persists the review. Same durability contract as RAVF003,
      // extended to the suppressed-resume sub-case (RAVF001).
      //
      // Mirror the unresolved-result guard in _enterFullTimeResultReview /
      // needsScoreboardResultReview: ONLY keep the snapshot when no outbox item
      // already owns this fixture's result. If one does — e.g. a REPEAT second
      // run resumed-and-suppressed while the FIRST run's submission is still
      // pending — persisting and later restoring+arming this snapshot would let
      // the first run's late 200 reset the wrong run, the exact REPEAT hazard
      // RAVF001 guards against. In that case fall through to clear, leaving the
      // pending item's own durability/ownership untouched.
      _flushMatchStateNow();
    } else {
      _clearMatchState();
    }
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
    final homeIsLeft = config?.homeIsLeft ?? true;
    final defaultHomeTeamId = homeIsLeft ? 'A' : 'B';
    final defaultAwayTeamId = homeIsLeft ? 'B' : 'A';
    final homeTeamId = _scoreboardHomeTeamId ?? defaultHomeTeamId;
    final awayTeamId = _scoreboardAwayTeamId ?? defaultAwayTeamId;

    return (
      matchCode: config?.matchCode ?? '',
      // Full fixture+revision identity captured at review time, so a later
      // same-code change (side swap / version bump) is detected on submit.
      signature: config?.signature ?? '',
      homeName: _teamNameById(homeTeamId) ?? config?.homeTeamName ?? 'Home',
      awayName: _teamNameById(awayTeamId) ?? config?.awayTeamName ?? 'Away',
      homeGoals: _scoreByTeamId(homeTeamId) ?? 0,
      awayGoals: _scoreByTeamId(awayTeamId) ?? 0,
    );
  }

  Future<bool> submitScoreboardResult({
    required String expectedSignature,
    required int homeGoals,
    required int awayGoals,
    String? comment,
    required bool homeConfirmed,
    required bool awayConfirmed,
  }) async {
    if (!_canSubmitScoreboardResult()) return false;

    // Identity guard: the review screen captured its scores/team mapping for one
    // fixture revision. Compare the FULL signature (code + version + side +
    // names), not just the match code: a same-code config change (e.g. a side
    // swap or version bump from an organizer edit, or a new link confirmed at
    // full time) would otherwise post the captured scores against a changed
    // mapping/version. Refuse so the referee re-opens a fresh review instead.
    if (scoreboardResultService.matchConfig?.signature != expectedSignature) {
      return false;
    }

    // Capture the side mapping BEFORE awaiting the enqueue. The signature guard
    // above proved matchConfig.signature == expectedSignature, so this mapping is
    // exactly the one the review screen submitted against. An already-in-flight
    // refreshMatchConfig() can complete during the await below, reassign the
    // committed config, and (for a same-fixture side swap) flip homeIsLeft —
    // re-deriving the mapping AFTER the await would then write these goals onto
    // the WRONG physical teams. Capturing here keeps the write-back correct
    // regardless of a concurrent refresh, while still letting a benign
    // version/name refresh through (the team IDs are stable, so the submitted
    // homeGoals always belong to homeTeamId). Same homeIsLeft fallback as
    // buildScoreboardResultReview.
    final homeIsLeft = scoreboardResultService.matchConfig?.homeIsLeft ?? true;
    final homeTeamId = _scoreboardHomeTeamId ?? (homeIsLeft ? 'A' : 'B');
    final awayTeamId = _scoreboardAwayTeamId ?? (homeIsLeft ? 'B' : 'A');

    final trimmedComment = comment?.trim();
    final submitted = await scoreboardResultService.enqueueFinalResult(
      homeGoals: homeGoals,
      awayGoals: awayGoals,
      comment: trimmedComment == null || trimmedComment.isEmpty
          ? null
          : trimmedComment,
      homeConfirmed: homeConfirmed,
      awayConfirmed: awayConfirmed,
    );
    if (submitted) {
      // Persist the referee's (possibly corrected) review scores onto the live
      // teams and the resumable snapshot now that an outbox item owns them.
      // Without this, a terminal 401/422 rejection re-opens the review (via
      // hasUnresolvedResultFor) reading the ORIGINAL teams[*].score, so the
      // correction would be silently lost and a blind re-submit would re-send
      // the wrong values (RAVF004). teams[*].score is a plain field (no
      // MQTT/bridge broadcast), so this updates local truth + the snapshot
      // only; the POST payload already carries the homeGoals/awayGoals passed
      // above. Map via the side mapping captured above (pre-await).
      for (final team in teams) {
        if (team.id == homeTeamId) {
          team.score = homeGoals;
        } else if (team.id == awayTeamId) {
          team.score = awayGoals;
        }
      }
      // Await the snapshot write so the corrected scores are DURABLE before
      // submit returns. enqueueFinalResult already persisted the outbox item
      // durably; a kill in the gap between that and a fire-and-forget snapshot
      // save would restore the OLD scores, and a later terminal 401/422 rejection
      // would re-open the review reading the stale teams[*].score — the exact
      // RAVF004 loss this write-back exists to prevent. submitScoreboardResult is
      // async and awaited by the review screen, never the robot hot path.
      await _flushMatchStateNowAndWait();
    }
    // enqueueFinalResult already notifies on every outcome it can change
    // (queued / already-tracked), and Game listens to the service and re-emits,
    // so no extra notifyListeners() is needed here.
    return submitted;
  }

  int? _scoreByTeamId(String? teamId) {
    if (teamId == null) return null;
    for (final team in teams) {
      if (team.id == teamId) return team.score;
    }
    return null;
  }

  String? _teamNameById(String? teamId) {
    if (teamId == null) return null;
    for (final team in teams) {
      if (team.id == teamId) return team.name;
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
      for (var module in team.modules.where((module) =>
          module.isEnabled && (module.isConnected || module.isConnecting))) {
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
      for (var module in team.modules
          .where((module) => module.isEnabled && module.isConnecting)) {
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
