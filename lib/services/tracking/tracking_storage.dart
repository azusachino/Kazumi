import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/tracking/anilist_binding.dart';
import 'package:kazumi/services/tracking/bangumi_binding.dart';
import 'package:kazumi/services/tracking/stores.dart';

/// Fork only: the collect-box writes the tracking features need, kept out of
/// the shared `storage.dart`. Each runs inside `GStorage`'s collect write
/// block, so it serialises with every other collect write.

/// Rewrites only the category of an existing row, keeping its item and
/// timestamp; a subject that is not collected is left alone.
///
/// Returns false when the row is absent, so the caller can insert it.
Future<bool> setCollectTypeIfPresent(int bangumiId, int type) {
  return GStorage.runCollectWriteExclusive(() async {
    try {
      final existing = GStorage.collectibles.get(bangumiId);
      if (existing == null) return false;
      if (existing.type == type) return true;
      existing.type = type;
      await GStorage.collectibles.put(bangumiId, existing);
      await GStorage.collectibles.flush();
      return true;
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'GStorage: set collect type failed. id=$bangumiId, type=$type',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  });
}

/// Follows a status the tracker already holds: the category rewrite and its
/// `tracker`-origin change land in one write block, so the next collectibles
/// merge cannot revert the status the drain just observed.
///
/// No outbox row is created: the remote is the source of this status.
Future<void> followTrackerStatus(int bangumiId, int type) {
  return GStorage.runCollectWriteExclusive(() async {
    final existing = GStorage.collectibles.get(bangumiId);
    if (existing == null || existing.type == type) return;
    existing.type = type;
    await GStorage.collectibles.put(bangumiId, existing);
    await GStorage.collectibles.flush();
    // The same append as appendCollectChange, inside the block already held.
    final change = CollectedBangumiChange(
      GStorage.generateCollectChangeIdLocked(),
      bangumiId,
      2,
      type,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      origin: CollectChangeOrigin.tracker,
    );
    await GStorage.collectChanges.put(change.id, change);
    await GStorage.collectChanges.flush();
  });
}

/// Two devices can mint the same same-second id for different subjects, so the
/// merge keeps both entries: the incoming one moves to a fresh local id when
/// an id is already taken by another subject.
CollectedBangumiChange rekeyCollidingCollectChange(
  CollectedBangumiChange incoming,
) {
  final existing = GStorage.collectChanges.get(incoming.id);
  if (existing == null || existing.bangumiID == incoming.bangumiID) {
    return incoming;
  }
  return CollectedBangumiChange(
    GStorage.generateCollectChangeIdLocked(),
    incoming.bangumiID,
    incoming.action,
    incoming.type,
    incoming.timestamp,
    origin: incoming.origin,
  );
}

/// Builds the fork's binding managers over the boxes and stores `GStorage.init`
/// already opened.
void wireTrackingManagers(BindingStore bindings) {
  GStorage.bangumiBindingManager = BangumiBindingManager(
    GStorage.bangumiAccount,
    bindings,
    GStorage.trackingSync,
    tombstones: GStorage.trackingTombstones,
  );
  GStorage.anilistBindingManager = AniListBindingManager(
    GStorage.anilistAccount,
    bindings,
    GStorage.trackingSync,
    tombstones: GStorage.trackingTombstones,
  );
}
