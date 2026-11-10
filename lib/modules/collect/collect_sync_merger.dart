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

class CollectSyncMerger {
  static CollectiblesMergeResult mergeWebDav({
    required List<CollectedBangumi> localCollectibles,
    required List<CollectedBangumiChange> localChanges,
    required List<CollectedBangumi> remoteCollectibles,
    required List<CollectedBangumiChange> remoteChanges,
  }) {
    final mergedCollectibles =
        remoteCollectibles.map(_copyCollectible).toList();
    final newLocalChanges = localChanges.where((localChange) {
      return !remoteChanges
          .any((remoteChange) => remoteChange.id == localChange.id);
    }).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    for (final change in newLocalChanges) {
      if (change.action == 3) {
        mergedCollectibles
            .removeWhere((item) => item.bangumiItem.id == change.bangumiID);
        continue;
      }

      final localCollectible = _findCollectible(
        localCollectibles,
        change.bangumiID,
      );
      if (localCollectible == null) {
        continue;
      }

      final changedCollectible = CollectedBangumi(
        localCollectible.bangumiItem,
        localCollectible.time,
        change.type,
      );
      final index = mergedCollectibles.indexWhere(
        (item) => item.bangumiItem.id == change.bangumiID,
      );

      if (change.action == 1) {
        if (index == -1) {
          mergedCollectibles.add(changedCollectible);
        } else {
          mergedCollectibles[index] = changedCollectible;
        }
      } else if (change.action == 2 && index != -1) {
        mergedCollectibles[index] = changedCollectible;
      }
    }

    final mergedChanges = <int, CollectedBangumiChange>{
      for (final change in remoteChanges) change.id: change,
      for (final change in newLocalChanges) change.id: change,
    }.values.toList();

    return CollectiblesMergeResult(
      collectibles: mergedCollectibles,
      changes: mergedChanges,
    );
  }

  static CollectedBangumi? _findCollectible(
    List<CollectedBangumi> collectibles,
    int bangumiId,
  ) {
    for (final collectible in collectibles) {
      if (collectible.bangumiItem.id == bangumiId) {
        return collectible;
      }
    }
    return null;
  }

  static CollectedBangumi _copyCollectible(CollectedBangumi collectible) {
    return CollectedBangumi(
      collectible.bangumiItem,
      collectible.time,
      collectible.type,
    );
  }

  CollectSyncMerger._();
}
