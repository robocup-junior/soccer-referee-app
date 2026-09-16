import 'dart:async';

import 'package:rcj_scoreboard/services/match_state_store.dart';

/// Coalesced persistence of the in-progress match (cold-resume, #45).
///
/// Two speeds, chosen by the caller:
///  * [markDirty] is a bare flag, cheap enough for the robot START/STOP fan-out
///    (CLAUDE.md invariant #1). The clock heartbeat flushes it.
///  * [markDirtyAndFlush] schedules the snapshot build + write on a microtask,
///    for discrete events off the hot path (label edit, penalty, score).
///
/// Persistence is a no-op until [attach] and while [suppressed] (bootstrap,
/// reset and the multi-step restore must not write partial snapshots).
class MatchPersistence {
  MatchPersistence(this._buildSnapshot);

  final MatchSnapshot Function() _buildSnapshot;
  MatchStateStore? _store;
  bool _dirty = false;
  bool suppressed = false;

  void attach(MatchStateStore store) => _store = store;

  MatchSnapshot? load() => _store?.load();

  void markDirty() {
    if (suppressed || _store == null) return;
    _dirty = true;
  }

  void markDirtyAndFlush() {
    if (suppressed || _store == null) return;
    _dirty = true;
    scheduleMicrotask(flush);
  }

  /// Write the snapshot now if anything is dirty.
  void flush() {
    if (suppressed || !_dirty) return;
    final store = _store;
    if (store == null) return;
    _dirty = false;
    unawaited(store.save(_buildSnapshot()));
  }

  /// Force a write of the current state (marks dirty first).
  void flushNow() {
    markDirty();
    flush();
  }

  /// Force a write and wait for it to land; for paths whose correctness
  /// depends on durability (never on the robot hot path).
  Future<void> flushNowAndWait() async {
    if (suppressed) return;
    final store = _store;
    if (store == null) return;
    _dirty = false;
    await store.save(_buildSnapshot());
  }

  /// Tombstone the snapshot (match over / discarded / replaced).
  void clear() {
    _dirty = false;
    unawaited(_store?.clear());
  }

  Future<void> clearAndWait() async {
    _dirty = false;
    await _store?.clear();
  }

  /// Run [body] with persistence suppressed, then re-enable it.
  void suppress(void Function() body) {
    suppressed = true;
    try {
      body();
    } finally {
      suppressed = false;
    }
  }
}
