import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/hive_registrar.g.dart';
import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/services/tracking/models.dart';
import 'package:kazumi/services/tracking/stores.dart';
import 'package:kazumi/services/tracking/tracker.dart';

void main() {
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('kazumi-tracking');
    Hive.init(directory.path);
    Hive.registerAdapters();
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('tracking boxes persist models across reopening', () async {
    {
      var (bindings, outbox) = await openTrackingStores();
      final binding = TrackingBinding(
        subjectId: 1,
        trackerId: TrackerId.anilist,
        remoteId: '42',
        total: 12,
      );
      await bindings.put(binding);
      await outbox.put(
        OutboxEntry(
          bindingGeneration: binding.generation,
          subjectId: 1,
          trackerId: TrackerId.anilist,
          remoteId: '42',
          progress: 8,
          status: TrackStatus.current,
          attempts: 2,
        ),
      );
      await bindings.box.close();
      await outbox.box.close();
      (bindings, outbox) = await openTrackingStores();
      expect((await bindings.get('1:anilist'))?.total, 12);
      expect((await bindings.get('1:anilist'))?.generation, binding.generation);
      expect(
        (await outbox.get('1:anilist'))?.bindingGeneration,
        binding.generation,
      );
      expect((await outbox.get('1:anilist'))?.attempts, 2);
      expect((await outbox.get('1:anilist'))?.status, TrackStatus.current);
    }
  });

  group('collect change origin', () {
    test('a row written without field 5 loads as a user change', () {
      final change = CollectedBangumiChangeAdapter().read(
        _StoredRowReader({
          0: 1700000000,
          1: 42,
          2: 2,
          3: 4,
          4: 1700000000,
        }),
      );

      expect(change.origin, CollectChangeOrigin.user);
      expect(change.bangumiID, 42);
      expect(change.type, 4);
    });

    test('a new write round-trips its origin through the box', () async {
      var box = await Hive.openBox<CollectedBangumiChange>('collectchanges');
      await box.put(
        1,
        CollectedBangumiChange(
          1,
          42,
          2,
          4,
          1700000000,
          origin: CollectChangeOrigin.tracker,
        ),
      );
      await box.put(2, CollectedBangumiChange(2, 43, 2, 1, 1700000001));
      await box.close();

      box = await Hive.openBox<CollectedBangumiChange>('collectchanges');
      expect(box.get(1)!.origin, CollectChangeOrigin.tracker);
      expect(box.get(1)!.type, 4);
      expect(box.get(2)!.origin, CollectChangeOrigin.user);
    });
  });
}

/// Replays a stored row's fields the way the generated adapter reads them:
/// the field count, then one pair of field index and value per field.
class _StoredRowReader implements BinaryReader {
  _StoredRowReader(Map<int, dynamic> fields)
      : _tokens = [
          fields.length,
          ...fields.entries.expand((entry) => [entry.key, entry.value]),
        ];

  final List<dynamic> _tokens;
  int _position = 0;

  @override
  int readByte() => _tokens[_position++] as int;

  @override
  dynamic read([int? typeId]) => _tokens[_position++];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected ${invocation.memberName}');
}
