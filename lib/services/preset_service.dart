import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class ModuleConfig {
  final int moduleId;
  final String macAddress;
  final String label;

  const ModuleConfig({
    required this.moduleId,
    required this.macAddress,
    required this.label,
  });

  Map<String, dynamic> toJson() => {
        'moduleId': moduleId,
        'macAddress': macAddress,
        'label': label,
      };

  factory ModuleConfig.fromJson(Map<String, dynamic> json) => ModuleConfig(
        moduleId: json['moduleId'] as int,
        macAddress: json['macAddress'] as String? ?? '',
        label: json['label'] as String? ?? '',
      );
}

class GamePreset {
  final String id;
  String name;
  final List<ModuleConfig> modules;

  GamePreset({
    required this.id,
    required this.name,
    required this.modules,
  });

  factory GamePreset.create(String name, List<ModuleConfig> modules) =>
      GamePreset(
        id: const Uuid().v4(),
        name: name,
        modules: modules,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'modules': modules.map((m) => m.toJson()).toList(),
      };

  factory GamePreset.fromJson(Map<String, dynamic> json) => GamePreset(
        id: json['id'] as String,
        name: json['name'] as String,
        modules: (json['modules'] as List<dynamic>)
            .map((m) => ModuleConfig.fromJson(m as Map<String, dynamic>))
            .toList(),
      );
}

class SavedDevice {
  final String id;
  String name;
  final String macAddress;
  final String label;

  SavedDevice({
    required this.id,
    required this.name,
    required this.macAddress,
    required this.label,
  });

  factory SavedDevice.create({
    required String name,
    required String macAddress,
    required String label,
  }) =>
      SavedDevice(
        id: const Uuid().v4(),
        name: name,
        macAddress: macAddress,
        label: label,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'macAddress': macAddress,
        'label': label,
      };

  factory SavedDevice.fromJson(Map<String, dynamic> json) => SavedDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        macAddress: json['macAddress'] as String? ?? '',
        label: json['label'] as String? ?? '',
      );
}

class PresetService {
  static const _prefsKey = 'module_presets';
  static const _devicesKey = 'saved_devices';

  Future<List<GamePreset>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => GamePreset.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Error loading presets: $e');
      return [];
    }
  }

  Future<void> save(GamePreset preset) async {
    final presets = await loadAll();
    final index = presets.indexWhere((p) => p.id == preset.id);
    if (index >= 0) {
      presets[index] = preset;
    } else {
      presets.add(preset);
    }
    await _persist(presets);
  }

  Future<void> delete(String id) async {
    final presets = await loadAll();
    presets.removeWhere((p) => p.id == id);
    await _persist(presets);
  }

  Future<void> _persist(List<GamePreset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(presets.map((p) => p.toJson()).toList()),
    );
  }

  Future<List<SavedDevice>> loadAllDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_devicesKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => SavedDevice.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Error loading saved devices: $e');
      return [];
    }
  }

  Future<void> saveDevice(SavedDevice device) async {
    final devices = await loadAllDevices();
    final index = devices.indexWhere((d) => d.id == device.id);
    if (index >= 0) {
      devices[index] = device;
    } else {
      devices.add(device);
    }
    await _persistDevices(devices);
  }

  Future<void> deleteDevice(String id) async {
    final devices = await loadAllDevices();
    devices.removeWhere((d) => d.id == id);
    await _persistDevices(devices);
  }

  Future<void> _persistDevices(List<SavedDevice> devices) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _devicesKey,
      jsonEncode(devices.map((d) => d.toJson()).toList()),
    );
  }
}
