import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../utils/ble_address.dart' as ble_address;

/// iOS-only MAC→UUID resolve loop (#82).
///
/// CoreBluetooth addresses peripherals by a per-phone UUID learned only by
/// seeing the module advertise (`RCJs-m_<MAC>`). Modules are [enroll]ed at
/// match load; one batch scan per round resolves every pending MAC while
/// [canScanNow] allows it (no half running). [stopForMatch] at kickoff ends
/// scanning for the rest of the match (a scan competes with the radio used
/// for START/STOP, invariant #1). Each resolution feeds exactly one connect
/// via [onResolved]; reconnection stays OS-owned (invariant #5). Every seam
/// is injectable so the state machine is unit-testable without BLE.
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
        _isForeignScanRunning = isForeignScanRunning ?? (() => FlutterBluePlus.isScanningNow),
        _retryDelay = retryDelay,
        _preemptedRetryDelay = preemptedRetryDelay;

  static void _defaultStopScan() => unawaited(FlutterBluePlus.stopScan()
      .catchError((Object e) => debugPrint('IosMacResolveController stopScan error: $e')));

  static const _maxConsecutiveFastRetries = 3;

  final Future<Map<String, String>> Function(Set<String> macs) _scan;
  final void Function() _stopScan;
  final bool Function() _canScanNow;
  final void Function(int moduleId, String mac, String uuid) _onResolved;
  final void Function(int moduleId) _onGaveUp;
  final bool Function() _isForeignScanRunning;
  final Duration _retryDelay;
  final Duration _preemptedRetryDelay;

  /// moduleId → wanted hardware MAC (uppercase). Latest enroll wins per id.
  final Map<int, String> _pending = {};
  int _consecutiveFastRetries = 0;
  bool _stoppedForMatch = false;
  bool _running = false;
  // Only while OUR scan call is in flight; never stop a scan we don't own
  // (it may be the referee's manual settings scan).
  bool _ownScanInFlight = false;
  bool _disposed = false;

  @visibleForTesting
  int get pendingCount => _pending.length;

  /// Resolve [mac] for [moduleId]. If scanning is impossible right now the
  /// module gives up immediately (manual scan/QR stays available).
  void enroll(int moduleId, String mac) {
    if (_disposed) return;
    if (_stoppedForMatch || !_canScanNow()) {
      _onGaveUp(moduleId);
      return;
    }
    _pending[moduleId] = mac.toUpperCase();
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  /// Drop a module (Cancel / re-target); an in-flight hit for it is discarded.
  void cancel(int moduleId) => _pending.remove(moduleId);

  /// One-shot at kickoff; synchronous and cheap (sits on the START path).
  void stopForMatch() {
    if (_stoppedForMatch) return;
    _stoppedForMatch = true;
    if (_ownScanInFlight) _stopScan();
    final gaveUp = List<int>.from(_pending.keys);
    _pending.clear();
    gaveUp.forEach(_onGaveUp);
  }

  /// Between-matches re-arm.
  void reset() {
    _pending.clear();
    _stoppedForMatch = false;
    _consecutiveFastRetries = 0;
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
  }

  Future<void> _loop() async {
    try {
      while (!_disposed && !_stoppedForMatch && _pending.isNotEmpty && _canScanNow()) {
        // A referee-initiated scan owns the (single, process-wide) radio.
        if (_isForeignScanRunning()) {
          await Future.delayed(_retryDelay);
          continue;
        }
        final stopwatch = Stopwatch()..start();
        Map<String, String> hits;
        _ownScanInFlight = true;
        try {
          hits = await _scan(_pending.values.toSet());
        } finally {
          _ownScanInFlight = false;
        }
        // A gate may have closed while scanning: a stale hit must not connect.
        if (_disposed || _stoppedForMatch) break;
        for (final entry in List.of(_pending.entries)) {
          final uuid = hits[entry.value];
          if (uuid == null) continue;
          _pending.remove(entry.key);
          _onResolved(entry.key, entry.value, uuid);
        }
        if (_pending.isEmpty) break;
        // Another startScan silently stops ours (near-instant empty round):
        // retry fast, but bounded, since a scan ERROR looks the same.
        final preempted = hits.isEmpty &&
            stopwatch.elapsed < const Duration(seconds: 1) &&
            _consecutiveFastRetries < _maxConsecutiveFastRetries;
        _consecutiveFastRetries = preempted ? _consecutiveFastRetries + 1 : 0;
        await Future.delayed(preempted ? _preemptedRetryDelay : _retryDelay);
      }
    } finally {
      _running = false;
    }
  }
}
