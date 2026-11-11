import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_review.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/hive_registrar.g.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/tracking/bangumi_binding.dart';
import 'package:kazumi/services/tracking/tracker.dart';
import 'package:kazumi/services/tracking/tracking_sync.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/services/tracking/bangumi_account.dart';
import 'package:kazumi/services/tracking/bangumi_import.dart';
import 'package:kazumi/services/tracking/bangumi_tracker.dart';

import 'bangumi_tracker_test.dart' show FakeAdapter;
import 'tracking_sync_test.dart' show FakeTracker, MemoryBindings, MemoryOutbox;

class MemoryCollect implements ICollectCrudRepository {
  final rows = <int, CollectedBangumi>{};
  @override
  CollectedBangumi? getCollectible(int id) => rows[id];
  @override
  int getCollectType(int id) => rows[id]?.type ?? 0;
  @override
  List<CollectedBangumi> getAllCollectibles() => rows.values.toList();
  @override
  Future<void> addCollectible(BangumiItem item, int type) async {
    rows[item.id] = CollectedBangumi(item, DateTime.now(), type);
  }
  @override
  Future<bool> addCollectibleIfMissing(BangumiItem item, int type) async {
    if (rows.containsKey(item.id)) return false;
    await addCollectible(item, type);
    return true;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FailingUpdateCollect extends MemoryCollect {
  @override
  Future<void> updateCollectible(BangumiItem item) async {
    throw StateError('stop after rating request');
  }
}

void main() {
  test('info rating uses the official authenticated tracker', () async {
    final dir = await Directory.systemTemp.createTemp('kazumi-rating');
    Hive.init(dir.path);
    final settings = await Hive.openBox<dynamic>('settings');
    final adapter = FakeAdapter((request) {
      if (request.path.endsWith('/me')) {
        return (status: 200, headers: null, body: {'id': 1, 'username': 'alice'});
      }
      return (status: 200, headers: null, body: {});
    });
    final tracker = BangumiTracker(adapter: adapter);
    final account = BangumiAccount(settings: settings, tracker: tracker);
    await account.signInWithToken('token');
    GStorage.bangumiAccount = account;
    final controller = InfoController(CollectController(FailingUpdateCollect()));
    controller.bangumiItem = BangumiItem.fromJson({
      'id': 123, 'name': 'show', 'images': <String, String>{},
      'rating': {'rank': 0, 'score': 0, 'total': 0, 'count': <int>[]},
    });
    await expectLater(controller.rateBangumi(
      BangumiReview(score: 8, tags: [], comment: ''), localType: 1), throwsStateError);
    final request = adapter.requests.singleWhere((request) => request.method == 'POST');
    expect(request.uri.toString(), 'https://api.bgm.tv/v0/users/-/collections/123');
    expect(request.headers['Authorization'], 'Bearer token');
    expect((request.data as Map)['rate'], 8);
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('tracker failure leaves the local status and change log intact', () async {
    final dir = await Directory.systemTemp.createTemp('kazumi-status');
    Hive.init(dir.path);
    Hive.registerAdapters();
    final settings = await Hive.openBox<dynamic>('settings');
    GStorage.collectChanges = await Hive.openBox<CollectedBangumiChange>('changes');
    final tracker = FakeTracker(TrackerId.bangumi);
    final account = BangumiAccount(settings: settings, tracker: tracker);
    await account.signInWithToken('token');
    tracker.failure = const TrackerNetworkException();
    final bindings = MemoryBindings();
    final outbox = MemoryOutbox();
    final sync = TrackingSync(bindings: bindings, outbox: outbox,
        trackers: [tracker], tokenProvider: (_) => account.validToken(),
        schedule: (_, _) => () {});
    GStorage.bangumiBindingManager = BangumiBindingManager(
      account,
      bindings,
      sync,
      tombstones: await Hive.openBox<int>('trackingTombstones'),
    );
    final repository = MemoryCollect();
    final item = BangumiItem.fromJson({
      'id': 5, 'name': 'show', 'images': <String, String>{},
      'rating': {'rank': 0, 'score': 0, 'total': 0, 'count': <int>[]},
    });
    await CollectController(repository).addCollect(item, type: 4);
    await sync.drain();
    expect(repository.rows[5]!.type, 4);
    expect(GStorage.collectChanges.values.single.type, 4);
    expect(outbox.rows['5:bangumi']!.status, TrackStatus.completed);
    sync.dispose();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('import ensures collected bindings without changing local status or outbox', () async {
    final dir = await Directory.systemTemp.createTemp('kazumi-import-bindings');
    Hive.init(dir.path);
    final settings = await Hive.openBox<dynamic>('settings');
    final adapter = FakeAdapter((request) {
      if (request.path.endsWith('/me')) {
        return (status: 200, headers: null, body: {'id': 1, 'username': 'alice'});
      }
      return (status: 200, headers: null, body: {
        'total': 3,
        'data': [for (final id in [1, 2, 3]) {
          'subject_id': id, 'type': 3, 'updated_at': '2026-01-01T00:00:00Z',
          'subject': {'id': id, 'name': 'show'},
        }],
      });
    });
    final tracker = BangumiTracker(adapter: adapter);
    final account = BangumiAccount(settings: settings, tracker: tracker);
    await account.signInWithToken('token');
    await settings.put(SettingsKeys.bangumiExcludedSubjectIds.name, ['3']);
    final bindings = MemoryBindings();
    final outbox = MemoryOutbox();
    final sync = TrackingSync(
      bindings: bindings,
      outbox: outbox,
      trackers: [FakeTracker(TrackerId.bangumi)],
      tokenProvider: (_) async => 'token',
      schedule: (_, _) => () {},
    );
    final manager = BangumiBindingManager(
      account,
      bindings,
      sync,
      tombstones: await Hive.openBox<int>('trackingTombstones'),
    );
    final repository = MemoryCollect();
    final original = BangumiItem.fromJson({
      'id': 1, 'type': 2, 'name': 'original', 'images': <String, String>{},
      'rating': {'rank': 0, 'score': 0, 'total': 0, 'count': <int>[]},
    });
    await repository.addCollectible(original, 4);
    final importer = BangumiImport(
      account, tracker, repository,
      recordChange: (_, _) async {},
      ensureBinding: manager.ensureBangumiBinding,
    );

    expect(await importer.run(), 2);
    expect(bindings.rows.keys, {'1:bangumi', '2:bangumi'});
    expect(repository.rows[1]!.type, 4);
    expect(outbox.rows, isEmpty);

    sync.dispose();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('import adds missing entries and preserves existing local status', () async {
    final dir = await Directory.systemTemp.createTemp('kazumi-import');
    Hive.init(dir.path);
    final settings = await Hive.openBox<dynamic>('settings');
    final adapter = FakeAdapter((request) {
      if (request.path.endsWith('/me')) {
        return (status: 200, headers: null, body: {'id': 1, 'username': 'alice'});
      }
      return (status: 200, headers: null, body: {
        'total': 2,
        'data': [for (final id in [1, 2]) {
          'subject_id': id, 'type': 3, 'updated_at': '2026-01-01T00:00:00Z',
          'subject': {'id': id, 'name': 'show'},
        }],
      });
    });
    final tracker = BangumiTracker(adapter: adapter);
    final account = BangumiAccount(settings: settings, tracker: tracker);
    await account.signInWithToken('token');
    final repository = MemoryCollect();
    final original = BangumiItem.fromJson({
      'id': 1, 'type': 2, 'name': 'original', 'images': <String, String>{},
      'rating': {'rank': 0, 'score': 0, 'total': 0, 'count': <int>[]},
    });
    await repository.addCollectible(original, 4);
    final changes = <int>[];
    final importer = BangumiImport(account, tracker, repository,
        recordChange: (id, type) async => changes.add(id));
    expect(await importer.run(), 1);
    expect(repository.rows[1]!.type, 4);
    expect(repository.rows[2]!.type, 1);
    expect(changes, [2]);
    await Hive.close();
    await dir.delete(recursive: true);
  });
}
