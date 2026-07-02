// Tests for #70: a referee-link match auto-pairs each side's comm modules from
// the server-provided MACs (home_module_macs / away_module_macs), mapping them
// onto the fixed per-side module slots by team ID so a swapped side never
// crosses the sides.
//
// Uses testWidgets for the same reason as scoreboard_field_test/game_recovery_
// test: the Game constructor stands up wakelock/notification/MQTT/bridge
// services whose platform-channel calls reject asynchronously in the headless
// test VM, which the widget binding tolerates.

import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/models/team.dart';
import 'package:rcj_scoreboard/services/match_state_store.dart';
import 'package:rcj_scoreboard/utils/ble_address.dart';

Map<String, dynamic> _config({
  String matchCode = 'M-1',
  bool homeIsLeft = true,
  List<String> homeMacs = const [],
  List<String> awayMacs = const [],
}) =>
    {
      'match_code': matchCode,
      'home_team': 'Home',
      'away_team': 'Away',
      'home_is_left': homeIsLeft,
      'venue': '1',
      'scheduled_start': null,
      'duration_seconds': 600,
      'timezone': 'Europe/Prague',
      'version': 1,
      'status': 'SCHEDULED',
      'home_module_macs': homeMacs,
      'away_module_macs': awayMacs,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  // A loaded Game with every slot disabled. applyPresetConfig then sets each
  // module's macAddress (the mapping under test) WITHOUT a real bleConnect(),
  // which is unsupported in the headless test VM — mirroring game_recovery_
  // test's disabled-during-restore pattern; on a real device the enabled slots
  // connect as normal. numberOfPlayers is set AFTER the two pumps that drain the
  // async _loadPrefs(), so its default (2) doesn't overwrite the 0.
  Future<Game> loadedGame(WidgetTester tester) async {
    final game = Game();
    await tester.pump();
    await tester.pump();
    game.numberOfPlayers = 0;
    return game;
  }

  Team teamById(Game game, String id) =>
      game.teams.firstWhere((t) => t.id == id);

  void apply(Game game, Map<String, dynamic> config) {
    game.scoreboardResultService.debugApplyMatchConfig(
      ScoreboardMatchConfig.fromJson(config),
    );
  }

  testWidgets('pairs home MACs onto team A and away MACs onto team B',
      (tester) async {
    final game = await loadedGame(tester);

    apply(
      game,
      _config(
        homeIsLeft: true,
        homeMacs: ['A1:B2:C3:D4:E5:F6', '11:22:33:44:55:66'],
        awayMacs: ['AA:BB:CC:DD:EE:FF'],
      ),
    );
    await tester.pump();

    expect(teamById(game, 'A').modules[0].macAddress, 'A1:B2:C3:D4:E5:F6');
    expect(teamById(game, 'A').modules[1].macAddress, '11:22:33:44:55:66');
    expect(teamById(game, 'B').modules[0].macAddress, 'AA:BB:CC:DD:EE:FF');

    game.dispose();
  });

  testWidgets('a right-side home maps home MACs onto team B (keyed by ID)',
      (tester) async {
    final game = await loadedGame(tester);

    apply(
      game,
      _config(
        homeIsLeft: false,
        homeMacs: ['A1:B2:C3:D4:E5:F6'],
        awayMacs: ['AA:BB:CC:DD:EE:FF'],
      ),
    );
    await tester.pump();

    // home_is_left:false binds home -> team B, away -> team A.
    expect(teamById(game, 'B').modules[0].macAddress, 'A1:B2:C3:D4:E5:F6');
    expect(teamById(game, 'A').modules[0].macAddress, 'AA:BB:CC:DD:EE:FF');

    game.dispose();
  });

  testWidgets('lower-case MACs are normalised to upper-case', (tester) async {
    final game = await loadedGame(tester);

    apply(game, _config(homeMacs: ['a1:b2:c3:d4:e5:f6']));
    await tester.pump();

    expect(teamById(game, 'A').modules[0].macAddress, 'A1:B2:C3:D4:E5:F6');

    game.dispose();
  });

  testWidgets('a partial MAC list only fills the slots it provides',
      (tester) async {
    final game = await loadedGame(tester);

    apply(game, _config(homeMacs: ['A1:B2:C3:D4:E5:F6']));
    await tester.pump();

    // Only slot 0 was named; the rest stay unpaired.
    expect(teamById(game, 'A').modules[0].macAddress, 'A1:B2:C3:D4:E5:F6');
    expect(teamById(game, 'A').modules[1].macAddress, '');

    game.dispose();
  });

  testWidgets(
      'a later MAC set pairs even when the fixture signature is unchanged',
      (tester) async {
    final game = await loadedGame(tester);

    // First apply: the same fixture with no module MACs — the pre-#70 persisted
    // shape an upgrading user carries. Nothing to pair yet.
    apply(game, _config());
    await tester.pump();
    expect(teamById(game, 'A').modules[0].macAddress, '');

    // A refresh of the SAME fixture (identical signature fields) that now
    // carries MACs. _applyScoreboardMatchConfig dedupes on the unchanged
    // signature — MACs are not part of it — so the module sync is what must
    // still pair the newly-arrived MAC.
    apply(game, _config(homeMacs: ['A1:B2:C3:D4:E5:F6']));
    await tester.pump();

    expect(teamById(game, 'A').modules[0].macAddress, 'A1:B2:C3:D4:E5:F6');

    game.dispose();
  });

  testWidgets('no module keys leaves every slot unpaired', (tester) async {
    final game = await loadedGame(tester);

    apply(game, _config());
    await tester.pump();

    for (final module in teamById(game, 'A').modules) {
      expect(module.macAddress, '');
    }

    game.dispose();
  });

  group('#82 hardware-MAC / iOS-UUID split', () {
    tearDown(() {
      debugUseIosBleUuidOverride = null;
    });

    testWidgets('Android pairing backfills hardwareMac from the MAC',
        (tester) async {
      final game = await loadedGame(tester);

      apply(game, _config(homeMacs: ['A1:B2:C3:D4:E5:F6']));
      await tester.pump();

      final module = teamById(game, 'A').modules[0];
      expect(module.macAddress, 'A1:B2:C3:D4:E5:F6');
      expect(module.hardwareMac, 'A1:B2:C3:D4:E5:F6');

      game.dispose();
    });

    testWidgets(
        'iOS pairing with a cached UUID connects by UUID and keeps the MAC',
        (tester) async {
      debugUseIosBleUuidOverride = true;
      SharedPreferences.setMockInitialValues({
        'mqtt_enabled': false,
        'ios_mac_uuid_cache':
            jsonEncode({'A1:B2:C3:D4:E5:F6': '12345678-1234-1234-1234-1234567890AB'}),
      });
      final game = await loadedGame(tester);

      apply(game, _config(homeMacs: ['A1:B2:C3:D4:E5:F6']));
      await tester.pump();

      final module = teamById(game, 'A').modules[0];
      expect(module.macAddress, '12345678-1234-1234-1234-1234567890AB');
      expect(module.hardwareMac, 'A1:B2:C3:D4:E5:F6');
      // Cache hit → nothing pending with the resolver.
      expect(game.iosMacResolver.pendingCount, 0);

      game.dispose();
    });

    testWidgets(
        'iOS enrollment after kickoff gives up immediately (Not found) — '
        'no scan during a running half', (tester) async {
      debugUseIosBleUuidOverride = true;
      final game = await loadedGame(tester);
      final module = teamById(game, 'A').modules[0];
      module.hardwareMac = 'A1:B2:C3:D4:E5:F6';

      // Kickoff: the resolver is stopped for the rest of the match. A
      // fallback enrollment (e.g. a stale cached UUID failing mid-match)
      // must settle to Not found without any scan.
      game.startTimer();
      game.enrollIosMacResolve(module);
      await tester.pump();

      expect(module.macAddress, '');
      expect(module.bleStatus, 'Not found');
      expect(game.iosMacResolver.pendingCount, 0);

      game.stopTimer();
      game.dispose();
    });

    testWidgets(
        'iOS pairing with no cache enrolls the module as Searching...',
        (tester) async {
      debugUseIosBleUuidOverride = true;
      final game = await loadedGame(tester);

      apply(game, _config(homeMacs: ['A1:B2:C3:D4:E5:F6']));
      await tester.pump();

      final module = teamById(game, 'A').modules[0];
      expect(module.macAddress, '');
      expect(module.hardwareMac, 'A1:B2:C3:D4:E5:F6');
      expect(module.bleStatus, 'Searching...');
      expect(game.iosMacResolver.pendingCount, 1);

      // Kickoff stops the resolve scanning for the rest of the match and
      // settles the pending slot to Not found (invariant #1).
      game.startTimer();
      expect(module.bleStatus, 'Not found');
      expect(game.iosMacResolver.pendingCount, 0);

      game.stopTimer();
      game.dispose();
      // Drain any scan/retry timers the resolve loop may have scheduled
      // before the kickoff stopped it.
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets(
        'retargeting a CONNECTED slot to a different MAC replaces the '
        'identity instead of silently keeping the old link (RAVF003)',
        (tester) async {
      final game = await loadedGame(tester);
      final module = teamById(game, 'A').modules[0];
      // Disabled so applyPresetConfig skips the real bleConnect (headless VM);
      // the guards under test only read the connected flag.
      module.disable();
      module.macAddress = 'AA:AA:AA:AA:AA:01';
      module.hardwareMac = 'AA:AA:AA:AA:AA:01';
      module.debugIsConnected = true;

      module.applyPresetConfig('BB:BB:BB:BB:BB:02', '');

      expect(module.macAddress, 'BB:BB:BB:BB:BB:02');
      expect(module.hardwareMac, 'BB:BB:BB:BB:BB:02');
      expect(module.isConnected, isFalse); // old link dropped, fresh boundary

      await tester.pump(const Duration(milliseconds: 1500));
      game.dispose();
    });

    testWidgets(
        're-pairing the SAME hardware identity on a connected iOS slot stays '
        'a no-op (idempotency guard reads the previous identity)',
        (tester) async {
      final game = await loadedGame(tester);
      final module = teamById(game, 'A').modules[0];
      module.macAddress = '12345678-1234-1234-1234-1234567890AB';
      module.hardwareMac = 'AA:AA:AA:AA:AA:01';
      module.debugIsConnected = true;

      module.applyPresetConfig('AA:AA:AA:AA:AA:01', '');

      expect(module.macAddress, '12345678-1234-1234-1234-1234567890AB');
      expect(module.isConnected, isTrue);

      game.dispose();
    });

    testWidgets(
        'retargeting a connected slot to a hardware MAC awaiting resolution '
        'drops the live link (empty connection id path)', (tester) async {
      final game = await loadedGame(tester);
      final module = teamById(game, 'A').modules[0];
      module.macAddress = '12345678-1234-1234-1234-1234567890AB';
      module.hardwareMac = 'AA:AA:AA:AA:AA:01';
      module.debugIsConnected = true;

      module.applyPresetConfig('', '', hardwareMac: 'BB:BB:BB:BB:BB:02');

      expect(module.hardwareMac, 'BB:BB:BB:BB:BB:02');
      expect(module.isConnected, isFalse);

      game.dispose();
    });

    testWidgets(
        'connecting a different UUID with no derivable MAC clears the stale '
        'hardwareMac instead of reporting the previous module (RAVF002)',
        (tester) async {
      final game = await loadedGame(tester);
      final module = teamById(game, 'A').modules[0];
      module.hardwareMac = 'AA:AA:AA:AA:AA:01';

      module.setBleDevice(
          BluetoothDevice.fromId('12345678-1234-1234-1234-1234567890AB'));

      expect(module.hardwareMac, '');

      // And a caller that DOES know the MAC keeps it through setBleDevice.
      module.setBleDevice(
          BluetoothDevice.fromId('87654321-4321-4321-4321-BA0987654321'),
          hardwareMac: 'BB:BB:BB:BB:BB:02');
      expect(module.hardwareMac, 'BB:BB:BB:BB:BB:02');

      game.dispose();
    });

    testWidgets(
        'restore: pre-split snapshot backfills hardwareMac from a MAC-shaped '
        'connection id; split snapshot restores both fields', (tester) async {
      final game = await loadedGame(tester);
      final module = teamById(game, 'A').modules[0];

      // Pre-split snapshot (no hardwareMac key ≙ default ''), disabled so the
      // restore takes the non-reconnect branch (no bleConnect headless).
      module.restoreFromSnapshot(const ModuleSnapshot(
        moduleId: 0,
        isEnabled: false,
        macAddress: 'A1:B2:C3:D4:E5:F6',
        customLabel: null,
        state: 'stop',
        lastState: 'stop',
        penaltyTime: 0,
      ));
      expect(module.hardwareMac, 'A1:B2:C3:D4:E5:F6');

      // Split snapshot: an iOS Searching-state slot (hardware MAC known, no
      // connection id yet).
      final module2 = teamById(game, 'A').modules[1];
      module2.restoreFromSnapshot(const ModuleSnapshot(
        moduleId: 1,
        isEnabled: false,
        macAddress: '',
        hardwareMac: '11:22:33:44:55:66',
        customLabel: null,
        state: 'stop',
        lastState: 'stop',
        penaltyTime: 0,
      ));
      expect(module2.macAddress, '');
      expect(module2.hardwareMac, '11:22:33:44:55:66');

      game.dispose();
    });
  });
}
