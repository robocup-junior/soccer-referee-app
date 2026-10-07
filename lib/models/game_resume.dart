// Part of game.dart: cold-resume snapshot build and restore (#45).
part of 'game.dart';

/// Snapshot build/restore: a killed app re-offers the match on the next launch.
extension GameResume on Game {
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
      scoreboardMatchCode: isReferee
          ? (liveReferee ? config.matchCode : _sb.resumedMatchCode)
          : null,
      scoreboardVersion: isReferee
          ? (liveReferee ? config.version : _sb.resumedVersion)
          : null,
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
      final stage = Game._stageFromName(snapshot.stage);
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
          iosPairing.pairByMac(m, m.hardwareMac,
              label: m.hasCustomLabel ? m.name : '');
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
    _notify();
  }

  /// Re-arm the final-result POST for a resumed referee match (#53). Drift
  /// guard keys on match_code only: a version bump is the same fixture.
  void _restoreScoreboardBinding(MatchSnapshot snapshot) {
    final resumedCode = snapshot.scoreboardMatchCode;
    final config = scoreboardResultService.matchConfig;
    final sameOrUnknown = config == null || config.matchCode == resumedCode;
    if (!snapshot.isRefereeMatch ||
        resumedCode == null ||
        resumedCode.isEmpty ||
        !sameOrUnknown) {
      // Non-referee match, or a DIFFERENT fixture is loaded: never POST.
      _sb.bindResumed(
          homeTeamId: null, awayTeamId: null, matchCode: null, version: null);
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
    _notify();
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
    _notify();
  }
}
