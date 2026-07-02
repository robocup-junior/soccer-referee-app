import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/services/ios_mac_resolver.dart';

/// Harness with every seam injected: no BLE, no timers longer than a few ms.
class _Harness {
  final resolved = <(int, String, String)>[];
  final gaveUp = <int>[];
  final scannedBatches = <Set<String>>[];
  bool canScan = true;
  int stopScanCalls = 0;

  /// Queue of scan outcomes; each scan pops one (empty map when exhausted).
  final scanOutcomes = <Map<String, String>>[];

  /// Completer used by tests that need to hold a scan in flight.
  Completer<Map<String, String>>? pendingScan;

  late final IosMacResolveController controller = IosMacResolveController(
    scan: (macs) {
      scannedBatches.add(macs);
      if (pendingScan != null) return pendingScan!.future;
      return Future.value(
          scanOutcomes.isEmpty ? const {} : scanOutcomes.removeAt(0));
    },
    stopScan: () => stopScanCalls++,
    canScanNow: () => canScan,
    onResolved: (id, mac, uuid) => resolved.add((id, mac, uuid)),
    onGaveUp: gaveUp.add,
    retryDelay: const Duration(milliseconds: 1),
  );
}

Future<void> _settle() => Future.delayed(const Duration(milliseconds: 20));

void main() {
  test('enroll → scan → onResolved, pending drains and loop stops', () async {
    final h = _Harness();
    h.scanOutcomes.add({'AA:BB:CC:DD:EE:FF': 'uuid-1'});
    h.controller.enroll(3, 'aa:bb:cc:dd:ee:ff');
    await _settle();
    expect(h.resolved, [(3, 'AA:BB:CC:DD:EE:FF', 'uuid-1')]);
    expect(h.controller.pendingCount, 0);
    expect(h.scannedBatches.length, 1);
    expect(h.scannedBatches.single, {'AA:BB:CC:DD:EE:FF'});
  });

  test('partial resolve keeps the miss pending and retries', () async {
    final h = _Harness();
    h.scanOutcomes.add({'AA:BB:CC:DD:EE:FF': 'uuid-1'});
    h.scanOutcomes.add({'11:22:33:44:55:66': 'uuid-2'});
    h.controller.enroll(0, 'AA:BB:CC:DD:EE:FF');
    h.controller.enroll(1, '11:22:33:44:55:66');
    await _settle();
    expect(h.resolved.toSet(), {
      (0, 'AA:BB:CC:DD:EE:FF', 'uuid-1'),
      (1, '11:22:33:44:55:66', 'uuid-2')
    });
    expect(h.scannedBatches.length, 2);
    // Second round only scanned for the miss.
    expect(h.scannedBatches[1], {'11:22:33:44:55:66'});
  });

  test('no scan when canScanNow is false; enrollment gives up immediately',
      () async {
    final h = _Harness();
    h.canScan = false;
    h.controller.enroll(2, 'AA:BB:CC:DD:EE:FF');
    await _settle();
    expect(h.scannedBatches, isEmpty);
    expect(h.gaveUp, [2]);
    expect(h.resolved, isEmpty);
  });

  test(
      'stopForMatch marks pending as gave-up, stops the scan, and drops an '
      'in-flight result (stale resolve cannot revive)', () async {
    final h = _Harness();
    h.pendingScan = Completer();
    h.controller.enroll(4, 'AA:BB:CC:DD:EE:FF');
    await _settle(); // loop is now awaiting the held scan
    expect(h.scannedBatches.length, 1);

    h.controller.stopForMatch();
    expect(h.gaveUp, [4]);
    expect(h.stopScanCalls, greaterThan(0));

    h.pendingScan!.complete({'AA:BB:CC:DD:EE:FF': 'uuid-late'});
    await _settle();
    expect(h.resolved, isEmpty);
    expect(h.controller.pendingCount, 0);
  });

  test('stopForMatch is idempotent and enroll afterwards gives up immediately',
      () async {
    final h = _Harness();
    h.controller.stopForMatch();
    h.controller.stopForMatch();
    h.controller.enroll(5, 'AA:BB:CC:DD:EE:FF');
    await _settle();
    expect(h.gaveUp, [5]);
    expect(h.scannedBatches, isEmpty);
  });

  test('cancel removes a module mid-flight; its late hit is dropped', () async {
    final h = _Harness();
    h.pendingScan = Completer();
    h.controller.enroll(6, 'AA:BB:CC:DD:EE:FF');
    h.controller.enroll(7, '11:22:33:44:55:66');
    await _settle();

    h.controller.cancel(6);
    h.pendingScan!.complete({
      'AA:BB:CC:DD:EE:FF': 'uuid-1',
      '11:22:33:44:55:66': 'uuid-2',
    });
    h.pendingScan = null;
    await _settle();
    expect(h.resolved, [(7, '11:22:33:44:55:66', 'uuid-2')]);
  });

  test('re-enrolling a module replaces its MAC (latest wins)', () async {
    final h = _Harness();
    h.pendingScan = Completer();
    h.controller.enroll(8, 'AA:BB:CC:DD:EE:FF');
    await _settle();
    h.controller.enroll(8, '11:22:33:44:55:66');
    h.pendingScan!.complete({'AA:BB:CC:DD:EE:FF': 'uuid-old'});
    h.pendingScan = null;
    h.scanOutcomes.add({'11:22:33:44:55:66': 'uuid-new'});
    await _settle();
    expect(h.resolved, [(8, '11:22:33:44:55:66', 'uuid-new')]);
  });

  test('reset re-arms after stopForMatch (next match scans again)', () async {
    final h = _Harness();
    h.controller.stopForMatch();
    h.controller.reset();
    h.scanOutcomes.add({'AA:BB:CC:DD:EE:FF': 'uuid-1'});
    h.controller.enroll(9, 'AA:BB:CC:DD:EE:FF');
    await _settle();
    expect(h.resolved, [(9, 'AA:BB:CC:DD:EE:FF', 'uuid-1')]);
  });

  test('dispose stops the loop; nothing fires afterwards', () async {
    final h = _Harness();
    h.pendingScan = Completer();
    h.controller.enroll(1, 'AA:BB:CC:DD:EE:FF');
    await _settle();
    h.controller.dispose();
    h.pendingScan!.complete({'AA:BB:CC:DD:EE:FF': 'uuid-1'});
    await _settle();
    expect(h.resolved, isEmpty);
    h.controller.enroll(2, '11:22:33:44:55:66');
    await _settle();
    expect(h.scannedBatches.length, 1);
  });

  test(
      'gates are re-checked between rounds: canScanNow flipping false stops '
      'the loop without giving up pending', () async {
    final h = _Harness();
    h.scanOutcomes.add(const {}); // first round finds nothing
    h.controller.enroll(1, 'AA:BB:CC:DD:EE:FF');
    // Flip the gate while the first round runs.
    h.canScan = false;
    await _settle();
    expect(h.scannedBatches.length, 1);
    expect(h.controller.pendingCount, 1);
    expect(h.resolved, isEmpty);
  });
}
