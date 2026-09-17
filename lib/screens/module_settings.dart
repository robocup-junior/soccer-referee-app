import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';
import 'package:rcj_scoreboard/models/module.dart';
import 'package:rcj_scoreboard/screens/mac_qr_scanner.dart';
import 'package:rcj_scoreboard/services/ble_adapter_monitor.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';
import 'package:rcj_scoreboard/services/preset_service.dart';
import 'package:rcj_scoreboard/utils/ble_address.dart';
import 'package:rcj_scoreboard/utils/colors.dart';
import 'package:rcj_scoreboard/widgets/app_dialogs.dart';

/// Per-robot BLE pairing: label, address (typed, scanned, from QR or from a
/// saved device) and connect/disconnect. Expects a [Module] and a
/// [BleAdapterMonitor] from Provider.
class ModuleSettingsScreen extends StatefulWidget {
  const ModuleSettingsScreen({super.key});

  @override
  State<ModuleSettingsScreen> createState() => _ModuleSettingsScreenState();
}

class _ModuleSettingsScreenState extends State<ModuleSettingsScreen> {
  final _addressController = TextEditingController();
  final _labelController = TextEditingController();
  final List<BluetoothDevice> _devices = [];
  int? _selectedIndex;
  bool _seeded = false;
  bool _scanning = false;
  StreamSubscription<List<ScanResult>>? _scanSub;
  // The last QR resolve's (UUID, MAC): the MAC is committed to the module only
  // when the user connects that exact UUID.
  String? _qrResolvedUuid;
  String? _qrScannedMac;

  static const _white = TextStyle(color: Colors.white);
  static const _grey = TextStyle(color: Colors.grey);

  @override
  void dispose() {
    _scanSub?.cancel();
    _addressController.dispose();
    _labelController.dispose();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _connectOrDisconnect(Module module) async {
    if (module.isConnected || module.isConnecting || module.isSearching) {
      module.bleDisconnect();
      return;
    }
    final address = _addressController.text.trim();
    if (address.isEmpty) {
      _snack('Enter a device address first');
      return;
    }
    // iOS: a MAC is resolved to the device's UUID by scan first. Manual scans
    // stay available mid-half by design; only automatic ones are gated.
    if (useIosBleUuid && isMacFormat(address)) {
      final uuid = await resolveIosDeviceUuid(address);
      if (!mounted) return;
      if (uuid == null) {
        _snack('No device found for that MAC — is the module on?');
        return;
      }
      _addressController.text = uuid;
      module.setBleDevice(BluetoothDevice.fromId(uuid), hardwareMac: address);
      module.bleConnect();
      return;
    }
    final fromQr = _qrResolvedUuid != null &&
        address.toUpperCase() == _qrResolvedUuid!.toUpperCase();
    module.setBleDevice(BluetoothDevice.fromId(address.toUpperCase()),
        hardwareMac: fromQr ? _qrScannedMac : null);
    module.bleConnect();
    FlutterBluePlus.stopScan();
  }

  Future<void> _scanQr() async {
    final mac = await scanMacQr(context);
    if (mac == null || !mounted) return;
    final address = await resolveScannedAddress(context, mac);
    if (address == null || !mounted) return;
    setState(() {
      _addressController.text = address;
      if (useIosBleUuid) {
        _qrResolvedUuid = address;
        _qrScannedMac = mac;
      }
    });
  }

  Future<void> _toggleScan() async {
    if (_scanning) {
      FlutterBluePlus.stopScan();
      return;
    }
    setState(() => _scanning = true);
    await _scanSub?.cancel();
    // Subscribe BEFORE startScan; onScanResults (not the replaying
    // scanResults) so a previous scan's cached devices never surface.
    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      final fresh = results.map((r) => r.device).where((d) => !_devices.contains(d));
      if (fresh.isNotEmpty && mounted) setState(() => _devices.addAll(fresh));
    });
    try {
      await FlutterBluePlus.startScan(
          withKeywords: ['RCJ', 'soccer', 'module'], timeout: const Duration(seconds: 3));
      await FlutterBluePlus.isScanning.where((s) => !s).first;
    } finally {
      await _scanSub?.cancel();
      _scanSub = null;
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _saveDevice(Module module) async {
    final address = _addressController.text.trim();
    if (address.isEmpty) {
      _snack('Enter a device address first');
      return;
    }
    final name = await showTextInputDialog(context,
        title: 'Save Device', label: 'Device name', hint: 'e.g. Red robot #3');
    if (name == null || name.trim().isEmpty || !mounted) return;
    final device = SavedDevice.create(
      name: name.trim(),
      macAddress: address,
      // Only when the MAC provably belongs to the typed address.
      hardwareMac: isMacFormat(address)
          ? address
          : (address.toUpperCase() == module.macAddress.toUpperCase() ? module.hardwareMac : ''),
      label: _labelController.text.trim(),
    );
    await PresetService().saveDevice(device);
    if (mounted) _snack('"${device.name}" saved');
  }

  Future<void> _loadDevice(Module module) async {
    final devices = await PresetService().loadAllDevices();
    if (!mounted) return;
    if (devices.isEmpty) {
      _snack('No saved devices yet');
      return;
    }
    final selected = await showDialog<SavedDevice>(
        context: context, builder: (_) => _SavedDevicesDialog(devices: devices));
    if (selected == null || !mounted) return;
    setState(() {
      _addressController.text = selected.macAddress;
      _labelController.text = selected.label;
    });
    module.applyPresetConfig(selected.macAddress, selected.label,
        hardwareMac: selected.hardwareMac);
    FlutterBluePlus.stopScan();
  }

  @override
  Widget build(BuildContext context) {
    final module = context.watch<Module>();
    final adapter = context.watch<BleAdapterMonitor>().state;
    if (!_seeded) {
      _seeded = true;
      // Fall back to the hardware MAC for an iOS slot whose UUID was never
      // resolved, so Connect can resolve + connect it in one tap.
      _addressController.text =
          module.macAddress.isNotEmpty ? module.macAddress : module.hardwareMac;
      _labelController.text = module.hasCustomLabel ? module.name : '';
    }
    final status =
        isAdapterProblem(adapter) ? describeAdapterState(adapter).message : module.bleStatus;
    final connectLabel = module.isConnected
        ? 'Disconnect'
        : (module.isConnecting || module.isSearching)
            ? 'Cancel'
            : 'Connect';

    return Scaffold(
      backgroundColor: Colors.black,
      // The keyboard overlays the (scrollable) list instead of squeezing the
      // fixed rows.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: Colors.white),
        backgroundColor: AppColors.primary,
        title: Text('Settings module ${module.name}', style: _white),
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Module status:', style: TextStyle(fontSize: 18)),
                  Flexible(
                    child: Text(status,
                        style: const TextStyle(fontSize: 18),
                        textAlign: TextAlign.right,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              const Divider(height: 30),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _labelController,
                      decoration: InputDecoration(
                        labelText: 'Bot label (default: ${module.defaultName})',
                        labelStyle: _grey,
                        hintText: module.defaultName,
                        hintStyle: _grey,
                        helperText: 'First 2 characters shown on robot display',
                        helperStyle: _grey,
                        border: const OutlineInputBorder(),
                      ),
                      style: _white,
                      maxLength: 10,
                    ),
                  ),
                  const SizedBox(width: 8),
                  AppButton(label: 'Save', onPressed: () => module.setLabel(_labelController.text)),
                ],
              ),
              const Divider(height: 30),
              TextField(
                controller: _addressController,
                inputFormatters: buildModuleAddressFormatters(),
                decoration: InputDecoration(
                  labelText: moduleAddressLabel,
                  labelStyle: _grey,
                  hintText: moduleAddressHint,
                  hintStyle: _grey,
                  border: const OutlineInputBorder(),
                ),
                style: _white,
                maxLength: bleAddressMaxLength,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                        label: 'Save device',
                        icon: Icons.bookmark_add_outlined,
                        onPressed: () => _saveDevice(module)),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: AppButton(
                        label: 'Load device',
                        icon: Icons.bookmark_outlined,
                        onPressed: () => _loadDevice(module)),
                  ),
                ],
              ),
              Container(
                height: 50,
                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _connectOrDisconnect(module),
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.button),
                  child: Text(connectLabel, style: const TextStyle(color: Colors.white, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                        label: _scanning ? 'Stop scanning' : 'Scan Bluetooth',
                        icon: Icons.bluetooth,
                        onPressed: _toggleScan),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: AppButton(label: 'Scan QR code', icon: Icons.qr_code_2, onPressed: _scanQr),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Devices list:', style: TextStyle(fontSize: 16)),
              Expanded(
                child: ListView.builder(
                  itemCount: _devices.length,
                  itemBuilder: (_, index) => ListTile(
                    tileColor: _selectedIndex == index ? AppColors.button : null,
                    title: Text(_devices[index].platformName, style: _white),
                    subtitle: Text(_devices[index].remoteId.toString(), style: _white),
                    onTap: () => setState(() {
                      _selectedIndex = index;
                      _addressController.text = _devices[index].remoteId.toString();
                    }),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SavedDevicesDialog extends StatefulWidget {
  const _SavedDevicesDialog({required this.devices});
  final List<SavedDevice> devices;

  @override
  State<_SavedDevicesDialog> createState() => _SavedDevicesDialogState();
}

class _SavedDevicesDialogState extends State<_SavedDevicesDialog> {
  late final List<SavedDevice> _devices = List.of(widget.devices);

  @override
  Widget build(BuildContext context) => AlertDialog(
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
                subtitle: Text(device.macAddress,
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () async {
                    await PresetService().deleteDevice(device.id);
                    setState(() => _devices.removeAt(index));
                    if (_devices.isEmpty && context.mounted) Navigator.pop(context);
                  },
                ),
                onTap: () => Navigator.pop(context, device),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ],
      );
}
