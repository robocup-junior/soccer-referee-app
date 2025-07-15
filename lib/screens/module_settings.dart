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
  _ModuleSettingsScreen createState() => _ModuleSettingsScreen();
}

class _ModuleSettingsScreen extends State<ModuleSettingsScreen> {

  List<BluetoothDevice> devices = [];

  String deviceStatus = '';

  BLEServices ble = BLEServices();

  int? selectedIndex;

  final TextEditingController _controller = TextEditingController();

  bool setMacFromModule = true;

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
      withKeywords: ['RCJ', 'soccer', 'module'],
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
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  var maskFormatter =  MaskTextInputFormatter(
    mask: '##:##:##:##:##:##',
    filter: {"#" : RegExp('[0-9A-Fa-f:]')},
    //type: MaskAutoCompletionType.lazy,
  );







  @override
  Widget build(BuildContext context) {

    final module = Provider.of<Module>(context);

    if (setMacFromModule) {
      setMacFromModule = false;
      _controller.text = module.macAddress;
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
                Text(
                  'Module status:',
                  style: TextStyle(fontSize: 18),
                ),
                Text(
                  deviceStatus == 'OK' ? module.bleStatus : deviceStatus,
                  style: TextStyle(fontSize: 18),
                ),
              ],
            ),

            SizedBox(height: 10),
            Divider(),
            SizedBox(height: 10),

            TextField(

              controller: _controller,
              inputFormatters: [maskFormatter],
              decoration: InputDecoration(
                labelText: 'Enter MAC Address',
                labelStyle: TextStyle(color: Colors.grey),
                hintText: 'xx:xx:xx:xx:xx:xx',
                hintStyle: TextStyle(color: Colors.grey),
                border: OutlineInputBorder(),

              ),
              style: TextStyle(color: Colors.white),
              maxLength: 17,
            ),
            SizedBox(height: 5),
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
                child: Text(module.isConnected ? 'Disconnect' : 'Connect', style: TextStyle(color: Colors.white, fontSize: 16, ),),
              ),
            ),

            SizedBox(height: 20),
            Row(
              //mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  flex: 1,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[700],
                    ),
                    icon: Icon(Icons.bluetooth, color: Colors.white),
                    label: Text(bleIsScanning ? 'Stop scanning' : 'Scan Bluetooth', style: TextStyle(color: Colors.white),overflow: TextOverflow.fade,),
                    onPressed: () {
                      bleIsScanning ? FlutterBluePlus.stopScan() : startScanning();
                    },
                  ),
                ),
                SizedBox(width: 4,),
                Expanded(
                  flex: 1,
                  child: buildQRButton(),
                ),
              ],
            ),
            SizedBox(height: 16),
            Text(
              'Devices list:',
              style: TextStyle(fontSize: 16),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: devices.length,

                itemBuilder: (context, index) {
                  return Container(
                    child: ListTile(
                      tileColor: selectedIndex == index ? Colors.grey[700] : null,
                      title: Text(devices[index].platformName, style: TextStyle(color: Colors.white)),
                      subtitle: Text(devices[index].remoteId.toString(), style: TextStyle(color: Colors.white)),
                      onTap: () {
                        if (mounted) {
                          setState(() {
                          selectedIndex = index;
                          _controller.text = devices[index].remoteId.toString();
                          });
                        }
                      },
                    ),
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
        icon: Icon(Icons.qr_code_2, color: Colors.white),
        label: Text('Scan QR code', style: TextStyle(color: Colors.white)),
        onPressed: () async {
          final result = await Navigator.push(context,
            MaterialPageRoute(builder: (context) => BarcodeScannerSimple()),
          );
          if (!context.mounted) return;
          if (result != null) {
            _controller.text = result;
          }
        },
      );
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
  //                     print(_controller.text);
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



