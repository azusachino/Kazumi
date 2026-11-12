import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/tracking/models.dart';
import 'package:kazumi/services/tracking/tracker.dart';
import 'package:kazumi/services/tracking/tracking_entry_cache.dart';

void main() {
  final at = DateTime.utc(2026, 11, 11);
  final binding = TrackingBinding(
    subjectId: 1, trackerId: TrackerId.bangumi, remoteId: '1', generation: 'a',
  );
  const entry = RemoteEntry(progress: 3, status: TrackStatus.planning, score: 80, total: 12);

  test('cache scopes snapshots to the account and binding generation', () async {
    var account = 'first';
    final cache = TrackingEntryCache(accountScope: (_) => account);
    await cache.put(binding, entry, at);
    expect(cache.get(binding)?.entry?.status, TrackStatus.planning);
    expect(cache.get(binding)?.isFresh(at.add(const Duration(minutes: 1))), isTrue);
    expect(cache.get(binding)?.isFresh(at.add(const Duration(minutes: 6))), isFalse);
    // A timestamp from the future (clock rollback) is not fresh either.
    expect(cache.get(binding)?.isFresh(at.subtract(const Duration(minutes: 1))), isFalse);
    final rebound = TrackingBinding(
      subjectId: 1, trackerId: TrackerId.bangumi, remoteId: '2', generation: 'b',
    );
    expect(cache.get(rebound), isNull);
    account = 'second';
    expect(cache.get(binding), isNull);
    await cache.put(binding, entry, at, scope: 'first');
    expect(cache.get(binding), isNull);
  });

  test('cached missing remote entry is distinguishable from a cache miss', () async {
    final cache = TrackingEntryCache();
    expect(cache.get(binding), isNull);
    await cache.put(binding, null, at);
    expect(cache.get(binding), isNotNull);
    expect(cache.get(binding)!.entry, isNull);
  });

  test('a persisted snapshot keeps the tracker updated_at', () async {
    final dir = await Directory.systemTemp.createTemp('kazumi-entry-cache');
    addTearDown(() => dir.delete(recursive: true));
    Hive.init(dir.path);
    final box = await Hive.openBox<String>('trackingEntryCache_updated_at');
    addTearDown(box.close);
    final updatedAt = DateTime.utc(2026, 5, 4, 3, 2, 1);

    await TrackingEntryCache(box: box).put(
      binding,
      RemoteEntry(
        progress: 3,
        status: TrackStatus.current,
        updatedAt: updatedAt,
      ),
      at,
    );

    final reopened = TrackingEntryCache(box: box);
    expect(reopened.get(binding)?.entry?.status, TrackStatus.current);
    expect(reopened.get(binding)?.entry?.updatedAt, updatedAt);
  });

  test('corrupt persisted snapshots read as a miss instead of failing', () async {
    final dir = await Directory.systemTemp.createTemp('kazumi-entry-cache');
    addTearDown(() => dir.delete(recursive: true));
    Hive.init(dir.path);
    final box = await Hive.openBox<String>('trackingEntryCache_corrupt');
    addTearDown(box.close);
    final cache = TrackingEntryCache(box: box);
    await cache.put(binding, entry, at);
    final key = box.keys.single as String;

    await box.put(key, 'not json at all');
    expect(TrackingEntryCache(box: box).get(binding), isNull);

    await box.put(
      key,
      '{"entry":{"progress":"three"},"fetchedAt":"$at"}',
    );
    expect(TrackingEntryCache(box: box).get(binding), isNull);
  });
}
