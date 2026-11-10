import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_collection.dart';
import 'package:kazumi/modules/bangumi/bangumi_collection_type.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_sync_merger.dart';
import 'package:kazumi/modules/collect/collect_sync_plan.dart';
import 'package:kazumi/modules/collect/collect_type.dart';

void main() {
  group('CollectSyncPlan', () {
    test('keeps WebDAV history-only mode out of collectible sync', () {
      const plan = CollectSyncPlan(
        webDavEnabled: true,
        webDavCollectiblesEnabled: false,
      );

      expect(plan.shouldSyncWebDavCollectibles, isFalse);
      expect(plan.canSync, isFalse);
    });

    test('allows WebDAV-only collectible sync', () {
      const plan = CollectSyncPlan(
        webDavEnabled: true,
        webDavCollectiblesEnabled: true,
      );

      expect(plan.shouldSyncWebDavCollectibles, isTrue);
      expect(plan.canSync, isTrue);
    });

  });

  group('CollectSyncMerger', () {
    test('merges local change log into WebDAV collectibles', () {
      final mergeResult = CollectSyncMerger.mergeWebDav(
        localCollectibles: [
          _collect(1, CollectType.watching, 10),
          _collect(2, CollectType.watched, 20),
          _collect(3, CollectType.abandoned, 30),
        ],
        localChanges: [
          _change(10, 1, 1, CollectType.watching, 10),
          _change(11, 2, 2, CollectType.watched, 20),
          _change(12, 3, 3, CollectType.abandoned, 30),
        ],
        remoteCollectibles: [
          _collect(2, CollectType.planToWatch, 5),
          _collect(3, CollectType.watching, 5),
          _collect(4, CollectType.onHold, 5),
        ],
        remoteChanges: [
          _change(9, 4, 1, CollectType.onHold, 5),
        ],
      );

      expect(_typesById(mergeResult.collectibles), {
        1: CollectType.watching.value,
        2: CollectType.watched.value,
        4: CollectType.onHold.value,
      });
      expect(mergeResult.changes.map((change) => change.id), [9, 10, 11, 12]);
    });

  });

  group('BangumiCollection.fromJson', () {
    test('parses normal JSON correctly', () {
      final collection = BangumiCollection.fromJson({
        'updated_at': '2026-08-30T14:00:00Z',
        'type': 2,
        'subject': {
          'id': 12345,
          'date': '2026-04-01',
          'name': 'Original Name',
          'name_cn': '中文名',
          'short_summary': '这是一部动画',
          'score': 8.5,
          'eps': 24,
          'rank': 42,
          'images': {
            'large': 'https://example.com/large.jpg',
          },
          'tags': [
            {'name': '科幻', 'count': 100},
          ],
        },
      });

      expect(collection.bangumiId, 12345);
      expect(collection.name, 'Original Name');
      expect(collection.nameCn, '中文名');
      expect(collection.shortSummary, '这是一部动画');
      expect(collection.score, 8.5);
      expect(collection.eps, 24);
      expect(collection.rank, 42);
      expect(collection.type, BangumiCollectionType.watched);
      expect(collection.updatedAt, DateTime.parse('2026-08-30T14:00:00Z'));
      expect(collection.images['large'], 'https://example.com/large.jpg');
      expect(collection.tags.length, 1);
    });

    test('handles missing or malformed fields defensively while requiring valid updated_at', () {
      final collection = BangumiCollection.fromJson({
        'updated_at': '2026-08-30T14:00:00Z',
        'type': 1,
        'subject': {
          'id': 999,
          'score': 7, // integer instead of double
          // missing short_summary, eps, rank, images, tags
        },
      });

      expect(collection.bangumiId, 999);
      expect(collection.score, 7.0);
      expect(collection.shortSummary, '');
      expect(collection.eps, 0);
      expect(collection.rank, 0);
      expect(collection.updatedAt, DateTime.parse('2026-08-30T14:00:00Z'));
      expect(collection.images['large'], '');
      expect(collection.tags, isEmpty);
    });

    test('throws FormatException on missing, empty, or invalid updated_at', () {
      expect(
        () => BangumiCollection.fromJson({
          'type': 1,
          'subject': {'id': 999},
        }),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => BangumiCollection.fromJson({
          'updated_at': '',
          'type': 1,
          'subject': {'id': 999},
        }),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => BangumiCollection.fromJson({
          'updated_at': 'invalid-date-string',
          'type': 1,
          'subject': {'id': 999},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('falls back to subject_id when subject.id is missing', () {
      final collection = BangumiCollection.fromJson({
        'updated_at': '2026-08-30T14:00:00Z',
        'subject_id': 888,
        'type': 1,
        'subject': {
          'name': 'Fallback Name',
        },
      });
      expect(collection.bangumiId, 888);
      expect(collection.name, 'Fallback Name');
    });

    test('throws FormatException when subject id is missing or invalid', () {
      expect(
        () => BangumiCollection.fromJson({
          'type': 1,
          'subject': {
            'name': 'No ID',
          },
        }),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => BangumiCollection.fromJson({
          'subject_id': 0,
          'type': 1,
          'subject': {
            'id': 0,
            'name': 'Zero ID',
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

CollectedBangumi _collect(int id, CollectType type, int timestamp) {
  return CollectedBangumi(
    _item(id),
    DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
    type.value,
  );
}

CollectedBangumiChange _change(
  int id,
  int bangumiId,
  int action,
  CollectType type,
  int timestamp,
) {
  return CollectedBangumiChange(
    id,
    bangumiId,
    action,
    type.value,
    timestamp,
  );
}

BangumiItem _item(int id) {
  return BangumiItem(
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
  );
}

Map<int, int> _typesById(List<CollectedBangumi> collectibles) {
  return {
    for (final collectible in collectibles)
      collectible.bangumiItem.id: collectible.type,
  };
}
