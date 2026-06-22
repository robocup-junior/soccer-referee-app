// Tests for MatchStateStore (match cold-resume persistence, #45).
//
// SharedPreferences.setMockInitialValues needs the platform channel binding, so
// we ensure the test binding is initialized. getInstance() caches a static
// instance across tests, so we clear() it in setUp for a clean slate (and plant
// any preloaded values via setString rather than initial values). The store
// itself does no Flutter widget work, so plain test() is fine.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/services/match_state_store.dart';

const String _kSnapshotKey = 'match_state_snapshot';

MatchSnapshot _sampleSnapshot({
  int remainingTime = 312,
  bool inGame = true,
  String stage = 'firstHalf',
}) {
  return MatchSnapshot(
    stage: stage,
    remainingTime: remainingTime,
    isTimeRunning: false,
    inGame: inGame,
    timerButtonText: 'START',
    savedAtMs: 1000,
    teams: const [
      TeamSnapshot(id: 'A', name: 'Reds', score: 2),
      TeamSnapshot(id: 'B', name: 'Blues', score: 1),
    ],
    modules: const [
      ModuleSnapshot(
        moduleId: 0,
        isEnabled: true,
        macAddress: 'AA:BB:CC:DD:EE:FF',
        customLabel: 'R1',
        state: 'damage',
        lastState: 'play',
        penaltyTime: 45,
      ),
      ModuleSnapshot(
        moduleId: 5,
        isEnabled: false,
        macAddress: '',
        customLabel: null,
        state: 'stop',
        lastState: 'stop',
        penaltyTime: 0,
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    await prefs.clear(); // clean slate regardless of getInstance() caching
  });

  group('MatchSnapshot JSON', () {
    test('round-trips all fields incl. per-module recovery data', () {
      final back = MatchSnapshot.fromJson(_sampleSnapshot().toJson());
      expect(back.version, kMatchSnapshotVersion);
      expect(back.stage, 'firstHalf');
      expect(back.remainingTime, 312);
      expect(back.inGame, isTrue);
      expect(back.teams[0].id, 'A');
      expect(back.teams[1].name, 'Blues');
      expect(back.teams[1].score, 1);

      final m0 = back.modules[0];
      expect(m0.moduleId, 0);
      expect(m0.macAddress, 'AA:BB:CC:DD:EE:FF');
      expect(m0.customLabel, 'R1');
      expect(m0.state, 'damage');
      expect(m0.lastState, 'play');
      expect(m0.penaltyTime, 45);

      final m1 = back.modules[1];
      expect(m1.isEnabled, isFalse);
      expect(m1.customLabel, isNull);
      expect(m1.macAddress, '');
    });
  });

  group('MatchStateStore save/load', () {
    test('saves and loads a snapshot', () async {
      final store = MatchStateStore(prefs);
      await store.save(_sampleSnapshot());
      final loaded = store.load();
      expect(loaded, isNotNull);
      expect(loaded!.remainingTime, 312);
      expect(loaded.modules.first.penaltyTime, 45);
    });

    test('load() is null when no snapshot has been written', () {
      expect(MatchStateStore(prefs).load(), isNull);
    });

    test('load() is null on corrupt JSON', () async {
      await prefs.setString(_kSnapshotKey, 'not valid json {{{');
      expect(MatchStateStore(prefs).load(), isNull);
    });

    test('load() is null on version mismatch', () async {
      final store = MatchStateStore(prefs);
      await store.save(_sampleSnapshot());
      final raw = prefs.getString(_kSnapshotKey)!;
      final bumped = raw.replaceFirst(
          '"version":$kMatchSnapshotVersion', '"version":99999');
      await prefs.setString(_kSnapshotKey, bumped);
      expect(store.load(), isNull);
    });

    test('clear() removes the snapshot', () async {
      final store = MatchStateStore(prefs);
      await store.save(_sampleSnapshot());
      expect(store.load(), isNotNull);
      await store.clear();
      expect(store.load(), isNull);
    });

    test('a save after clear() is loadable again', () async {
      final store = MatchStateStore(prefs);
      await store.save(_sampleSnapshot());
      await store.clear();
      await store.save(_sampleSnapshot(remainingTime: 100));
      final loaded = store.load();
      expect(loaded, isNotNull);
      expect(loaded!.remainingTime, 100);
    });

    test(
        'a stale older save completing after a clear does NOT resurrect the match',
        () async {
      final store = MatchStateStore(prefs);
      await store.save(_sampleSnapshot());
      // Fire a save and a clear without awaiting the save first: the clear bumps
      // the generation/tombstone, so even if the older save lands last it must
      // be rejected on load.
      final staleSave = store.save(_sampleSnapshot(remainingTime: 999));
      final clear = store.clear();
      await Future.wait([staleSave, clear]);
      expect(store.load(), isNull,
          reason: 'cleared match must stay cleared even if a stale save lands');
    });

    test('a new save after an unawaited clear wins (latest intent)', () async {
      final store = MatchStateStore(prefs);
      await store.save(_sampleSnapshot());
      // Discard then immediately start a NEW match, both unawaited (as the app
      // does via _clearMatchState/_persistMatchState). The later save is the
      // genuine latest intent and must survive — the clear must not wipe it.
      final clear = store.clear();
      final save = store.save(_sampleSnapshot(remainingTime: 77));
      await Future.wait([clear, save]);
      final loaded = store.load();
      expect(loaded, isNotNull,
          reason: 'the newer save must win over the prior clear');
      expect(loaded!.remainingTime, 77);
    });

    test('tombstone rejects a stale snapshot that beat the clear to disk',
        () async {
      final store = MatchStateStore(prefs);
      await store.save(_sampleSnapshot());
      await store.clear();

      // Simulate a late write that physically beat the clear to disk: plant a
      // snapshot stamped with an old generation (0). A fresh store over the same
      // prefs must reject it via the persisted tombstone.
      await prefs.setString(
        _kSnapshotKey,
        '{"version":$kMatchSnapshotVersion,"generation":0,"stage":"firstHalf",'
            '"remainingTime":312,"isTimeRunning":false,"inGame":true,'
            '"timerButtonText":"START","teams":[],"modules":[],"savedAtMs":1}',
      );
      expect(MatchStateStore(prefs).load(), isNull);
    });
  });
}
