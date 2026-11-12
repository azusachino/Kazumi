import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('kazumi_propagation_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  setUp(() async {
    await GStorage.collectibles.clear();
    await GStorage.collectChanges.clear();
    await GStorage.trackingOutbox.clear();
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  test('a propagated tracker status survives the next WebDAV merge', () async {
    await GStorage.collectibles.put(42, _collect(42, CollectType.watching));

    await GStorage.followTrackerStatus(42, CollectType.watched.value);

    final recorded = GStorage.collectChanges.values.toList();
    expect(recorded, hasLength(1));
    expect(recorded.single.bangumiID, 42);
    expect(recorded.single.action, 2);
    expect(recorded.single.type, CollectType.watched.value);
    expect(recorded.single.origin, CollectChangeOrigin.tracker);

    // The next collectibles sync must not revert the tracked status: the
    // remote box still holds the category this device had before the drain.
    await GStorage.patchCollectibles(
      [_collect(42, CollectType.watching)],
      const [],
    );

    expect(GStorage.collectibles.get(42)!.type, CollectType.watched.value);
    expect(GStorage.trackingOutbox, isEmpty);
  });

  test('a propagation that changes nothing records nothing', () async {
    await GStorage.collectibles.put(43, _collect(43, CollectType.watched));

    await GStorage.followTrackerStatus(43, CollectType.watched.value);

    expect(GStorage.collectChanges, isEmpty);
  });

  test('an id minted twice for different subjects keeps both edits', () async {
    await GStorage.collectibles.put(1, _collect(1, CollectType.watching));
    await GStorage.collectibles.put(2, _collect(2, CollectType.watching));
    final local = await GStorage.appendCollectChange(
      bangumiId: 1,
      action: 2,
      type: CollectType.planToWatch.value,
      timestamp: 100,
    );

    // The other device minted the same id for a different subject.
    await GStorage.patchCollectibles(
      [_collect(2, CollectType.watched)],
      [CollectedBangumiChange(local.id, 2, 2, CollectType.watched.value, 200)],
    );

    expect(GStorage.collectibles.get(1)!.type, CollectType.planToWatch.value);
    expect(GStorage.collectibles.get(2)!.type, CollectType.watched.value);
    expect(
      GStorage.collectChanges.values
          .map((change) => '${change.bangumiID}')
          .toSet(),
      {'1', '2'},
    );
    expect(GStorage.collectChanges.length, 2);
  });

  test('a propagation never touches a subject the owner did not collect',
      () async {
    await GStorage.followTrackerStatus(44, CollectType.watched.value);

    expect(GStorage.collectibles.containsKey(44), isFalse);
    expect(GStorage.collectChanges, isEmpty);
    expect(GStorage.trackingOutbox, isEmpty);
  });
}

CollectedBangumi _collect(int id, CollectType type) {
  return CollectedBangumi(
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
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}
