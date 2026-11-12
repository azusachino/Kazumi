import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/tracking/tracking_features.dart';

/// Fork only: the tracking work that runs after the app is on screen,
/// so `main.dart` keeps one line.
class KazumiTrackingStartup {
  const KazumiTrackingStartup._();

  /// Backfills Bangumi bindings for what this device already collected.
  ///
  /// Skips while signed out and does not rerun on sign-in; the next app start
  /// or a later collection-status/watch event picks the subject up.
  static Future<void> run() async {
    if (!TrackingFeatures.bindingsOnSync) return;
    if (!GStorage.bangumiAccount.isSignedIn) return;
    try {
      await GStorage.bangumiBindingManager.ensureBangumiBindings(
        GStorage.collectibles.values
            .where((item) => CollectType.fromValue(item.type).isCollected)
            .map((item) => item.bangumiItem),
      );
    } catch (e) {
      KazumiLogger()
          .e('Tracking: failed to backfill Bangumi bindings', error: e);
    }
  }
}
