import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/tracking_webdav_exchange.dart';
import 'package:kazumi/services/tracking/models.dart';
import 'package:kazumi/services/tracking/stores.dart';
import 'package:kazumi/services/tracking/tracker.dart';
import 'package:kazumi/services/tracking/tracking_features.dart';
import 'package:kazumi/services/tracking/tracking_storage.dart';
import 'package:kazumi/services/tracking/tracking_startup.dart';
import 'package:kazumi/services/tracking/tracking_sync.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'tracking_sync_test.dart' show FakeTracker;

/// Each flag turns off one seam and nothing else: the same input with the flag
/// on is the control, and the rest of the suite pins the all-on behaviour.
void main() {
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('kazumi_features_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  setUp(() async {
    await GStorage.collectibles.clear();
    await GStorage.collectChanges.clear();
    await GStorage.trackingBindings.clear();
    await GStorage.trackingTombstones.clear();
    await GStorage.trackingOutbox.clear();
    await GStorage.putSetting(TrackingFeatures.flagsKey, <String, bool>{});
    await GStorage.putSetting(
      SettingsKeys.bangumiExcludedSubjectIds,
      <String>[],
    );
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  test('bindingsOnSync off creates no binding on startup or WebDAV apply',
      () async {
    // A stored pasted token signs the account in without a viewer request.
    await GStorage.bangumiAccount.settings.put(
        SettingsKeys.bangumiAccountToken.name, 'fake-bangumi-token');
    await GStorage.bangumiAccount.settings.put(
        SettingsKeys.bangumiAccountKind.name, 'pasted');
    await GStorage.collectibles.put(71, _collect(71, CollectType.watched));

    await _flags(bindingsOnSync: false);
    await KazumiTrackingStartup.run();
    await ensureCollectedBangumiBindings();
    expect(GStorage.trackingBindings.get('71:bangumi'), isNull);

    await _flags(bindingsOnSync: true);
    await KazumiTrackingStartup.run();
    expect(GStorage.trackingBindings.get('71:bangumi')?.remoteId, '71');
  });

  test('statusMirror off leaves the local library alone', () async {
    final controller = CollectController(CollectCrudRepository());

    await _flags(statusMirror: false);
    await controller.addCollectFromTracker(_item(72), CollectType.watching.value);
    expect(GStorage.collectibles.containsKey(72), isFalse);
    expect(GStorage.collectChanges, isEmpty);

    await _flags(statusMirror: true);
    await controller.addCollectFromTracker(_item(72), CollectType.watching.value);
    expect(GStorage.collectibles.get(72)?.type, CollectType.watching.value);
    expect(GStorage.collectChanges.length, 1);
  });

  test('remoteStatusFollow off does not rewrite the local category', () async {
    await GStorage.collectibles.put(73, _collect(73, CollectType.watching));

    await _flags(remoteStatusFollow: false);
    await followTrackerStatus(73, CollectType.watched.value);
    expect(GStorage.collectibles.get(73)!.type, CollectType.watching.value);
    expect(GStorage.collectChanges, isEmpty);

    await _flags(remoteStatusFollow: true);
    await followTrackerStatus(73, CollectType.watched.value);
    expect(GStorage.collectibles.get(73)!.type, CollectType.watched.value);
    expect(
      GStorage.collectChanges.values.single.origin,
      CollectChangeOrigin.tracker,
    );
  });

  test('writeBackOnSync off enqueues nothing for a received category',
      () async {
    final tracker = FakeTracker(TrackerId.bangumi)
      ..remote = const RemoteEntry(progress: 1, status: TrackStatus.current);
    final original = GStorage.trackingSync;
    final sync = TrackingSync(
      bindings: HiveBindingStore(GStorage.trackingBindings),
      outbox: HiveOutboxStore(GStorage.trackingOutbox),
      trackers: [tracker],
      tokenProvider: (_) async => 'fake-bangumi-token',
      cache: GStorage.trackingEntryCache,
      schedule: (_, _) => () {},
    );
    GStorage.trackingSync = sync;
    addTearDown(() {
      sync.dispose();
      GStorage.trackingSync = original;
    });

    /// A category this device received over WebDAV, and the tracker status it
    /// last recorded for the same subject.
    Future<void> received() async {
      await GStorage.collectibles.put(74, _collect(74, CollectType.watched));
      final binding = TrackingBinding(
        subjectId: 74,
        trackerId: TrackerId.bangumi,
        remoteId: '74',
        total: 12,
        generation: 'device-b',
      );
      await GStorage.trackingBindings.put(binding.key, binding);
      await GStorage.trackingEntryCache.put(
        binding,
        RemoteEntry(
          progress: 1,
          status: TrackStatus.current,
          total: 12,
          updatedAt: DateTime.utc(2020),
        ),
        DateTime.utc(2026),
      );
      await GStorage.appendCollectChange(
        bangumiId: 74,
        action: 2,
        type: CollectType.watched.value,
      );
    }

    await received();
    await _flags(writeBackOnSync: false);
    await enqueueReceivedStatuses();
    await GStorage.trackingSync.drain();
    expect(GStorage.trackingOutbox, isEmpty);
    expect(tracker.calls, isEmpty);

    await GStorage.collectChanges.clear();
    await GStorage.trackingOutbox.clear();
    await received();
    await _flags(writeBackOnSync: true);
    await enqueueReceivedStatuses();
    expect(GStorage.trackingOutbox.containsKey('74:bangumi'), isTrue);
    await GStorage.trackingSync.drain();
    expect(tracker.calls, hasLength(1));
  });
}

Future<void> _flags({
  bool bindingsOnSync = true,
  bool statusMirror = true,
  bool remoteStatusFollow = true,
  bool writeBackOnSync = true,
}) {
  return GStorage.putSetting(TrackingFeatures.flagsKey, <String, bool>{
    'bindingsOnSync': bindingsOnSync,
    'statusMirror': statusMirror,
    'remoteStatusFollow': remoteStatusFollow,
    'writeBackOnSync': writeBackOnSync,
  });
}

BangumiItem _item(int id) => BangumiItem.fromJson({
      'id': id,
      'name': 'show $id',
      'images': <String, String>{},
      'rating': {'rank': 0, 'score': 0, 'total': 0, 'count': <int>[]},
    });

CollectedBangumi _collect(int id, CollectType type) => CollectedBangumi(
      BangumiItem(
        id: id,
        type: 2,
        name: 'subject $id',
        nameCn: '条目 $id',
        summary: '',
        airDate: '2026-01-01',
        airWeekday: 4,
        rank: 0,
        images: const {
          'large': '',
          'common': '',
          'medium': '',
          'small': '',
          'grid': '',
        },
        tags: const <BangumiTag>[],
        alias: const [],
        ratingScore: 0,
        votes: 0,
        votesCount: const [],
        info: '',
      ),
      DateTime.utc(2026),
      type.value,
    );

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}
