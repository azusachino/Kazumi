import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/modules/collect/collect_module.dart';

class CollectiblesMergeResult {
  const CollectiblesMergeResult({
    required this.collectibles,
    required this.changes,
  });

  final List<CollectedBangumi> collectibles;
  final List<CollectedBangumiChange> changes;
}

/// Merges this device's collect log into a WebDAV copy.
///
/// A change is identified by `(id, subject)`, so two devices that minted the
/// same id for different subjects keep both edits. Per subject the winner is
/// the greatest `(timestamp, origin, type)`: an owner action outranks a
/// tracker echo, and a higher category breaks the remaining tie. Both devices
/// therefore pick the same winner whichever side they merge from, so a tie
/// converges instead of oscillating.
class CollectSyncMerger {
  static CollectiblesMergeResult mergeWebDav({
    required List<CollectedBangumi> localCollectibles,
    required List<CollectedBangumiChange> localChanges,
    required List<CollectedBangumi> remoteCollectibles,
    required List<CollectedBangumiChange> remoteChanges,
  }) {
    final mergedCollectibles =
        remoteCollectibles.map(_copyCollectible).toList();
    final localBySubject = {
      for (final collectible in localCollectibles)
        collectible.bangumiItem.id: collectible,
    };

    for (final winner in _winners([
      ...remoteChanges,
      ...localChanges,
    ]).values) {
      final index = mergedCollectibles.indexWhere(
        (item) => item.bangumiItem.id == winner.bangumiID,
      );
      if (winner.action == 3) {
        if (index != -1) mergedCollectibles.removeAt(index);
        continue;
      }
      // Only a local collectible can carry a category this device does not
      // have on the remote side yet.
      final source = localBySubject[winner.bangumiID] ??
          (index == -1 ? null : mergedCollectibles[index]);
      if (source == null) continue;
      final changed = CollectedBangumi(
        source.bangumiItem,
        source.time,
        winner.type,
      );
      if (index == -1) {
        mergedCollectibles.add(changed);
      } else {
        mergedCollectibles[index] = changed;
      }
    }

    final mergedChanges = <String, CollectedBangumiChange>{
      for (final change in remoteChanges) _key(change): change,
      for (final change in localChanges) _key(change): change,
    };

    return CollectiblesMergeResult(
      collectibles: mergedCollectibles,
      changes: mergedChanges.values.toList(),
    );
  }

  /// The winning change per subject.
  static Map<int, CollectedBangumiChange> _winners(
    Iterable<CollectedBangumiChange> changes,
  ) {
    final winners = <int, CollectedBangumiChange>{};
    for (final change in changes) {
      final current = winners[change.bangumiID];
      if (current == null || _compare(change, current) > 0) {
        winners[change.bangumiID] = change;
      }
    }
    return winners;
  }

  static int _compare(CollectedBangumiChange a, CollectedBangumiChange b) {
    final byTime = a.timestamp.compareTo(b.timestamp);
    if (byTime != 0) return byTime;
    final byOrigin = _originRank(a).compareTo(_originRank(b));
    if (byOrigin != 0) return byOrigin;
    return a.type.compareTo(b.type);
  }

  static int _originRank(CollectedBangumiChange change) =>
      change.origin == CollectChangeOrigin.user ? 1 : 0;

  static String _key(CollectedBangumiChange change) =>
      '${change.id}\u0000${change.bangumiID}';

  static CollectedBangumi _copyCollectible(CollectedBangumi collectible) {
    return CollectedBangumi(
      collectible.bangumiItem,
      collectible.time,
      collectible.type,
    );
  }

  CollectSyncMerger._();
}
