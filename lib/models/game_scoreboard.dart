// Part of game.dart: scoreboard fixture binding, result review and submission.
part of 'game.dart';

/// Scoreboard (deep-link) fixture: apply a config, pair its modules, review
/// and submit the final result, reset once it is delivered.
extension GameScoreboard on Game {
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
    _notify();
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
    final isConfirmedLoad =
        confirmed != null && confirmed == signature && inGame;
    final suppressedResume = inGame && _sb.suppressFinalResult;

    // Dedupe an unchanged fixture, except while a resumed match still waits
    // for its own fixture's config (which may carry the same stale signature).
    if (!isConfirmedLoad &&
        !suppressedResume &&
        _sb.appliedSignature == signature) {
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
    _periodTime = Game._scoreboardHalf;
    _halfTimeDuration = Game._scoreboardBreak;
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
      final macs =
          team.id == homeId ? config.homeModuleMacs : config.awayModuleMacs;
      for (var i = 0; i < team.modules.length && i < macs.length; i++) {
        final module = team.modules[i];
        final mac = macs[i].toUpperCase();
        final sameIdentity = mac.isNotEmpty &&
            (module.hardwareMac == mac ||
                module.macAddress.toUpperCase() == mac);
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
    if (scoreboardResultService.hasUnresolvedResultFor(config.matchCode)) {
      return false;
    }
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
    _notify();
  }

  bool get needsScoreboardResultReview {
    if (currentStage != MatchStage.fullTime || _sb.fullTimeSignature == null) {
      return false;
    }
    final config = scoreboardResultService.matchConfig;
    // The committed config must STILL be the fixture that just ended.
    if (config == null || config.signature != _sb.fullTimeSignature) {
      return false;
    }
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
    if (currentStage != MatchStage.fullTime || _sb.fullTimeSignature == null) {
      return;
    }
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
    _periodTime =
        _prefs?.getInt(Game._periodTimeKey) ?? Game._defaultPeriodTime;
    _halfTimeDuration = _prefs?.getInt(Game._halfTimeDurationKey) ??
        Game._defaultHalfTimeDuration;
    setTeamToDefaultOrder();
    gameInit();
    unawaited(scoreboardResultService.resetLinkedMatchAfterSubmission());
    persistence.clear();
    _notify();
  }
}
