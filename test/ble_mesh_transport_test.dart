
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ble_mesh_chat/ble_mesh_chat.dart';

import 'fake_ble_platform_api.dart';

void main() {
  late FakeBlePlatformApi platform;
  late BleMeshTransport transport;

  setUp(() {
    platform = FakeBlePlatformApi();
    transport = BleMeshTransport(api: platform);
  });

  tearDown(() async {
    await transport.dispose();
    await platform.close();
  });

  Uint8List bytes(int length) =>
      Uint8List.fromList(List<int>.filled(length, 0x41));

  group('link bookkeeping', () {
    test('linkUp adds the link and publishes the new set', () async {
      final seen = <int>[];
      transport.linksChanged.listen((links) => seen.add(links.length));

      platform.emitLinkUp('c:AA');
      platform.emitLinkUp('p:BB');
      await pumpEventQueue();

      expect(transport.links.keys, containsAll(['c:AA', 'p:BB']));
      expect(seen, [1, 2]);
    });

    test('linkDown removes the link and reports the reason', () async {
      final downs = <BleLinkDown>[];
      transport.linkDown.listen(downs.add);

      platform.emitLinkUp('c:AA');
      await pumpEventQueue();
      platform.emitLinkDown('c:AA', reason: 'peer walked away');
      await pumpEventQueue();

      expect(transport.links, isEmpty);
      expect(downs.single.linkId, 'c:AA');
      expect(downs.single.reason, 'peer walked away');
    });

    test('a frame is never delivered before its own linkUp', () async {
      final order = <String>[];
      transport.linkUp.listen((link) => order.add('up:${link.linkId}'));
      transport.frames.listen((frame) => order.add('frame:${frame.linkId}'));

      platform.emitLinkUp('c:AA');
      platform.emitFrame('c:AA', [1, 2, 3]);
      await pumpEventQueue();

      expect(order, ['up:c:AA', 'frame:c:AA']);
    });

    test('losing the radio clears the link snapshot', () async {
      platform.emitLinkUp('c:AA');
      platform.emitLinkUp('c:BB');
      await pumpEventQueue();
      expect(transport.links, hasLength(2));

      platform.emitAdapterState(BleAdapterState.poweredOff);
      await pumpEventQueue();

      expect(transport.links, isEmpty);
      expect(transport.lastAdapterState, BleAdapterState.poweredOff);
    });

    test('minFrameSize reports the most restrictive live link', () async {
      expect(transport.minFrameSize, isNull);

      platform.emitLinkUp('c:AA', maxFrameSize: 244);
      platform.emitLinkUp('p:BB', maxFrameSize: 20);
      await pumpEventQueue();
      expect(transport.minFrameSize, 20);

      platform.emitLinkDown('p:BB');
      await pumpEventQueue();
      expect(transport.minFrameSize, 244);
    });

    test('refreshLinks replaces Dart state from the platform', () async {
      platform.emitLinkUp('c:STALE');
      await pumpEventQueue();

      platform.platformLinks = [
        BleLink(
          linkId: 'c:REAL',
          role: BleLinkRole.central,
          remoteId: 'remote',
          maxFrameSize: 185,
          connectedAtMs: 0,
        ),
      ];
      await transport.refreshLinks();

      expect(transport.links.keys, ['c:REAL']);
    });
  });

  group('send', () {
    test('rejects an oversized frame without touching the platform', () async {
      platform.emitLinkUp('c:AA', maxFrameSize: 20);
      await pumpEventQueue();

      await expectLater(
        transport.send('c:AA', bytes(21)),
        throwsA(isA<BleFrameTooLargeException>()),
      );
      expect(platform.sent, isEmpty);
    });

    test('accepts a frame exactly at the limit', () async {
      platform.emitLinkUp('c:AA', maxFrameSize: 20);
      await pumpEventQueue();

      await transport.send('c:AA', bytes(20));

      expect(platform.sent.single.linkId, 'c:AA');
      expect(platform.sent.single.frame, hasLength(20));
    });

    test('throws for a link that is no longer live', () async {
      await expectLater(
        transport.send('c:GONE', bytes(4)),
        throwsA(isA<BleUnknownLinkException>()),
      );
    });
  });

  group('broadcast', () {
    test('fans out to every live link', () async {
      platform.emitLinkUp('c:AA');
      platform.emitLinkUp('p:BB');
      await pumpEventQueue();

      final report = await transport.broadcast(bytes(10));

      expect(report.isCompleteSuccess, isTrue);
      expect(report.delivered, containsAll(['c:AA', 'p:BB']));
      expect(platform.sent, hasLength(2));
    });

    test('skips the link a frame arrived on, so it is not echoed back', () async {
      platform.emitLinkUp('c:AA');
      platform.emitLinkUp('p:BB');
      await pumpEventQueue();

      final report = await transport.broadcast(bytes(10), exceptLinkId: 'c:AA');

      expect(report.delivered, ['p:BB']);
      expect(platform.sent.map((s) => s.linkId), ['p:BB']);
    });

    test('a failing link does not stop the others', () async {
      platform.emitLinkUp('c:AA');
      platform.emitLinkUp('p:BB');
      platform.emitLinkUp('c:CC');
      await pumpEventQueue();
      platform.sendFailures['p:BB'] = PlatformException(code: 'write_failed');

      final report = await transport.broadcast(bytes(10));

      expect(report.delivered, containsAll(['c:AA', 'c:CC']));
      expect(report.failed.keys, ['p:BB']);
      expect(report.attempted, 3);
      expect(report.isCompleteSuccess, isFalse);
    });

    test('reports links whose frame size is too small instead of splitting', () async {
      platform.emitLinkUp('c:AA', maxFrameSize: 244);
      platform.emitLinkUp('p:TINY', maxFrameSize: 20);
      await pumpEventQueue();

      final report = await transport.broadcast(bytes(100));

      expect(report.delivered, ['c:AA']);
      expect(report.failed['p:TINY'], isA<BleFrameTooLargeException>());
    });
  });

  group('unsupported platforms', () {
    setUp(() {
      platform.throwOnEveryCall = MissingPluginException('no implementation');
    });

    test('start surfaces a typed unsupported error', () async {
      await expectLater(
        transport.start(),
        throwsA(isA<BleUnsupportedPlatformException>()),
      );
      expect(transport.isRunning, isFalse);
    });

    test('capabilities degrades instead of throwing', () async {
      final capabilities = await transport.capabilities();

      expect(capabilities.supportsCentral, isFalse);
      expect(capabilities.supportsPeripheral, isFalse);
      expect(capabilities.platformName, 'unsupported');
    });

    test('stop is a no-op', () async {
      await transport.stop();
      expect(transport.isRunning, isFalse);
    });
  });

  group('errors and lifecycle', () {
    test('platform errors are advisory, not fatal', () async {
      final errors = <BleTransportError>[];
      transport.errors.listen(errors.add);

      platform.emitError(
        BleErrorCode.advertisingFailed,
        'advertising failed with code 1',
      );
      await pumpEventQueue();

      expect(errors.single.code, BleErrorCode.advertisingFailed);
      expect(transport.links, isEmpty);
    });

    test('start passes the sample service UUID by default', () async {
      await transport.start();

      expect(platform.startCalls, 1);
      expect(platform.lastConfig?.serviceUuid, BleMeshUuids.service);
      expect(
        platform.lastConfig?.characteristicUuid,
        BleMeshUuids.characteristic,
      );
      expect(transport.isRunning, isTrue);
    });

    test('using a disposed transport is an error, not silence', () async {
      final disposable = BleMeshTransport(api: platform);
      await disposable.dispose();

      expect(() => disposable.send('c:AA', bytes(1)), throwsStateError);
    });
  });
}
