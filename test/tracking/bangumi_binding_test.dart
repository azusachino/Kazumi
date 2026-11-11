import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/tracking/bangumi_account.dart';
import 'package:kazumi/services/tracking/bangumi_binding.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/tracking/tracker.dart';
import 'package:kazumi/services/tracking/tracking_sync.dart';

import 'tracking_sync_test.dart' show FakeTracker, MemoryBindings, MemoryOutbox;

void main() {
  test('watched events create one binding only when signed in', () async {
    final dir = await Directory.systemTemp.createTemp('kazumi-binding-test');
    Hive.init(dir.path);
    final settings = await Hive.openBox<dynamic>('settings');
    final tombstones = await Hive.openBox<int>('trackingTombstones');
    final tracker = FakeTracker(TrackerId.bangumi);
    final account = BangumiAccount(settings: settings, tracker: tracker);
    final bindings = MemoryBindings();
    final outbox = MemoryOutbox();
    final sync = TrackingSync(
      bindings: bindings,
      outbox: outbox,
      trackers: [],
      tokenProvider: (_) => account.validToken(),
    );
    final now = DateTime.utc(2026, 11, 11);
    final manager = BangumiBindingManager(
      account,
      bindings,
      sync,
      tombstones: tombstones,
      clock: () => now,
    );
    final item = BangumiItem(
      id: 123,
      type: 2,
      name: 'show',
      nameCn: '中文',
      summary: '',
      airDate: '',
      airWeekday: 0,
      rank: 0,
      images: {},
      tags: [],
      alias: [],
      ratingScore: 0,
      votes: 0,
      votesCount: [],
      info: '',
    );
    await manager.watched(item, 1);
    expect(bindings.rows, isEmpty);
    expect(outbox.rows, isEmpty);
    await account.signInWithToken('token');
    await Future.wait([manager.watched(item, 1), manager.watched(item, 2)]);
    expect(bindings.rows.length, 1);
    final binding = bindings.rows['123:bangumi']!;
    expect(binding.remoteId, '123');
    expect(binding.title, 'show');
    expect(binding.updatedAt, now);
    expect(outbox.rows['123:bangumi']!.progress, 2);
    await manager.watched(item, 3);
    expect(bindings.rows['123:bangumi']!.generation, binding.generation);
    for (final entry in {
      CollectType.watching: TrackStatus.current,
      CollectType.planToWatch: TrackStatus.planning,
      CollectType.onHold: TrackStatus.paused,
      CollectType.watched: TrackStatus.completed,
      CollectType.abandoned: TrackStatus.dropped,
    }.entries) {
      await manager.statusChanged(item, entry.key);
      expect(outbox.rows['123:bangumi']!.status, entry.value);
    }
    final revision = outbox.rows['123:bangumi']!.revision;
    await manager.statusChanged(item, CollectType.none);
    expect(outbox.rows['123:bangumi']!.revision, revision);

    await manager.stopTracking(item.id);
    expect(bindings.rows.containsKey('123:bangumi'), isFalse);
    expect(tombstones.get('123:bangumi'), now.millisecondsSinceEpoch);
    expect(
      settings.get(SettingsKeys.bangumiExcludedSubjectIds.name),
      contains('123'),
    );
    await manager.watched(item, 4);
    expect(bindings.rows.containsKey('123:bangumi'), isFalse);
    await manager.startTracking(item);
    expect(bindings.rows['123:bangumi']?.remoteId, '123');
    expect(bindings.rows['123:bangumi']?.updatedAt, now);
    expect(tombstones.containsKey('123:bangumi'), isFalse);
    expect(
      settings.get(SettingsKeys.bangumiExcludedSubjectIds.name),
      isNot(contains('123')),
    );
    sync.dispose();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('startTracking seeds 想看 only for a newly created binding', () async {
    final dir = await Directory.systemTemp.createTemp('kazumi-start-tracking');
    Hive.init(dir.path);
    final settings = await Hive.openBox<dynamic>('settings');
    final tombstones = await Hive.openBox<int>('trackingTombstones');
    final account = BangumiAccount(
      settings: settings,
      tracker: FakeTracker(TrackerId.bangumi),
    );
    final bindings = MemoryBindings();
    final outbox = MemoryOutbox();
    final tracker = FakeTracker(TrackerId.bangumi);
    final sync = TrackingSync(
      bindings: bindings,
      outbox: outbox,
      trackers: [tracker],
      tokenProvider: (_) => account.validToken(),
      delay: (_) async {},
      schedule: (_, _) => () {},
    );
    final manager = BangumiBindingManager(
      account,
      bindings,
      sync,
      tombstones: tombstones,
    );
    BangumiItem item(int id) => BangumiItem(
      id: id,
      type: 2,
      name: 'show $id',
      nameCn: '番剧 $id',
      summary: '',
      airDate: '',
      airWeekday: 0,
      rank: 0,
      images: {},
      tags: [],
      alias: [],
      ratingScore: 0,
      votes: 0,
      votesCount: [],
      info: '',
    );
    await account.signInWithToken('token');

    // An explicit add creates the binding and sends one planning (想看) write.
    await manager.startTracking(item(123));
    await sync.drain();
    expect(bindings.rows['123:bangumi']?.remoteId, '123');
    expect(tracker.calls, [(null, TrackStatus.planning, null)]);

    // Still idempotent: adding again sends nothing more.
    await manager.startTracking(item(123));
    await sync.drain();
    expect(tracker.calls.length, 1);

    // An already-bound subject keeps the status the owner chose.
    await sync.enqueue(
      123,
      status: TrackStatus.current,
      trackerId: TrackerId.bangumi,
    );
    await sync.drain();
    expect(tracker.calls.last, (null, TrackStatus.current, null));
    await manager.startTracking(item(123));
    await sync.drain();
    expect(tracker.calls.length, 2);

    // Implicit binding creation (import, WebDAV apply, startup backfill)
    // still owes no write.
    await manager.ensureBangumiBindings([item(456)]);
    await sync.drain();
    expect(bindings.rows.containsKey('456:bangumi'), isTrue);
    expect(outbox.rows.containsKey('456:bangumi'), isFalse);
    expect(tracker.calls.length, 2);

    sync.dispose();
    await Hive.close();
    await dir.delete(recursive: true);
  });
}
