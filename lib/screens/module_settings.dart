import 'package:flutter/cupertino.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';
import 'package:rcj_scoreboard/models/module.dart';
import 'package:rcj_scoreboard/services/ble.dart';
import 'package:rcj_scoreboard/utils/ble_address.dart';
import 'package:rcj_scoreboard/utils/colors.dart';

import 'mac_qr_scanner.dart';
import 'package:rcj_scoreboard/services/preset_service.dart';

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
  StreamSubscription<List<ScanResult>>? _scanSubscription;

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


  Future<void> _saveCurrentDevice() async {
    final mac = _controller.text.trim();
    if (mac.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a device address first')),
      );
      return;
    }

    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Device'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Device name',
            hintText: 'e.g. Red robot #3',
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (name == null || name.trim().isEmpty) return;

    final device = SavedDevice.create(
      name: name.trim(),
      macAddress: mac,
      label: _labelController.text.trim(),
    );
    await PresetService().saveDevice(device);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${device.name}" saved')),
      );
    }
  }

  Future<void> _loadSavedDevice() async {
    final devices = await PresetService().loadAllDevices();
    if (!mounted) return;

    if (devices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No saved devices yet')),
      );
      return;
    }

    final selected = await showDialog<SavedDevice>(
      context: context,
      builder: (context) => _SavedDevicesDialog(devices: devices),
    );

    if (selected == null || !mounted) return;

    final module = Provider.of<Module>(context, listen: false);
    setState(() {
      _controller.text = selected.macAddress;
      _labelController.text = selected.label;
    });
    // Single apply path shared with presets: sets the label (empty -> default)
    // and connects only when the module is enabled.
    module.applyPresetConfig(selected.macAddress, selected.label);
    FlutterBluePlus.stopScan();
  }

  void startScanning() async {
    setState(() {
      bleIsScanning = true;
    });
    // Cancel any previous subscription before creating a new one.
    await _scanSubscription?.cancel();
    _scanSubscription = null;

    // Subscribe BEFORE startScan so no results are missed between the scan
    // starting and .listen() being attached (race in the old ordering). Use
    // onScanResults, not scanResults: scanResults is a behavior stream that
    // replays the previous scan's cached results to a new listener, so
    // subscribing before startScan would surface stale/unfiltered devices from
    // an earlier scan; onScanResults clears between scans.
    _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
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

    try {
      await FlutterBluePlus.startScan(
        withKeywords: ['RCJ', 'soccer', 'module'],
        timeout: const Duration(seconds: 3),
      );
      // Wait for scanning to stop
      await FlutterBluePlus.isScanning.where((val) => val == false).first;
    } finally {
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      if (mounted) {
        setState(() {
          bleIsScanning = false;
        });
      }
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
    _scanSubscription?.cancel();
    _scanSubscription = null;
    _controller.dispose();
    _labelController.dispose();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  // Shared with the bridge address field via utils/ble_address.dart so both
  // screens use the same UUID-vs-MAC mask.
  final maskFormatter = buildBleAddressMask();

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
      // The body has an Expanded devices list, so it can't go in a scroll view.
      // Don't shrink the viewport for the keyboard (which overflowed the fixed
      // rows by a few px); the bot-label field is near the top and stays visible
      // while the keyboard overlays the lower (scrollable) part.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        iconTheme: const IconThemeData(
          color: Colors.white,
        ),
        backgroundColor: AppColors.primary,
        title: Text('Settings module ${module.name}',
            style: const TextStyle(color: Colors.white)),
      ),

      body: SafeArea(
        top: false,
        child: Padding(
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
                // Flexible + ellipsis so a long status string can never overflow
                // the Row and bork the screen (BLE errors can be verbose).
                Flexible(
                  child: Text(
                    deviceStatus == 'OK' ? module.bleStatus : deviceStatus,
                    style: const TextStyle(fontSize: 18),
                    textAlign: TextAlign.right,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
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
                labelText: useIosBleUuid ? 'Enter device UUID' : 'Enter MAC Address',
                labelStyle: const TextStyle(color: Colors.grey),
                hintText: bleAddressHint,
                hintStyle: const TextStyle(color: Colors.grey),
                border: const OutlineInputBorder(),

              ),
              style: const TextStyle(color: Colors.white),
              maxLength: bleAddressMaxLength,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[700],
                    ),
                    icon: const Icon(Icons.bookmark_add_outlined, color: Colors.white),
                    label: const Text('Save device', style: TextStyle(color: Colors.white)),
                    onPressed: _saveCurrentDevice,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[700],
                    ),
                    icon: const Icon(Icons.bookmark_outlined, color: Colors.white),
                    label: const Text('Load device', style: TextStyle(color: Colors.white)),
                    onPressed: _loadSavedDevice,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Container(
              height: 50,
              margin: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 5.0),
              width: double.infinity,
              child: ElevatedButton(

                onPressed: () async {
                  // Connected OR mid-connect → the button cancels/disconnects,
                  // so a stuck "Connecting..." (dead module) can always be broken.
                  if (module.isConnected || module.isConnecting) {
                    module.bleDisconnect();
                  } else {
                    final mac = _controller.text.trim();
                    if (mac.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Enter a device address first')),
                      );
                      return;
                    }
                    module.setBleDevice(BluetoothDevice.fromId(mac.toUpperCase()));
                    module.bleConnect();
                    FlutterBluePlus.stopScan();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey[700],
                ),
                child: Text(module.isConnected ? 'Disconnect' : module.isConnecting ? 'Cancel' : 'Connect', style: const TextStyle(color: Colors.white, fontSize: 16, ),),
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
        ),
      ),
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
            if (useIosBleUuid) {
              handleIosResult(result);
            } else {
              _controller.text = result;
            }
          }
        },
      );
    }

    // QR codes encode a MAC, but iOS connects by CoreBluetooth UUID — resolve it
    // via the shared BLE scan (utils/ble_address.dart), which uses the validated
    // onScanResults lifecycle (NOT the replay-prone scanResults this used to call)
    // and tears the scan down in finally.
    Future<void> handleIosResult(dynamic pResult) async {
      final resolvedUuid = await resolveIosDeviceUuid('$pResult');

      if (resolvedUuid != null) {
        if (mounted) {
          _controller.text = resolvedUuid;
        }
        return;
      }

      //Error handling if no device to mac was found
      if (mounted) {
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

class _SavedDevicesDialog extends StatefulWidget {
  final List<SavedDevice> devices;

  const _SavedDevicesDialog({required this.devices});

  @override
  State<_SavedDevicesDialog> createState() => _SavedDevicesDialogState();
}

class _SavedDevicesDialogState extends State<_SavedDevicesDialog> {
  late List<SavedDevice> _devices;

  @override
  void initState() {
    super.initState();
    _devices = List.from(widget.devices);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Load Saved Device'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _devices.length,
          itemBuilder: (context, index) {
            final device = _devices[index];
            return ListTile(
              title: Text(device.name),
              subtitle: Text(
                device.macAddress,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                onPressed: () async {
                  await PresetService().deleteDevice(device.id);
                  setState(() => _devices.removeAt(index));
                  if (_devices.isEmpty && context.mounted) {
                    Navigator.pop(context, null);
                  }
                },
              ),
              onTap: () => Navigator.pop(context, device),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}



