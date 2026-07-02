import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';

/// Shared helpers for entering/resolving a BLE device address (robot modules
/// and the BLE bridge alike).
///
/// On iOS a BLE peripheral is addressed by a CoreBluetooth UUID, not a MAC, so
/// the address field and the QR-resolve flow differ by platform. These helpers
/// are the single source of truth for that difference; `module_settings.dart`
/// and `settings.dart` both use them.

/// Test-only override for [useIosBleUuid]: `Platform.isIOS` cannot be faked in
/// a headless test, so iOS-branch logic (auto-pair, hardwareMac backfills) is
/// exercised by setting this. Always reset to null in tearDown.
@visibleForTesting
bool? debugUseIosBleUuidOverride;

/// True when the device address is a CoreBluetooth UUID (iOS) rather than a MAC.
bool get useIosBleUuid =>
    debugUseIosBleUuidOverride ?? (!kIsWeb && Platform.isIOS);

/// Strict colon-separated hardware-MAC shape (`AA:BB:CC:DD:EE:FF`, either
/// case) — the same shape the QR scanner accepts. A CoreBluetooth UUID never
/// matches, so this doubles as the platform-free "is this a hardware MAC?"
/// test used by the #82 connection-id / hardware-MAC split.
final RegExp _macRegExp = RegExp(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$');

bool isMacFormat(String s) => _macRegExp.hasMatch(s);

/// The firmware advertises the module's real MAC inside its BLE name:
/// `RCJs-m_<MAC>` (confirmed against the FW repo — a stale comment elsewhere
/// claims `RCJ-soccer_module-`, which is wrong). Shared by robot modules and
/// the scoreboard bridge, so callers must key on the full MAC, never on the
/// prefix alone.
const String kModuleNamePrefix = 'RCJs-m_';

/// Parse the hardware MAC back out of an advertised/platform name, or null if
/// the name is not a module-style name. Case-insensitive; the returned MAC is
/// normalized to uppercase.
String? macFromAdvertisedName(String name) {
  final trimmed = name.trim();
  if (trimmed.length != kModuleNamePrefix.length + 17) return null;
  if (!trimmed.toUpperCase().startsWith(kModuleNamePrefix.toUpperCase())) {
    return null;
  }
  final mac = trimmed.substring(kModuleNamePrefix.length);
  return isMacFormat(mac) ? mac.toUpperCase() : null;
}

/// Fold a batch of scan results into a `MAC → remoteId` map for the [wanted]
/// MACs. Pure (no BLE calls) so the batch-resolve matching is unit-testable.
/// Prefers the live advertised name over `platformName` (fbp's cached/GAP name,
/// which can be stale or empty for a never-connected device). First sighting of
/// a MAC wins. Matching is case-insensitive on both sides.
Map<String, String> foldScanHits(
    Set<String> wanted, Iterable<ScanResult> results) {
  final wantedUpper = wanted.map((m) => m.toUpperCase()).toSet();
  final hits = <String, String>{};
  for (final r in results) {
    final name = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : r.device.platformName;
    final mac = macFromAdvertisedName(name);
    if (mac == null || !wantedUpper.contains(mac)) continue;
    hits.putIfAbsent(mac, () => r.device.remoteId.toString());
  }
  return hits;
}

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

/// Input formatters for the MODULE address field (#82): iOS accepts EITHER a
/// hardware MAC (resolved to a UUID by scan on Connect, matching the Android
/// UX) or a raw CoreBluetooth UUID, so a fixed mask can't apply — just filter
/// to plausible characters. Android keeps the strict MAC mask. The bridge
/// address field intentionally keeps [buildBleAddressMask] (UUID-only on iOS).
List<TextInputFormatter> buildModuleAddressFormatters() => useIosBleUuid
    ? [FilteringTextInputFormatter.allow(RegExp('[0-9A-Fa-f:-]'))]
    : [buildBleAddressMask()];

/// Label for the module address field (see [buildModuleAddressFormatters]).
String get moduleAddressLabel =>
    useIosBleUuid ? 'Enter MAC or device UUID' : 'Enter MAC Address';

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
  final hits = await resolveIosDeviceUuids({mac});
  return hits[mac.toUpperCase()];
}

/// Batch generalization of [resolveIosDeviceUuid]: ONE scan resolves every
/// advertised module in [macs] to its CoreBluetooth UUID (`MAC → UUID` map,
/// uppercase MAC keys). Used by the iOS match-load auto-pair (#82) so ten
/// server-supplied MACs cost a single scan, not ten.
///
/// Returns a partial (possibly empty) map — absent modules simply don't
/// appear. Stops early once every wanted MAC is seen. Errors are swallowed
/// (BLE off / permission denied / scan preempted by another `startScan`
/// elsewhere — fbp allows one scan process-wide) so callers treat any miss as
/// "not found, retry later".
Future<Map<String, String>> resolveIosDeviceUuids(Set<String> macs,
    {Duration timeout = const Duration(seconds: 3)}) async {
  final wanted = macs.map((m) => m.toUpperCase()).toSet();
  final hits = <String, String>{};
  StreamSubscription<List<ScanResult>>? scanSub;

  try {
    scanSub = FlutterBluePlus.onScanResults.listen((results) {
      hits.addAll(foldScanHits(wanted.difference(hits.keys.toSet()), results));
      if (hits.length == wanted.length) {
        // Stop on all-found rather than waiting out the timeout: faster, and
        // shrinks the window this global scan overlaps robot control.
        unawaited(FlutterBluePlus.stopScan());
      }
    });

    await FlutterBluePlus.startScan(timeout: timeout);
    // Wait for the scan to stop (all found above, timeout, or preempted).
    await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;
  } catch (e) {
    // BLE off / permission denied / platform scan failure: swallow so the
    // caller can surface a "not found" message instead of throwing.
    debugPrint('resolveIosDeviceUuids scan error: $e');
  } finally {
    await scanSub?.cancel();
    try {
      await FlutterBluePlus.stopScan();
    } catch (e) {
      // Same failure classes as above — the teardown must never throw.
      debugPrint('resolveIosDeviceUuids stopScan error: $e');
    }
  }

  return hits;
}
