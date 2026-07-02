import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/utils/ble_address.dart';

ScanResult _scanResult({String advName = '', required String remoteId}) {
  return ScanResult(
    device: BluetoothDevice(remoteId: DeviceIdentifier(remoteId)),
    advertisementData: AdvertisementData(
      advName: advName,
      txPowerLevel: null,
      appearance: null,
      connectable: true,
      manufacturerData: const {},
      serviceData: const {},
      serviceUuids: const [],
    ),
    rssi: -50,
    timeStamp: DateTime(2026),
  );
}

void main() {
  group('isMacFormat', () {
    test('accepts a colon-separated 17-char MAC, either case', () {
      expect(isMacFormat('AA:BB:CC:DD:EE:FF'), isTrue);
      expect(isMacFormat('aa:bb:cc:dd:ee:0f'), isTrue);
    });

    test('rejects UUIDs, partial MACs, other separators and garbage', () {
      expect(isMacFormat('12345678-1234-1234-1234-123456789012'), isFalse);
      expect(isMacFormat('AA:BB:CC:DD:EE'), isFalse);
      expect(isMacFormat('AA-BB-CC-DD-EE-FF'), isFalse);
      expect(isMacFormat('AA:BB:CC:DD:EE:FF:00'), isFalse);
      expect(isMacFormat(''), isFalse);
      expect(isMacFormat('GG:BB:CC:DD:EE:FF'), isFalse);
    });
  });

  group('macFromAdvertisedName', () {
    test('parses the firmware name RCJs-m_<MAC> and normalizes to uppercase',
        () {
      expect(macFromAdvertisedName('RCJs-m_AA:BB:CC:DD:EE:FF'),
          'AA:BB:CC:DD:EE:FF');
      expect(macFromAdvertisedName('rcjs-M_aa:bb:cc:dd:ee:ff'),
          'AA:BB:CC:DD:EE:FF');
    });

    test('rejects wrong prefixes and malformed tails', () {
      expect(
          macFromAdvertisedName('RCJ-soccer_module-AA:BB:CC:DD:EE:FF'), isNull);
      expect(macFromAdvertisedName('RCJs-m_AA:BB:CC:DD:EE'), isNull);
      expect(macFromAdvertisedName('RCJs-m_'), isNull);
      expect(macFromAdvertisedName(''), isNull);
      expect(macFromAdvertisedName('AA:BB:CC:DD:EE:FF'), isNull);
    });
  });

  group('foldScanHits', () {
    test('maps wanted advertised MACs to their remote ids', () {
      final hits = foldScanHits(
        {'AA:BB:CC:DD:EE:FF'},
        [_scanResult(advName: 'RCJs-m_AA:BB:CC:DD:EE:FF', remoteId: 'uuid-1')],
      );
      expect(hits, {'AA:BB:CC:DD:EE:FF': 'uuid-1'});
    });

    test('ignores unwanted modules, non-module names and empty names', () {
      final hits = foldScanHits(
        {'AA:BB:CC:DD:EE:FF'},
        [
          _scanResult(advName: 'RCJs-m_11:22:33:44:55:66', remoteId: 'uuid-2'),
          _scanResult(advName: 'SomethingElse', remoteId: 'uuid-3'),
          _scanResult(remoteId: 'uuid-4'),
        ],
      );
      expect(hits, isEmpty);
    });

    test('collects multiple wanted modules in one pass, first sighting wins',
        () {
      final hits = foldScanHits(
        {'AA:BB:CC:DD:EE:FF', '11:22:33:44:55:66'},
        [
          _scanResult(advName: 'RCJs-m_AA:BB:CC:DD:EE:FF', remoteId: 'uuid-1'),
          _scanResult(advName: 'RCJs-m_11:22:33:44:55:66', remoteId: 'uuid-2'),
          _scanResult(advName: 'RCJs-m_AA:BB:CC:DD:EE:FF', remoteId: 'uuid-9'),
        ],
      );
      expect(
          hits, {'AA:BB:CC:DD:EE:FF': 'uuid-1', '11:22:33:44:55:66': 'uuid-2'});
    });

    test('matches case-insensitively against a lowercase wanted set entry', () {
      // Callers normalize, but the fold itself must not depend on it silently:
      // wanted entries are compared after uppercase normalization.
      final hits = foldScanHits(
        {'aa:bb:cc:dd:ee:ff'},
        [_scanResult(advName: 'rcjs-m_AA:bb:CC:dd:EE:ff', remoteId: 'uuid-1')],
      );
      expect(hits, {'AA:BB:CC:DD:EE:FF': 'uuid-1'});
    });
  });
}
