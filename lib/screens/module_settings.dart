import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';
import 'package:rcj_scoreboard/models/module.dart';
import 'package:rcj_scoreboard/services/ble.dart';
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';
import 'package:rcj_scoreboard/utils/colors.dart';

import 'mac_qr_scanner.dart';

class ModuleSettingsScreen extends StatefulWidget {

  const ModuleSettingsScreen({super.key});

  @override
  State<ModuleSettingsScreen> createState() => _ModuleSettingsScreen();
}

class _ModuleSettingsScreen extends State<ModuleSettingsScreen> {

  List<BluetoothDevice> devices = [];

  String deviceStatus = '';

  BLEServices ble = BLEServices();

  int? selectedIndex;

  final TextEditingController _controller = TextEditingController();
  final TextEditingController _labelController = TextEditingController();

  bool setMacFromModule = true;
  bool setLabelFromModule = true;

  bool bleIsScanning = false;


  @override
  void initState() {
    super.initState();

    // This will schedule a callback to be executed after the first frame is built.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _postInitLoad();
    });


    // ble.initCheck().then((result){
    //   // if (mounted) {
    //   //   setState(() {
    //   //     deviceStatus = result;
    //   //   });
    //   // }
    // });

    //startScanning();
  }

  void _postInitLoad() {
    ble.initCheck().then((result){
      if (mounted) {
        setState(() {
          deviceStatus = result;
        });
      }
    });

    // setState(() {
    //
    // });
  }


  void startScanning() async {
    setState(() {
      bleIsScanning = true;
    });
    await FlutterBluePlus.startScan(
      //withNames: ['RCJ-soccer_module'],
      //withServices: [Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E')],
      withKeywords: ['RCJ'],
      timeout: const Duration(seconds: 3),
    );
    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult result in results) {
        if (!devices.contains(result.device)) {
          if (mounted) {
            setState(() {
              devices.add(result.device);
            });
          }
        }
      }
    });

    // Wait for scanning to stop
    await FlutterBluePlus.isScanning.where((val) => val == false).first;

    // Your code to execute when scanning has finished
    if (mounted) {
      setState(() {
        bleIsScanning = false;
      });
    }

  }

  // @override
  // Widget build(BuildContext context) {
  //   return Scaffold(
  //     appBar: AppBar(
  //       title: Text('BLE Scanner'),
  //     ),
  //     body: ListView.builder(
  //       itemCount: devices.length,
  //       itemBuilder: (context, index) {
  //         return ListTile(
  //           title: Text(devices[index].platformName),
  //           subtitle: Text(devices[index].remoteId.toString()),
  //         );
  //       },
  //     ),
  //   );
  // }

  @override
  void dispose() {
    //SystemChannels.textInput.invokeMethod('TextInput.hide');
    _controller.dispose();
    _labelController.dispose();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  var maskFormatter = MaskTextInputFormatter(
    mask: (!kIsWeb && Platform.isIOS)
        ? '########-####-####-####-############'
        : '##:##:##:##:##:##',
    filter: (!kIsWeb && Platform.isIOS)
        ? {"#": RegExp('[0-9A-Fa-f-]')}
        : {"#": RegExp('[0-9A-Fa-f:]')},
  );

  @override
  Widget build(BuildContext context) {

    final module = Provider.of<Module>(context);

    if (setMacFromModule) {
      setMacFromModule = false;
      _controller.text = module.macAddress;
    }

    if (setLabelFromModule) {
      setLabelFromModule = false;
      _labelController.text = module.hasCustomLabel ? module.name : '';
    }


    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        iconTheme: const IconThemeData(
          color: Colors.white,
        ),
        backgroundColor: AppColors.primary,
        title: Text('Settings module ${module.name}',
            style: const TextStyle(color: Colors.white)),
      ),


        body: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            //SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Module status:',
                  style: TextStyle(fontSize: 18),
                ),
                Text(
                  deviceStatus == 'OK' ? module.bleStatus : deviceStatus,
                  style: const TextStyle(fontSize: 18),
                ),
              ],
            ),

            const SizedBox(height: 10),
            const Divider(),
            const SizedBox(height: 10),

            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _labelController,
                    decoration: InputDecoration(
                      labelText: 'Bot label (default: ${module.defaultName})',
                      labelStyle: const TextStyle(color: Colors.grey),
                      hintText: module.defaultName,
                      hintStyle: const TextStyle(color: Colors.grey),
                      helperText: 'First 2 characters shown on robot display',
                      helperStyle: const TextStyle(color: Colors.grey),
                      border: const OutlineInputBorder(),
                    ),
                    style: const TextStyle(color: Colors.white),
                    maxLength: 10,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[700],
                  ),
                  onPressed: () {
                    module.setLabel(_labelController.text);
                  },
                  child: const Text('Save', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),

            const SizedBox(height: 10),
            const Divider(),
            const SizedBox(height: 10),

            TextField(

              controller: _controller,
              inputFormatters: [maskFormatter],
              decoration: InputDecoration(
                labelText: (!kIsWeb && Platform.isIOS) ? 'Enter device UUID' : 'Enter MAC Address',
                labelStyle: const TextStyle(color: Colors.grey),
                hintText: (!kIsWeb && Platform.isIOS) ? 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' :'xx:xx:xx:xx:xx:xx',
                hintStyle: const TextStyle(color: Colors.grey),
                border: const OutlineInputBorder(),

              ),
              style: const TextStyle(color: Colors.white),
              maxLength: (!kIsWeb && Platform.isIOS) ? 36 : 17,
            ),
            const SizedBox(height: 5),
            Container(
              height: 50,
              margin: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 5.0),
              width: double.infinity,
              child: ElevatedButton(

                onPressed: () async {
                  if (module.isConnected) {
                    module.bleDisconnect();
                  } else {
                    module.setBleDevice(BluetoothDevice.fromId(_controller.text.toUpperCase()));
                    module.bleConnect();
                    FlutterBluePlus.stopScan();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey[700],
                ),
                child: Text(module.isConnected ? 'Disconnect' : 'Connect', style: const TextStyle(color: Colors.white, fontSize: 16, ),),
              ),
            ),

            const SizedBox(height: 20),
            Row(
              //mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  flex: 1,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[700],
                    ),
                    icon: const Icon(Icons.bluetooth, color: Colors.white),
                    label: Text(bleIsScanning ? 'Stop scanning' : 'Scan Bluetooth', style: const TextStyle(color: Colors.white),overflow: TextOverflow.fade,),
                    onPressed: () {
                      bleIsScanning ? FlutterBluePlus.stopScan() : startScanning();
                    },
                  ),
                ),
                const SizedBox(width: 4,),
                Expanded(
                  flex: 1,
                  child: buildQRButton(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Devices list:',
              style: TextStyle(fontSize: 16),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: devices.length,

                itemBuilder: (context, index) {
                  return ListTile(
                    tileColor: selectedIndex == index ? Colors.grey[700] : null,
                    title: Text(devices[index].platformName, style: const TextStyle(color: Colors.white)),
                    subtitle: Text(devices[index].remoteId.toString(), style: const TextStyle(color: Colors.white)),
                    onTap: () {
                      if (mounted) {
                        setState(() {
                        selectedIndex = index;
                        _controller.text = devices[index].remoteId.toString();
                        });
                      }
                    },
                  );
                },
              ),
            ),
          ],
        ),
        )
      );
    }


    Widget buildQRButton() {
      return ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.grey[700],
        ),
        icon: const Icon(Icons.qr_code_2, color: Colors.white),
        label: const Text('Scan QR code', style: TextStyle(color: Colors.white)),
        onPressed: () async {
          final result = await Navigator.push(context,
            MaterialPageRoute(builder: (context) => const BarcodeScannerSimple()),
          );
          if (!context.mounted) return;
          if (result != null) {
            //result = 'RCJ-soccer_module-XX:XX:XX:XX:XX:XX'
            // --> map result (ble device name) to uuid
            if(!kIsWeb && Platform.isIOS){
              handleIosResult(result);
            } else {
              _controller.text = result;
            }
          }
        },
      );
    }

    Future<void> handleIosResult(dynamic pResult) async {
      bool validResult = false;
      String? bleDeviceName = 'RCJs-m_$pResult';
      debugPrint(bleDeviceName);

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 3));

      await for (final results in FlutterBluePlus.scanResults.timeout(
        const Duration(seconds: 3),
        onTimeout: (sink) => sink.close(),
      )) {
        for (ScanResult r in results) {
          if (r.device.platformName == bleDeviceName) {
            //debugPrint('App-specific UUID: ${r.device.remoteId}');
            _controller.text = r.device.remoteId.toString();
            validResult = true;
            await FlutterBluePlus.stopScan();
            break;
          }
        }

        if (validResult) break;
      }

      await FlutterBluePlus.stopScan();

      //Error handling if no device to mac was found
      if (!validResult && mounted) {
        await showCupertinoDialog(
          context: context,
          builder: (BuildContext context) {
            return CupertinoAlertDialog(
              title: const Text('No device found'),
              content: const Text('No device was found matching the MAC address you scanned'),
              actions: [
                CupertinoDialogAction(
                  isDefaultAction: true,
                  onPressed: () {
                    Navigator.of(context).pop(); // 👈 closes the dialog
                  },
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      }
    }







  //     body: Padding(
  //       padding: const EdgeInsets.all(16.0),
  //       child: Column(
  //         children: [
  //           Column(
  //             children: [
  //               Row(
  //                 children: [
  //                   Text('Device status:'),
  //
  //                   Text(deviceStatus == 'OK' ? widget.module.bleStatus : deviceStatus),
  //                 ],
  //               ),
  //               //MacAddressInputField(),
  //               TextField(
  //                 controller: _controller,
  //                 inputFormatters: [maskFormatter],
  //                 decoration: InputDecoration(
  //                   labelText: 'Enter MAC Address',
  //                   hintText: 'xx:xx:xx:xx:xx:xx',
  //                   border: OutlineInputBorder(),
  //                 ),
  //                 maxLength: 17,
  //               ),
  //
  //               ElevatedButton(
  //                   onPressed: () {
  //                     debugPrint(_controller.text);
  //                     widget.module.setDevice(BluetoothDevice.fromId(_controller.text.toUpperCase()));
  //                   },
  //                   child: Text('Connect')
  //               ),
  //
  //
  //             ],
  //           )
  //
  //         ],
  //       ),
  //     ),
  //   );
  // }
 }



