import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../utils/ble_address.dart' as ble_address;

/// iOS-only MAC→UUID resolve controller (#82).
///
/// iOS cannot connect to a module by its hardware MAC — CoreBluetooth
/// addresses peripherals by a per-phone UUID that is only learned by seeing
/// the module advertise (`RCJs-m_<MAC>`). This controller owns the "which
/// MACs still need a UUID" bookkeeping and the bounded rescan that resolves
/// them:
///
///  * Modules are [enroll]ed at match load (auto-pair), preset apply, or when
///    a cached UUID turns out to be stale ("Peripheral not found").
///  * A background loop runs ONE batch scan per round for all still-pending
///    MACs, while — and only while — [canScanNow] allows it (no half running).
///  * [stopForMatch] is called synchronously at kickoff: it stops scanning for
///    the rest of the match (invariant #1 — a BLE scan competes with the radio
///    used for robot START/STOP) and marks pending modules "not found"; the
///    referee's manual QR/scan fallback stays available at any time.
///  * Resolution feeds exactly ONE `connect(autoConnect:true)` per module via
///    [onResolved]; reconnection after power-cycles stays OS-owned (invariant
///    #5 — this controller never reacts to disconnect events).
///
/// Every seam (scan, stopScan, gate, callbacks, retry delay) is injectable so
/// the state machine is fully unit-testable without BLE.
class IosMacResolveController {
  IosMacResolveController({
    Future<Map<String, String>> Function(Set<String> macs)? scan,
    void Function()? stopScan,
    required bool Function() canScanNow,
    required void Function(int moduleId, String mac, String uuid) onResolved,
    required void Function(int moduleId) onGaveUp,
    bool Function()? isForeignScanRunning,
    Duration retryDelay = const Duration(seconds: 4),
    Duration preemptedRetryDelay = const Duration(milliseconds: 300),
  })  : _scan = scan ?? ble_address.resolveIosDeviceUuids,
        _stopScan = stopScan ?? _defaultStopScan,
        _canScanNow = canScanNow,
        _onResolved = onResolved,
        _onGaveUp = onGaveUp,
        _isForeignScanRunning =
            isForeignScanRunning ?? _defaultIsForeignScanRunning,
        _retryDelay = retryDelay,
        _preemptedRetryDelay = preemptedRetryDelay;

  static void _defaultStopScan() =>
      unawaited(FlutterBluePlus.stopScan().catchError((Object e) {
        // BLE off / unsupported platform: there is no scan to stop.
        debugPrint('IosMacResolveController stopScan error: $e');
      }));

  final Future<Map<String, String>> Function(Set<String> macs) _scan;
  final void Function() _stopScan;
  final bool Function() _canScanNow;
  final void Function(int moduleId, String mac, String uuid) _onResolved;
  static bool _defaultIsForeignScanRunning() => FlutterBluePlus.isScanningNow;

  final void Function(int moduleId) _onGaveUp;
  final bool Function() _isForeignScanRunning;
  final Duration _retryDelay;
  final Duration _preemptedRetryDelay;
  static const int _maxConsecutiveFastRetries = 3;
  int _consecutiveFastRetries = 0;

  /// moduleId → wanted hardware MAC (uppercase). Latest enroll wins per id.
  final Map<int, String> _pending = {};
  bool _stoppedForMatch = false;
  bool _running = false;
  bool _disposed = false;

  @visibleForTesting
  int get pendingCount => _pending.length;

  /// Ask the controller to resolve [mac] for module [moduleId]. If scanning is
  /// currently impossible (match running / already stopped for this match) the
  /// module immediately reports as given up — the referee falls back to the
  /// manual scan/QR path; nothing is queued behind a closed gate.
  void enroll(int moduleId, String mac) {
    if (_disposed) return;
    if (_stoppedForMatch || !_canScanNow()) {
      _onGaveUp(moduleId);
      return;
    }
    _pending[moduleId] = mac.toUpperCase();
    _kick();
  }

  /// Drop a module from the pending set (user Cancel / re-target). An
  /// in-flight scan hit for it is discarded at apply time.
  void cancel(int moduleId) {
    _pending.remove(moduleId);
  }

  /// One-shot at kickoff: no more scanning for the rest of this match.
  /// Synchronous and cheap (flag + unawaited stopScan) — it sits on the
  /// START path (invariant #1). Idempotent: warm-resume tick replay can cross
  /// stage transitions in one burst.
  void stopForMatch() {
    if (_stoppedForMatch) return;
    _stoppedForMatch = true;
    _stopScan();
    final gaveUp = List<int>.from(_pending.keys);
    _pending.clear();
    gaveUp.forEach(_onGaveUp);
  }

  /// Between-matches re-arm (gameInit / REPEAT / full-time teardown /
  /// confirmed new Load): forget pending work and allow scanning again for
  /// the next match's load.
  void reset() {
    _pending.clear();
    _stoppedForMatch = false;
    _consecutiveFastRetries = 0;
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
  }

  void _kick() {
    if (_running || _disposed) return;
    _running = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    try {
      while (!_disposed &&
          !_stoppedForMatch &&
          _pending.isNotEmpty &&
          _canScanNow()) {
        // Manual, referee-initiated scans always win the (single, process-
        // wide) radio: starting ours would silently kill a running settings
        // list scan or QR/MAC resolve — the exact fallback the design keeps
        // for a module the auto-resolve hasn't found (#82 review round 2).
        // Yield the whole round and check back on the normal cadence.
        if (_isForeignScanRunning()) {
          await Future.delayed(_retryDelay);
          continue;
        }
        final stopwatch = Stopwatch()..start();
        final hits = await _scan(_pending.values.toSet());
        stopwatch.stop();
        // Gates may have closed while the scan ran (kickoff, dispose, reset):
        // a stale hit must never connect a module the match moved past.
        if (_disposed || _stoppedForMatch) break;
        for (final entry
            in List<MapEntry<int, String>>.from(_pending.entries)) {
          final uuid = hits[entry.value];
          if (uuid == null) continue;
          _pending.remove(entry.key);
          _onResolved(entry.key, entry.value, uuid);
        }
        if (_pending.isEmpty) break;
        // fbp allows ONE scan process-wide: another startScan (settings list
        // scan, a QR resolve) silently stops ours, which surfaces here as a
        // near-instant empty round. Retry quickly in that case so a
        // preemption can't eat a whole pre-kickoff resolve window; a
        // full-length empty round keeps the normal cadence. Two bounds keep
        // this from degrading into a hot loop (#82 review round 2): a scan
        // ERROR (BLE off / permission denied) also returns near-instantly
        // empty, so consecutive fast retries are capped; and while a foreign
        // scan is still running the loop yields above instead of retrying
        // into it.
        final preempted = hits.isEmpty &&
            stopwatch.elapsed < const Duration(seconds: 1) &&
            _consecutiveFastRetries < _maxConsecutiveFastRetries;
        _consecutiveFastRetries = preempted ? _consecutiveFastRetries + 1 : 0;
        await Future.delayed(preempted ? _preemptedRetryDelay : _retryDelay);
      }
    } finally {
      _running = false;
    }
    // A gate may have re-opened between the while-check and _running=false
    // only via enroll(), which re-kicks; no self-rescheduling needed here.
  }
}
