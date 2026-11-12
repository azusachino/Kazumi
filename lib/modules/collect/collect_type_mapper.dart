import 'package:kazumi/modules/bangumi/bangumi_collection_type.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/tracking/tracker.dart';

/// Converting [BangumiCollectionType] to local [CollectType].
extension BangumiCollectionTypeMapper on BangumiCollectionType {
  /// Converts this Bangumi collection type to the equivalent local type.
  CollectType toCollectType() {
    return switch (this) {
      BangumiCollectionType.planToWatch => CollectType.planToWatch,
      BangumiCollectionType.watched => CollectType.watched,
      BangumiCollectionType.watching => CollectType.watching,
      BangumiCollectionType.onHold => CollectType.onHold,
      BangumiCollectionType.abandoned => CollectType.abandoned,
      BangumiCollectionType.unknown => CollectType.none,
    };
  }
}

/// Converting [CollectType] to [BangumiCollectionType].
extension CollectTypeBangumiMapper on CollectType {
  /// Converts this local collection type to the equivalent Bangumi type.
  BangumiCollectionType? toBangumiCollectionType() {
    return switch (this) {
      CollectType.planToWatch => BangumiCollectionType.planToWatch,
      CollectType.watched => BangumiCollectionType.watched,
      CollectType.watching => BangumiCollectionType.watching,
      CollectType.onHold => BangumiCollectionType.onHold,
      CollectType.abandoned => BangumiCollectionType.abandoned,
      CollectType.none => null,
    };
  }
}

/// Converting a tracker [TrackStatus] to the local [CollectType] it describes.
extension TrackStatusCollectTypeMapper on TrackStatus {
  /// Converts this tracker status to the equivalent local type.
  CollectType toCollectType() {
    return switch (this) {
      TrackStatus.planning => CollectType.planToWatch,
      TrackStatus.current => CollectType.watching,
      TrackStatus.completed => CollectType.watched,
      TrackStatus.paused => CollectType.onHold,
      TrackStatus.dropped => CollectType.abandoned,
    };
  }
}
