import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:rcj_scoreboard/utils/ble_address.dart';
import 'package:rcj_scoreboard/utils/colors.dart';
import 'package:rcj_scoreboard/widgets/app_dialogs.dart';

/// Scan a module QR code; resolves to the encoded hardware MAC, or null.
Future<String?> scanMacQr(BuildContext context) async {
  final result = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => const BarcodeScannerSimple()),
  );
  return result?.trim().toUpperCase();
}

/// Turn a scanned [mac] into a connectable address: the MAC itself on Android,
/// the device's CoreBluetooth UUID (found by scan) on iOS. Shows a notice and
/// returns null when no advertising device carries that MAC.
Future<String?> resolveScannedAddress(BuildContext context, String mac) async {
  if (!useIosBleUuid) return mac;
  final uuid = await resolveIosDeviceUuid(mac);
  if (uuid == null && context.mounted) {
    await showInfoDialog(context,
        title: 'No device found',
        body: 'No device was found matching the MAC address you scanned');
  }
  return uuid;
}

class BarcodeScannerSimple extends StatefulWidget {
  const BarcodeScannerSimple({super.key});

  @override
  State<BarcodeScannerSimple> createState() => _BarcodeScannerSimpleState();
}

class _BarcodeScannerSimpleState extends State<BarcodeScannerSimple> {
  String? _lastValue;
  bool _popped = false;

  void _handleBarcode(BarcodeCapture capture) {
    final value = capture.barcodes.firstOrNull?.displayValue;
    if (!_popped && value != null && isMacFormat(value)) {
      _popped = true;
      Navigator.pop(context, value);
    }
    if (mounted) setState(() => _lastValue = value);
  }

  @override
  Widget build(BuildContext context) {
    final value = _lastValue;
    final caption = value == null
        ? ''
        : isMacFormat(value)
            ? value
            : 'Wrong MAC QR code format';
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: Colors.white),
        backgroundColor: AppColors.primary,
        title: const Text('Scan module QR code', style: TextStyle(color: Colors.white)),
      ),
      body: Stack(
        children: [
          MobileScanner(onDetect: _handleBarcode),
          Align(
            alignment: Alignment.bottomCenter,
            // SafeArea INSIDE the tinted box so the camera never shows through
            // below the caption.
            child: Container(
              color: Colors.black.withValues(alpha: 0.85),
              child: SafeArea(
                top: false,
                child: SizedBox(
                  height: 100,
                  child: Center(
                    child: Text(caption,
                        overflow: TextOverflow.fade, style: const TextStyle(color: Colors.white)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
