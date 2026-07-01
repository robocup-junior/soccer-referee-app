import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Schema version of the persisted match snapshot. A snapshot with any other
/// version is ignored on load (treated as "no match"), so an old/incompatible
/// snapshot can never crash startup or restore garbage. Bump this whenever the
/// serialized shape changes incompatibly. v2 adds scoreboard binding fields.
const int kMatchSnapshotVersion = 2;

/// Per-team recoverable state. Order is preserved by [MatchSnapshot.teams] so a
/// swapped team order can be restored onto the correct physical side.
@immutable
class TeamSnapshot {
  final String id;
  final String name;
  final int score;

  const TeamSnapshot({
    required this.id,
    required this.name,
    required this.score,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'score': score,
      };

  factory TeamSnapshot.fromJson(Map<String, dynamic> json) => TeamSnapshot(
        id: json['id'] as String,
        name: json['name'] as String,
        score: (json['score'] as num).toInt(),
      );
}

/// Per-module recoverable state. Kept self-contained (flat fields) rather than
/// embedding `ModuleConfig` so the recovery schema isn't coupled to the preset
/// schema (see design doc). `macAddress` is REQUIRED for auto-reconnect after a
/// cold kill, which constructs fresh `Module`s with no device.
@immutable
class ModuleSnapshot {
  final int moduleId;
  final bool isEnabled;
  final String macAddress;
  final String? customLabel;

  /// `ModuleState.name` of `_state` at save time.
  final String state;

  /// `ModuleState.name` of `_lastState` at save time (drives `Module.stop()`).
  final String lastState;

  /// Remaining penalty/damage seconds.
  final int penaltyTime;

  const ModuleSnapshot({
    required this.moduleId,
    required this.isEnabled,
    required this.macAddress,
    required this.customLabel,
    required this.state,
    required this.lastState,
    required this.penaltyTime,
  });

  Map<String, dynamic> toJson() => {
        'moduleId': moduleId,
        'isEnabled': isEnabled,
        'macAddress': macAddress,
        'customLabel': customLabel,
        'state': state,
        'lastState': lastState,
        'penaltyTime': penaltyTime,
      };

  factory ModuleSnapshot.fromJson(Map<String, dynamic> json) => ModuleSnapshot(
        moduleId: (json['moduleId'] as num).toInt(),
        isEnabled: json['isEnabled'] as bool,
        macAddress: json['macAddress'] as String,
        customLabel: json['customLabel'] as String?,
        state: json['state'] as String,
        lastState: json['lastState'] as String,
        penaltyTime: (json['penaltyTime'] as num).toInt(),
      );
}

/// One versioned snapshot of the whole match. Written as a single JSON value
/// under one key (see design doc: splitting static vs dynamic saves nothing on
/// Android because a prefs commit rewrites the whole file).
@immutable
class MatchSnapshot {
  final int version;
  final String stage; // MatchStage.name
  final int remainingTime; // the freeze point (heartbeat-maintained)
  // Captured at save time for diagnostics/forward-compat only. The restore path
  // (Game.resumePendingMatch) deliberately does NOT consult these: a cold resume
  // always freezes the clock (or resumes the half-time break) and derives the
  // button label from the stage, so honoring a persisted isTimeRunning=true
  // would auto-run a half and violate the never-auto-PLAY invariant.
  final bool isTimeRunning; // whether the clock was running at save time
  final bool inGame;
  final String timerButtonText;
  final List<TeamSnapshot> teams; // order preserved (captures team swap)
  final List<ModuleSnapshot> modules;
  final int savedAtMs; // epoch ms, for staleness display
  /// Scoreboard binding (#53). Non-null only for a referee/deep-link match.
  /// Lets a resumed match re-arm the correct final-result POST and lets the
  /// resume path cross-check against the separately-persisted match config
  /// (drift guard) before treating the match as a live referee match.
  final bool isRefereeMatch;
  final String? scoreboardMatchCode;
  final int? scoreboardVersion;
  final String? scoreboardHomeTeamId; // 'A' or 'B'
  final String? scoreboardAwayTeamId; // 'A' or 'B'

  const MatchSnapshot({
    this.version = kMatchSnapshotVersion,
    required this.stage,
    required this.remainingTime,
    required this.isTimeRunning,
    required this.inGame,
    required this.timerButtonText,
    required this.teams,
    required this.modules,
    required this.savedAtMs,
    this.isRefereeMatch = false,
    this.scoreboardMatchCode,
    this.scoreboardVersion,
    this.scoreboardHomeTeamId,
    this.scoreboardAwayTeamId,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'stage': stage,
        'remainingTime': remainingTime,
        'isTimeRunning': isTimeRunning,
        'inGame': inGame,
        'timerButtonText': timerButtonText,
        'teams': teams.map((t) => t.toJson()).toList(),
        'modules': modules.map((m) => m.toJson()).toList(),
        'savedAtMs': savedAtMs,
        'isRefereeMatch': isRefereeMatch,
        'scoreboardMatchCode': scoreboardMatchCode,
        'scoreboardVersion': scoreboardVersion,
        'scoreboardHomeTeamId': scoreboardHomeTeamId,
        'scoreboardAwayTeamId': scoreboardAwayTeamId,
      };

  factory MatchSnapshot.fromJson(Map<String, dynamic> json) => MatchSnapshot(
        version: (json['version'] as num).toInt(),
        stage: json['stage'] as String,
        remainingTime: (json['remainingTime'] as num).toInt(),
        isTimeRunning: json['isTimeRunning'] as bool,
        inGame: json['inGame'] as bool,
        timerButtonText: json['timerButtonText'] as String,
        teams: (json['teams'] as List)
            .map((e) => TeamSnapshot.fromJson(e as Map<String, dynamic>))
            .toList(),
        modules: (json['modules'] as List)
            .map((e) => ModuleSnapshot.fromJson(e as Map<String, dynamic>))
            .toList(),
        savedAtMs: (json['savedAtMs'] as num).toInt(),
        isRefereeMatch: json['isRefereeMatch'] as bool? ?? false,
        scoreboardMatchCode: json['scoreboardMatchCode'] as String?,
        scoreboardVersion: (json['scoreboardVersion'] as num?)?.toInt(),
        scoreboardHomeTeamId: json['scoreboardHomeTeamId'] as String?,
        scoreboardAwayTeamId: json['scoreboardAwayTeamId'] as String?,
      );
}

/// Thin wrapper over [SharedPreferences] that persists exactly one
/// [MatchSnapshot] under [_snapshotKey], with **serialized + coalesced** writes
/// so a slow older write can never overwrite a newer one (or resurrect a
/// discarded match).
///
/// Ordering model:
/// - A single in-flight write + a "latest pending" slot (coalescing): rapid
///   `save`/`clear` calls collapse to the most recent intent.
/// - A monotonic [_generation], persisted as a tombstone under [_tombstoneKey].
///   `clear()` bumps the generation and persists the tombstone; each `save`
///   stamps the snapshot with the current generation. `load()` rejects any
///   snapshot whose stamped generation predates the tombstone — so even a late
///   stale `save` that physically beat a `clear` to disk is ignored on the next
///   launch. (Honest scope: the in-memory coalescing only guarantees ordering
///   while the process is alive; the tombstone is what makes it crash-safe.)
class MatchStateStore {
  static const String _snapshotKey = 'match_state_snapshot';
  static const String _tombstoneKey = 'match_state_tombstone_generation';

  final SharedPreferences _prefs;

  int _generation;

  // Coalescing state: at most one op is in flight; the latest requested
  // terminal state lives in the pending slot.
  bool _hasPending = false;
  bool _pendingIsClear = false;
  MatchSnapshot? _pendingSnapshot;
  int _pendingGeneration = 0;
  bool _draining = false;
  Future<void>? _drainFuture;

  MatchStateStore(this._prefs) : _generation = _prefs.getInt(_tombstoneKey) ?? 0;

  /// Enqueue a snapshot write (coalesced). Best-effort and never throws into
  /// the caller. Safe to call off the hot path; the actual `setString` is async.
  Future<void> save(MatchSnapshot snapshot) {
    _pendingIsClear = false;
    _pendingSnapshot = snapshot;
    _pendingGeneration = _generation;
    _hasPending = true;
    return _drain();
  }

  /// Enqueue a clear in the SAME stream (not a side API): bump the generation,
  /// record the clear intent in the pending slot, persist the tombstone (so a
  /// crash can't lose it), and drop any pending save.
  ///
  /// The intent is recorded **before** the `await`: otherwise a `save()` racing
  /// in during the tombstone write (the app calls both unawaited) would stamp
  /// the already-bumped generation, drain a snapshot, and then be wiped when the
  /// resumed clear set its pending slot — losing a newer match. Recording first
  /// makes the genuinely-last caller win (latest-intent semantics).
  Future<void> clear() async {
    _generation++;
    _pendingIsClear = true;
    _pendingSnapshot = null;
    _pendingGeneration = _generation;
    _hasPending = true;
    try {
      final ok = await _prefs.setInt(_tombstoneKey, _generation);
      if (!ok) debugPrint('MatchStateStore: tombstone write returned false');
    } catch (e) {
      debugPrint('MatchStateStore.clear tombstone write failed: $e');
    }
    return _drain();
  }

  Future<void> _drain() {
    if (_draining) return _drainFuture ?? Future<void>.value();
    _draining = true;
    _drainFuture = _runDrain();
    return _drainFuture!;
  }

  Future<void> _runDrain() async {
    try {
      while (_hasPending) {
        final isClear = _pendingIsClear;
        final snapshot = _pendingSnapshot;
        final generation = _pendingGeneration;
        _hasPending = false;
        _pendingIsClear = false;
        _pendingSnapshot = null;

        try {
          if (isClear) {
            final ok = await _prefs.remove(_snapshotKey);
            if (!ok) debugPrint('MatchStateStore: snapshot remove returned false');
          } else if (snapshot != null) {
            final map = snapshot.toJson()..['generation'] = generation;
            final ok = await _prefs.setString(_snapshotKey, jsonEncode(map));
            if (!ok) debugPrint('MatchStateStore: snapshot save returned false');
          }
        } catch (e) {
          // Best-effort: log and keep draining any newer pending op.
          debugPrint('MatchStateStore write failed: $e');
        }
      }
    } finally {
      _draining = false;
      _drainFuture = null;
    }
  }

  /// Returns the persisted snapshot, or `null` on a missing, unparseable, or
  /// version-mismatched value, or one whose generation predates the tombstone.
  MatchSnapshot? load() {
    final raw = _prefs.getString(_snapshotKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if ((decoded['version'] as num?)?.toInt() != kMatchSnapshotVersion) {
        return null;
      }
      final generation = (decoded['generation'] as num?)?.toInt() ?? 0;
      final tombstone = _prefs.getInt(_tombstoneKey) ?? 0;
      if (generation < tombstone) return null;
      return MatchSnapshot.fromJson(decoded);
    } catch (e) {
      debugPrint('MatchStateStore.load parse failed: $e');
      return null;
    }
  }
}
