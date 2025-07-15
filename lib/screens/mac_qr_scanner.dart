import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class BarcodeScannerSimple extends StatefulWidget {
  const BarcodeScannerSimple({super.key});

  @override
  State<BarcodeScannerSimple> createState() => _BarcodeScannerSimpleState();
}

class _BarcodeScannerSimpleState extends State<BarcodeScannerSimple> {
  Barcode? _barcode;
  bool pop_enable = true;  // to make sure pop is called only ones

  bool isValidMacAddress(String? macAddress) {
    if (macAddress == null) {
      return false;
    }

    // Check if the length is exactly 17 characters
    if (macAddress.length != 17) {
      return false;
    }

    // Define the regular expression pattern for a MAC address
    final RegExp macAddressRegExp = RegExp(
      r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$',
      caseSensitive: true,
    );

    // Check if the input string matches the MAC address pattern
    return macAddressRegExp.hasMatch(macAddress);
  }

  Widget _buildBarcode(Barcode? value) {
    if (value == null) {
      return const Text(
        '',
        overflow: TextOverflow.fade,
        style: TextStyle(color: Colors.white),
      );
    } else if (!isValidMacAddress(value.displayValue)) {
      return const Text(
        'Wrong MAC QR code format',
        overflow: TextOverflow.fade,
        style: TextStyle(color: Colors.white),
      );
    }

    return Text(
      value.displayValue ?? 'Read ERROR',
      overflow: TextOverflow.fade,
      style: const TextStyle(color: Colors.white),
    );
  }

  void _handleBarcode(BarcodeCapture barcodes) {

    if (pop_enable && isValidMacAddress(barcodes.barcodes.firstOrNull?.displayValue)) {
      pop_enable = false;
      Navigator.pop(context, barcodes.barcodes.firstOrNull?.displayValue);
    }

    if (mounted) {
      setState(() {
        _barcode = barcodes.barcodes.firstOrNull;
      });
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        iconTheme: const IconThemeData(
          color: Colors.white,
        ),
        backgroundColor: Colors.blue[900],
        title: Text('Scan module QR code', style: const TextStyle(color: Colors.white)),
      ),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: _handleBarcode,
            //scanWindow: Rect.fromCenter(center: Offset.zero, width: 500, height: 500),

          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              alignment: Alignment.bottomCenter,
              height: 100,
              color: Colors.black.withOpacity(0.85),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Expanded(child: Center(child: _buildBarcode(_barcode))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

