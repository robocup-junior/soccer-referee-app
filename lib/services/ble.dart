import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';






class BLEServices {

  BLEServices();

  Future<String> initCheck() async {
    String status = 'A';
    // first, check if bluetooth is supported by your hardware
    // Note: The platform is initialized on the first call to any FlutterBluePlus method.
    if (await FlutterBluePlus.isSupported == false) {
      status = 'Bluetooth not supported';
      return status;
    }

    // handle bluetooth on & off
    // note: for iOS the initial state is typically BluetoothAdapterState.unknown
    // note: if you have permissions issues you will get stuck at BluetoothAdapterState.unauthorized
    BluetoothAdapterState state = await FlutterBluePlus.adapterState.first;
    debugPrint('test');
    debugPrint(state as String?);
    if (state == BluetoothAdapterState.on) {
      // usually start scanning, connecting, etc
      status = 'OK';
    } else if (state == BluetoothAdapterState.unavailable) {
      status = 'No connection';
    } else {
      // show an error to the user, etc
      debugPrint('off');
      status = 'Bluetooth is disabled';
    }
    // var subscription = FlutterBluePlus.adapterState.listen((BluetoothAdapterState state) {
    //   debugPrint('TEST');
    //   debugPrint(state);
    //   if (state == BluetoothAdapterState.on) {
    //     // usually start scanning, connecting, etc
    //     debugPrint('ok');
    //     status = 'OK';
    //   } else {
    //     // show an error to the user, etc
    //     debugPrint('off');
    //     status = 'BlueTooth is disabled';
    //   }
    // });

    if (status == 'Bluetooth is disabled') {
      if (await enableBLE() == false) {
        status = 'Bluetooth is disabled';
      } else {
        status = 'OK';
      }
    }

    // cancel to prevent duplicate listeners
    //subscription.cancel();

    return status;
  }

  Future<bool> enableBLE() async {
    // turn on bluetooth ourself if we can
    // for iOS, the user controls bluetooth enable/disable
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
        return true;
      } catch (e) {
        debugPrint('Enable BLE error');
        return false;
      }
    }
    return false;
  }


}






