import 'tracking_sync_file.dart';

class TrackingSyncMerger {
  static TrackingSyncFile merge(
    TrackingSyncFile local,
    TrackingSyncFile remote,
  ) {
    final keys = <String>{
      ...local.bindings.map((binding) => binding.key),
      ...local.tombstones.map((tombstone) => tombstone.key),
      ...remote.bindings.map((binding) => binding.key),
      ...remote.tombstones.map((tombstone) => tombstone.key),
    };
    final bindings = <TrackingSyncBinding>[];
    final tombstones = <TrackingTombstone>[];

    for (final key in keys) {
      final localCandidate = _candidate(local, key);
      final remoteCandidate = _candidate(remote, key);
      final winner = localCandidate == null
          ? remoteCandidate
          : remoteCandidate == null ||
                localCandidate.timestamp >= remoteCandidate.timestamp
          ? localCandidate
          : remoteCandidate;
      if (winner == null) continue;
      if (winner.binding case final binding?) {
        bindings.add(binding);
      } else if (winner.tombstone case final tombstone?) {
        tombstones.add(tombstone);
      }
    }

    final excluded = <int>{...local.bangumiExcluded, ...remote.bangumiExcluded};
    return TrackingSyncFile(
      bindings: bindings,
      tombstones: tombstones,
      bangumiExcluded: excluded.toList()..sort(),
    );
  }

  static _Candidate? _candidate(TrackingSyncFile file, String key) {
    final binding = file.bindings.where((value) => value.key == key);
    final tombstone = file.tombstones.where((value) => value.key == key);
    if (binding.isNotEmpty && tombstone.isNotEmpty) {
      throw ArgumentError('Tracking key has both binding and tombstone: $key');
    }
    if (binding.isNotEmpty) {
      final value = binding.first;
      return _Candidate(
        timestamp: value.updatedAt?.millisecondsSinceEpoch ?? 0,
        binding: value,
      );
    }
    if (tombstone.isNotEmpty) {
      final value = tombstone.first;
      return _Candidate(timestamp: value.deletedAt, tombstone: value);
    }
    return null;
  }

  TrackingSyncMerger._();
}

class _Candidate {
  const _Candidate({required this.timestamp, this.binding, this.tombstone});

  final int timestamp;
  final TrackingSyncBinding? binding;
  final TrackingTombstone? tombstone;
}
