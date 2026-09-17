import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// One slot of a saved robot configuration. [hardwareMac] is the permanent
/// MAC ('' when unknown); on iOS [macAddress] is a per-phone UUID.
class ModuleConfig {
  const ModuleConfig({
    required this.moduleId,
    required this.macAddress,
    this.hardwareMac = '',
    required this.label,
  });

  final int moduleId;
  final String macAddress;
  final String hardwareMac;
  final String label;

  Map<String, dynamic> toJson() => {
        'moduleId': moduleId,
        'macAddress': macAddress,
        'hardwareMac': hardwareMac,
        'label': label,
      };

  factory ModuleConfig.fromJson(Map<String, dynamic> json) => ModuleConfig(
        moduleId: json['moduleId'] as int,
        macAddress: json['macAddress'] as String? ?? '',
        hardwareMac: json['hardwareMac'] as String? ?? '',
        label: json['label'] as String? ?? '',
      );
}

/// A named set of module pairings for the whole field.
class GamePreset {
  GamePreset({required this.id, required this.name, required this.modules});

  factory GamePreset.create(String name, List<ModuleConfig> modules) =>
      GamePreset(id: const Uuid().v4(), name: name, modules: modules);

  final String id;
  String name;
  final List<ModuleConfig> modules;

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

/// A single bookmarked robot module.
class SavedDevice {
  SavedDevice({
    required this.id,
    required this.name,
    required this.macAddress,
    this.hardwareMac = '',
    required this.label,
  });

  factory SavedDevice.create({
    required String name,
    required String macAddress,
    String hardwareMac = '',
    required String label,
  }) =>
      SavedDevice(
        id: const Uuid().v4(),
        name: name,
        macAddress: macAddress,
        hardwareMac: hardwareMac,
        label: label,
      );

  final String id;
  String name;
  final String macAddress;
  final String hardwareMac;
  final String label;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'macAddress': macAddress,
        'hardwareMac': hardwareMac,
        'label': label,
      };

  factory SavedDevice.fromJson(Map<String, dynamic> json) => SavedDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        macAddress: json['macAddress'] as String? ?? '',
        hardwareMac: json['hardwareMac'] as String? ?? '',
        label: json['label'] as String? ?? '',
      );
}

/// Presets and saved devices, each a JSON list under one prefs key.
class PresetService {
  static final _presets = _JsonListStore<GamePreset>(
      'module_presets', GamePreset.fromJson, (p) => p.toJson(), (p) => p.id);
  static final _devices = _JsonListStore<SavedDevice>(
      'saved_devices', SavedDevice.fromJson, (d) => d.toJson(), (d) => d.id);

  Future<List<GamePreset>> loadAll() => _presets.load();
  Future<void> save(GamePreset preset) => _presets.upsert(preset);
  Future<void> delete(String id) => _presets.delete(id);

  Future<List<SavedDevice>> loadAllDevices() => _devices.load();
  Future<void> saveDevice(SavedDevice device) => _devices.upsert(device);
  Future<void> deleteDevice(String id) => _devices.delete(id);
}

class _JsonListStore<T> {
  _JsonListStore(this._key, this._fromJson, this._toJson, this._idOf);

  final String _key;
  final T Function(Map<String, dynamic>) _fromJson;
  final Map<String, dynamic> Function(T) _toJson;
  final String Function(T) _idOf;

  Future<List<T>> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => _fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Error loading $_key: $e');
      return [];
    }
  }

  Future<void> upsert(T item) async {
    final items = await load();
    final index = items.indexWhere((i) => _idOf(i) == _idOf(item));
    index >= 0 ? items[index] = item : items.add(item);
    await _persist(items);
  }

  Future<void> delete(String id) async {
    final items = await load();
    items.removeWhere((i) => _idOf(i) == id);
    await _persist(items);
  }

  Future<void> _persist(List<T> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(items.map(_toJson).toList()));
  }
}
