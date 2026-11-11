import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/tracking/tracking_sync_file.dart';
import 'package:kazumi/modules/tracking/tracking_sync_merger.dart';

TrackingSyncBinding binding(
  String remoteId,
  int? updatedAt, {
  int subjectId = 1,
}) => TrackingSyncBinding(
  subjectId: subjectId,
  remoteId: remoteId,
  updatedAt: updatedAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(updatedAt),
);

TrackingSyncFile file({
  List<TrackingSyncBinding> bindings = const [],
  List<TrackingTombstone> tombstones = const [],
  List<int> excluded = const [],
}) => TrackingSyncFile(
  bindings: bindings,
  tombstones: tombstones,
  bangumiExcluded: excluded,
);

void main() {
  final cases =
      <
        ({
          String name,
          TrackingSyncFile local,
          TrackingSyncFile remote,
          String? remoteId,
          bool deleted,
        })
      >[
        (
          name: 'keeps the newer local live binding',
          local: file(bindings: [binding('local', 20)]),
          remote: file(bindings: [binding('remote', 10)]),
          remoteId: 'local',
          deleted: false,
        ),
        (
          name: 'takes a newer remote rebind',
          local: file(bindings: [binding('old', 10)]),
          remote: file(bindings: [binding('new', 20)]),
          remoteId: 'new',
          deleted: false,
        ),
        (
          name: 'a newer tombstone beats an older live binding',
          local: file(bindings: [binding('old', 10)]),
          remote: file(
            tombstones: [TrackingTombstone(key: '1:anilist', deletedAt: 20)],
          ),
          remoteId: null,
          deleted: true,
        ),
        (
          name: 'a newer rebind beats an older tombstone',
          local: file(
            tombstones: [TrackingTombstone(key: '1:anilist', deletedAt: 10)],
          ),
          remote: file(bindings: [binding('new', 20)]),
          remoteId: 'new',
          deleted: false,
        ),
        (
          name: 'both absent stays absent',
          local: file(),
          remote: file(),
          remoteId: null,
          deleted: false,
        ),
        (
          name: 'equal timestamps keep local',
          local: file(bindings: [binding('local', 20)]),
          remote: file(bindings: [binding('remote', 20)]),
          remoteId: 'local',
          deleted: false,
        ),
        (
          name: 'null updatedAt sorts before a timestamped live binding',
          local: file(bindings: [binding('old', null)]),
          remote: file(bindings: [binding('new', 1)]),
          remoteId: 'new',
          deleted: false,
        ),
      ];

  for (final testCase in cases) {
    test(testCase.name, () {
      final merged = TrackingSyncMerger.merge(testCase.local, testCase.remote);
      expect(merged.bindings.singleOrNull?.remoteId, testCase.remoteId);
      expect(merged.tombstones.isNotEmpty, testCase.deleted);
    });
  }

  test(
    'tracking file round-trips allowlisted fields and omit sync secrets',
    () {
      final original = file(
        bindings: [
          TrackingSyncBinding(
            subjectId: 7,
            remoteId: '42',
            title: 'Show',
            cover: 'https://example.invalid/cover.jpg',
            total: 12,
            episodeOffset: 2,
            statusLocked: true,
            score: 80,
            updatedAt: DateTime.utc(2026, 11, 11),
          ),
        ],
        tombstones: [TrackingTombstone(key: '9:anilist', deletedAt: 1234)],
        excluded: [1, 2],
      );

      final encoded = original.encode();
      final decoded = TrackingSyncFile.decode(encoded);

      expect(decoded.bindings.single.remoteId, '42');
      expect(decoded.bindings.single.updatedAt, DateTime.utc(2026, 11, 11));
      expect(decoded.tombstones.single.deletedAt, 1234);
      expect(decoded.bangumiExcluded, [1, 2]);
      expect(encoded, isNot(contains('generation')));
      expect(encoded, isNot(contains('lastRemoteProgress')));
      expect(encoded, isNot(contains('lastSyncAt')));
      expect(encoded, isNot(contains('token')));
    },
  );
}
