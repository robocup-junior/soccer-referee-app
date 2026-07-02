import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';

/// Shared helpers for entering/resolving a BLE device address (robot modules
/// and the BLE bridge alike).
///
/// On iOS a BLE peripheral is addressed by a CoreBluetooth UUID, not a MAC, so
/// the address field and the QR-resolve flow differ by platform. These helpers
/// are the single source of truth for that difference; `module_settings.dart`
/// and `settings.dart` both use them.

/// True when the device address is a CoreBluetooth UUID (iOS) rather than a MAC.
bool get useIosBleUuid => !kIsWeb && Platform.isIOS;

/// Input mask for the device-address field: a CoreBluetooth UUID on iOS, a
/// colon-separated MAC on Android.
MaskTextInputFormatter buildBleAddressMask() => MaskTextInputFormatter(
      mask: useIosBleUuid
          ? '########-####-####-####-############'
          : '##:##:##:##:##:##',
      filter: useIosBleUuid
          ? {'#': RegExp('[0-9A-Fa-f-]')}
          : {'#': RegExp('[0-9A-Fa-f:]')},
    );

/// Max length of the address field text (UUID vs MAC).
int get bleAddressMaxLength => useIosBleUuid ? 36 : 17;

/// Hint text for the address field.
String get bleAddressHint => useIosBleUuid
    ? 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
    : 'xx:xx:xx:xx:xx:xx';

/// QR codes always encode a MAC (the scanner only accepts a 17-char MAC), but
/// iOS cannot connect by MAC — it needs the device's CoreBluetooth UUID. Resolve
/// [mac] to a UUID by BLE-scanning for the device that advertises that MAC in
/// its name (`RCJs-m_<MAC>`, shared by robot modules and the bridge). Returns
/// the resolved UUID, or null if no matching device was seen (BLE off /
/// permission denied / not advertising / timeout).
///
/// Uses `onScanResults` with subscribe-before-`startScan` — NOT `scanResults`,
/// which is a behavior stream that replays the previous scan's cached results
/// and so could resolve to a stale device the current scan never saw. The scan
/// is always torn down in `finally`, stops as soon as a match is found, and the
/// name match is case-insensitive (the QR MAC may be lower- or upper-case).
Future<String?> resolveIosDeviceUuid(String mac) async {
  final targetName = 'RCJs-m_$mac'.toUpperCase();
  String? resolved;
  StreamSubscription<List<ScanResult>>? scanSub;

  try {
    scanSub = FlutterBluePlus.onScanResults.listen((results) {
      for (final ScanResult r in results) {
        if (r.device.platformName.toUpperCase() == targetName) {
          resolved ??= r.device.remoteId.toString();
          // Stop on match rather than waiting out the timeout: faster, and
          // shrinks the window this global scan overlaps robot control.
          unawaited(FlutterBluePlus.stopScan());
          break;
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 3));
    // Wait for the scan to stop (on the match above, or on the timeout).
    await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;
  } catch (e) {
    // BLE off / permission denied / platform scan failure: swallow so the
    // caller can surface a "not found" message instead of throwing.
    debugPrint('resolveIosDeviceUuid scan error: $e');
  } finally {
    await scanSub?.cancel();
    await FlutterBluePlus.stopScan();
  }

  return resolved;
}

/// Batch variant of [resolveIosDeviceUuid] for the scoreboard auto-pair path
/// (#82). A deep-linked match carries the robots' hardware MACs, but iOS cannot
/// connect by MAC — it needs each peripheral's CoreBluetooth UUID. Rather than
/// run one 3 s scan per module (up to 10 × 3 s in series), this runs a SINGLE
/// scan that harvests every advertised `RCJs-m_<MAC>` into a MAC→UUID map, so
/// auto-pairing an entire field costs one scan.
///
/// Returns a map keyed by the UPPER-CASE MAC (callers look up with
/// `mac.toUpperCase()`) → resolved UUID, containing only the [macs] actually
/// seen advertising. MACs not seen (BLE off / powered down / out of range /
/// timeout) are simply absent — the caller leaves those slots unpaired for a
/// manual QR/scan, exactly as the single-MAC QR path shows "no device found".
///
/// Same validated scan lifecycle as [resolveIosDeviceUuid]: subscribe to
/// `onScanResults` BEFORE `startScan` (never the replay-prone `scanResults`),
/// case-insensitive name match, and always tear the scan down in `finally`.
/// Stops early once every requested MAC has been resolved; otherwise runs to
/// the timeout. This resolve-scan runs only at pairing time (clock stopped,
/// `!inGame`) — never on the START/STOP path (invariant #1).
Future<Map<String, String>> resolveIosDeviceUuids(Iterable<String> macs) async {
  // Map the target advertised name -> upper-case MAC so a scan hit resolves
  // straight back to the MAC key the caller will look up by.
  final macByTargetName = <String, String>{};
  for (final mac in macs) {
    if (mac.isEmpty) continue;
    final upper = mac.toUpperCase();
    macByTargetName['RCJs-m_$upper'.toUpperCase()] = upper;
  }
  final resolved = <String, String>{};
  if (macByTargetName.isEmpty) return resolved;

  StreamSubscription<List<ScanResult>>? scanSub;
  try {
    scanSub = FlutterBluePlus.onScanResults.listen((results) {
      for (final ScanResult r in results) {
        final mac = macByTargetName[r.device.platformName.toUpperCase()];
        if (mac != null) {
          resolved[mac] = r.device.remoteId.toString();
        }
      }
      // Stop as soon as every requested MAC is resolved: faster, and shrinks
      // the window this scan overlaps robot control.
      if (resolved.length == macByTargetName.length) {
        unawaited(FlutterBluePlus.stopScan());
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 3));
    await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;
  } catch (e) {
    // BLE off / permission denied / platform scan failure: swallow so the
    // caller can leave unresolved slots for a manual pair instead of throwing.
    debugPrint('resolveIosDeviceUuids scan error: $e');
  } finally {
    await scanSub?.cancel();
    await FlutterBluePlus.stopScan();
  }

  return resolved;
}
