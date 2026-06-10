import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/services/preset_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // SharedPreferences.setMockInitialValues needs the platform channel binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ModuleConfig JSON', () {
    test('round-trips all fields', () {
      const cfg = ModuleConfig(moduleId: 3, macAddress: 'AA:BB', label: 'X1');
      final back = ModuleConfig.fromJson(cfg.toJson());
      expect(back.moduleId, 3);
      expect(back.macAddress, 'AA:BB');
      expect(back.label, 'X1');
    });

    test('missing macAddress/label fall back to empty strings', () {
      final back = ModuleConfig.fromJson({'moduleId': 0});
      expect(back.moduleId, 0);
      expect(back.macAddress, '');
      expect(back.label, '');
    });
  });

  group('GamePreset JSON', () {
    test('round-trips id, name and nested modules', () {
      final preset = GamePreset(
        id: 'p1',
        name: 'Finals',
        modules: const [
          ModuleConfig(moduleId: 0, macAddress: 'AA', label: ''),
          ModuleConfig(moduleId: 5, macAddress: 'BB', label: 'B1'),
        ],
      );
      final back = GamePreset.fromJson(preset.toJson());
      expect(back.id, 'p1');
      expect(back.name, 'Finals');
      expect(back.modules.length, 2);
      expect(back.modules[1].moduleId, 5);
      expect(back.modules[1].label, 'B1');
      expect(back.modules[0].label, '');
    });

    test('create() assigns a non-empty uuid', () {
      final preset = GamePreset.create('P', const []);
      expect(preset.id, isNotEmpty);
      expect(preset.name, 'P');
    });
  });

  group('SavedDevice JSON', () {
    test('round-trips all fields', () {
      final device = SavedDevice(
        id: 'd1',
        name: 'A1',
        macAddress: 'AA:BB:CC',
        label: 'Striker',
      );
      final back = SavedDevice.fromJson(device.toJson());
      expect(back.id, 'd1');
      expect(back.name, 'A1');
      expect(back.macAddress, 'AA:BB:CC');
      expect(back.label, 'Striker');
    });

    test('missing macAddress/label fall back to empty strings', () {
      final back = SavedDevice.fromJson({'id': 'd2', 'name': 'A2'});
      expect(back.macAddress, '');
      expect(back.label, '');
    });
  });

  group('PresetService presets', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('loadAll returns empty when nothing stored', () async {
      expect(await PresetService().loadAll(), isEmpty);
    });

    test('save adds then upserts by id (no duplicates)', () async {
      final service = PresetService();
      final preset = GamePreset.create('P', const [
        ModuleConfig(moduleId: 0, macAddress: 'AA', label: 'A1'),
      ]);

      await service.save(preset);
      expect((await service.loadAll()).length, 1);

      // Same id, changed name -> upsert, not a second entry.
      preset.name = 'P renamed';
      await service.save(preset);
      final all = await service.loadAll();
      expect(all.length, 1);
      expect(all.single.name, 'P renamed');
    });

    test('delete removes only the matching preset', () async {
      final service = PresetService();
      final a = GamePreset.create('A', const []);
      final b = GamePreset.create('B', const []);
      await service.save(a);
      await service.save(b);

      await service.delete(a.id);
      final all = await service.loadAll();
      expect(all.length, 1);
      expect(all.single.id, b.id);
    });
  });

  group('PresetService saved devices', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('save/upsert/delete a device round-trips through prefs', () async {
      final service = PresetService();
      final device = SavedDevice.create(
        name: 'A1',
        macAddress: 'AA:BB',
        label: 'Keeper',
      );

      await service.saveDevice(device);
      var all = await service.loadAllDevices();
      expect(all.length, 1);
      expect(all.single.label, 'Keeper');

      await service.deleteDevice(device.id);
      all = await service.loadAllDevices();
      expect(all, isEmpty);
    });
  });
}
