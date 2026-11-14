import 'package:kazumi/modules/collect/collect_change_merge.dart';
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
    // The fork's merge decision lives in its own file; see its doc comment.
    final (collectibles, changes) = mergeCollectChanges(
      localCollectibles: localCollectibles,
      localChanges: localChanges,
      remoteCollectibles: remoteCollectibles,
      remoteChanges: remoteChanges,
    );
    return CollectiblesMergeResult(
      collectibles: collectibles,
      changes: changes,
    );
  }

  CollectSyncMerger._();
}
