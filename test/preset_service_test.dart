import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/services/preset_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // SharedPreferences.setMockInitialValues needs the platform channel binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ModuleConfig JSON', () {
    test('missing macAddress/label fall back to empty strings', () {
      final back = ModuleConfig.fromJson({'moduleId': 0});
      expect(back.moduleId, 0);
      expect(back.macAddress, '');
      expect(back.label, '');
    });
  });

  group('GamePreset JSON', () {});

  group('SavedDevice JSON', () {});

  group('PresetService presets', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

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
