import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/tracking/tracker.dart';

/// Fork only: converting between a tracker [TrackStatus] and the local
/// [CollectType] a library row stores.

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

/// Converting a local [CollectType] to the tracker status it describes.
extension CollectTypeTrackStatusMapper on CollectType {
  /// Converts this local type to the equivalent tracker status, or null when
  /// the subject is not collected at all.
  TrackStatus? toTrackStatus() {
    return switch (this) {
      CollectType.planToWatch => TrackStatus.planning,
      CollectType.watching => TrackStatus.current,
      CollectType.watched => TrackStatus.completed,
      CollectType.onHold => TrackStatus.paused,
      CollectType.abandoned => TrackStatus.dropped,
      CollectType.none => null,
    };
  }
}
