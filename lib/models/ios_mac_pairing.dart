import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/models/module.dart';
import 'package:rcj_scoreboard/services/ios_mac_resolver.dart';
import 'package:rcj_scoreboard/utils/ble_address.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// iOS MAC→UUID pairing (#82).
///
/// iOS cannot connect by hardware MAC, so a module is paired through a cached
/// CoreBluetooth UUID or, failing that, one batch scan at match load owned by
/// [IosMacResolveController]. The cache persists across matches; a stale entry
/// is dropped when its connect fails and the module re-enrolls. Every method
/// is a no-op on Android except the cache bookkeeping, which is platform-free.
class IosMacPairing {
  IosMacPairing({
    required Module? Function(int moduleId) moduleById,
    required bool Function() canScanNow,
  }) : _moduleById = moduleById {
    resolver = IosMacResolveController(
      canScanNow: canScanNow,
      onResolved: _onResolved,
      onGaveUp: (id) => _moduleById(id)?.markSearchGaveUp(),
    );
  }

  static const _cacheKey = 'ios_mac_uuid_cache';

  final Module? Function(int moduleId) _moduleById;
  late final IosMacResolveController resolver;
  final Map<String, String> _cache = {};
  SharedPreferences? _prefs;
  bool _cacheDirty = false;

  /// Merge the persisted cache under entries resolved before prefs loaded.
  void loadCache(SharedPreferences prefs) {
    _prefs = prefs;
    final raw = prefs.getString(_cacheKey);
    if (raw != null) {
      try {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((mac, uuid) {
          if (uuid is String && uuid.isNotEmpty) {
            _cache.putIfAbsent(mac.toUpperCase(), () => uuid);
          }
        });
      } catch (e) {
        debugPrint('ios_mac_uuid_cache unreadable, ignoring: $e');
      }
    }
    if (_cacheDirty) _persistCache();
  }

  void _persistCache() {
    final prefs = _prefs;
    if (prefs == null) {
      _cacheDirty = true;
      return;
    }
    _cacheDirty = false;
    prefs.setString(_cacheKey, jsonEncode(_cache));
  }

  void _cachePut(String mac, String uuid) {
    if (_cache[mac] == uuid) return;
    _cache[mac] = uuid;
    _persistCache();
  }

  /// Seed the cache from a stored pairing (preset). Last writer wins; a stale
  /// seed self-heals via the connect-failure fallback.
  void seed(String mac, String uuid) {
    if (mac.isEmpty || uuid.isEmpty) return;
    _cachePut(mac.toUpperCase(), uuid);
  }

  /// Warm the cache from a live connection. Called by Module's connected event.
  void record(String mac, String uuid) {
    if (!useIosBleUuid) return;
    seed(mac, uuid);
  }

  /// Pair [module] to hardware [mac]: cached UUID first, else enroll it with
  /// the batch-scan resolver ("Searching..."). [label] follows
  /// applyPresetConfig's always-apply rule.
  void pairByMac(Module module, String mac, {required String label}) {
    final macUpper = mac.toUpperCase();
    if (module.isConnected && module.hardwareMac == macUpper) {
      module.applyPresetConfig('', label, hardwareMac: macUpper);
      resolver.cancel(module.moduleId);
      _cachePut(macUpper, module.macAddress);
      return;
    }
    final cached = _cache[macUpper];
    if (cached != null && cached.isNotEmpty) {
      resolver.cancel(module.moduleId);
      module.applyPresetConfig(cached, label, hardwareMac: macUpper);
    } else {
      module.applyPresetConfig('', label, hardwareMac: macUpper);
      module.markSearching();
      resolver.enroll(module.moduleId, macUpper);
    }
  }

  /// A connect() failed because its identity can never connect: drop the dead
  /// cache entry and hand the module to the resolver. Called once per failed
  /// connect CALL, never from disconnect events (invariant #5).
  void enroll(Module module) {
    if (!useIosBleUuid || module.hardwareMac.isEmpty) return;
    if (_cache.remove(module.hardwareMac) != null) _persistCache();
    module.markSearching();
    resolver.enroll(module.moduleId, module.hardwareMac);
  }

  /// Forget a pending search (Cancel / retarget) so a late hit can't revive it.
  void cancel(Module module) => resolver.cancel(module.moduleId);

  void _onResolved(int moduleId, String mac, String uuid) {
    final module = _moduleById(moduleId);
    // The slot may have been re-pointed while the scan ran.
    if (module == null || module.hardwareMac != mac) return;
    _cachePut(mac, uuid);
    // A live/in-flight link is left alone. An idle module always gets a fresh
    // connect, even for an unchanged UUID: that is the stale-cache recovery
    // case (the module just re-advertised, so it is connectable again).
    if (module.isConnected || module.isConnecting) return;
    module.setBleDevice(BluetoothDevice.fromId(uuid), hardwareMac: mac);
    if (module.isEnabled) module.bleConnect();
  }

  @visibleForTesting
  void debugOnResolved(int moduleId, String mac, String uuid) =>
      _onResolved(moduleId, mac, uuid);

  void dispose() => resolver.dispose();
}
