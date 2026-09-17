import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Schema version of the persisted match snapshot; any other version is
/// ignored on load. Bump on an incompatible shape change.
const int kMatchSnapshotVersion = 2;

@immutable
class TeamSnapshot {
  const TeamSnapshot({required this.id, required this.name, required this.score});

  final String id;
  final String name;
  final int score;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'score': score};

  factory TeamSnapshot.fromJson(Map<String, dynamic> json) => TeamSnapshot(
        id: json['id'] as String,
        name: json['name'] as String,
        score: (json['score'] as num).toInt(),
      );
}

/// Per-module recoverable state. `macAddress` (the connection id) is what a
/// cold kill reconnects with; `hardwareMac` (#82) is optional for old
/// snapshots. `state`/`lastState` are `ModuleState.name`s.
@immutable
class ModuleSnapshot {
  const ModuleSnapshot({
    required this.moduleId,
    required this.isEnabled,
    required this.macAddress,
    this.hardwareMac = '',
    required this.customLabel,
    required this.state,
    required this.lastState,
    required this.penaltyTime,
  });

  final int moduleId;
  final bool isEnabled;
  final String macAddress;
  final String hardwareMac;
  final String? customLabel;
  final String state;
  final String lastState;
  final int penaltyTime;

  Map<String, dynamic> toJson() => {
        'moduleId': moduleId,
        'isEnabled': isEnabled,
        'macAddress': macAddress,
        'hardwareMac': hardwareMac,
        'customLabel': customLabel,
        'state': state,
        'lastState': lastState,
        'penaltyTime': penaltyTime,
      };

  factory ModuleSnapshot.fromJson(Map<String, dynamic> json) => ModuleSnapshot(
        moduleId: (json['moduleId'] as num).toInt(),
        isEnabled: json['isEnabled'] as bool,
        macAddress: json['macAddress'] as String,
        hardwareMac: json['hardwareMac'] as String? ?? '',
        customLabel: json['customLabel'] as String?,
        state: json['state'] as String,
        lastState: json['lastState'] as String,
        penaltyTime: (json['penaltyTime'] as num).toInt(),
      );
}

/// One versioned snapshot of the whole match, stored as a single JSON value.
/// `isTimeRunning` is diagnostic only: a resume always freezes the clock. The
/// scoreboard fields (#53) are set only for a referee (deep-link) match.
@immutable
class MatchSnapshot {
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

  final int version;
  final String stage;
  final int remainingTime;
  final bool isTimeRunning;
  final bool inGame;
  final String timerButtonText;
  final List<TeamSnapshot> teams; // display order (captures a side swap)
  final List<ModuleSnapshot> modules;
  final int savedAtMs;
  final bool isRefereeMatch;
  final String? scoreboardMatchCode;
  final int? scoreboardVersion;
  final String? scoreboardHomeTeamId;
  final String? scoreboardAwayTeamId;

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

/// Persists exactly one [MatchSnapshot] with serialized, coalesced writes so a
/// slow older write can never overwrite a newer one or resurrect a discarded
/// match: rapid save/clear calls collapse to the latest intent, and `clear()`
/// bumps a generation persisted as a tombstone that `load()` checks, which
/// makes the ordering crash-safe (a stale save that beat a clear to disk is
/// rejected on the next launch).
class MatchStateStore {
  MatchStateStore(this._prefs) : _generation = _prefs.getInt(_tombstoneKey) ?? 0;

  static const _snapshotKey = 'match_state_snapshot';
  static const _tombstoneKey = 'match_state_tombstone_generation';

  final SharedPreferences _prefs;
  int _generation;
  // At most one write in flight; the latest requested state waits in the slot.
  bool _hasPending = false;
  bool _pendingIsClear = false;
  MatchSnapshot? _pendingSnapshot;
  int _pendingGeneration = 0;
  Future<void>? _drainFuture;

  Future<void> save(MatchSnapshot snapshot) {
    _pendingIsClear = false;
    _pendingSnapshot = snapshot;
    _pendingGeneration = _generation;
    _hasPending = true;
    return _drain();
  }

  /// Record the clear intent BEFORE awaiting the tombstone write so a save
  /// racing in meanwhile is the genuinely-last caller, then drain.
  Future<void> clear() async {
    _generation++;
    _pendingIsClear = true;
    _pendingSnapshot = null;
    _pendingGeneration = _generation;
    _hasPending = true;
    await _write('tombstone', () => _prefs.setInt(_tombstoneKey, _generation));
    return _drain();
  }

  Future<void> _drain() => _drainFuture ??= _runDrain();

  Future<void> _runDrain() async {
    try {
      while (_hasPending) {
        final isClear = _pendingIsClear;
        final snapshot = _pendingSnapshot;
        final generation = _pendingGeneration;
        _hasPending = false;
        _pendingIsClear = false;
        _pendingSnapshot = null;
        if (isClear) {
          await _write('snapshot remove', () => _prefs.remove(_snapshotKey));
        } else if (snapshot != null) {
          final map = snapshot.toJson()..['generation'] = generation;
          await _write('snapshot save', () => _prefs.setString(_snapshotKey, jsonEncode(map)));
        }
      }
    } finally {
      _drainFuture = null;
    }
  }

  static Future<void> _write(String what, Future<bool> Function() op) async {
    try {
      if (!await op()) debugPrint('MatchStateStore: $what returned false');
    } catch (e) {
      debugPrint('MatchStateStore: $what failed: $e');
    }
  }

  /// The persisted snapshot, or null when missing, unparseable, of another
  /// schema version, or older than the tombstone.
  MatchSnapshot? load() {
    final raw = _prefs.getString(_snapshotKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if ((decoded['version'] as num?)?.toInt() != kMatchSnapshotVersion) return null;
      final generation = (decoded['generation'] as num?)?.toInt() ?? 0;
      if (generation < (_prefs.getInt(_tombstoneKey) ?? 0)) return null;
      return MatchSnapshot.fromJson(decoded);
    } catch (e) {
      debugPrint('MatchStateStore.load parse failed: $e');
      return null;
    }
  }
}
