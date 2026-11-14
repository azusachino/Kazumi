import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Fork only: one flag source for the fork's behaviour.
///
/// Every flag defaults to enabled, so an absent key — and an absent flag —
/// leaves today's behaviour in place. A device can turn one seam off without
/// reverting code, and a bad merge shows up as a flag default instead of a
/// silent behaviour change. Each seam reads its flag with one synchronous call;
/// nothing subscribes.
///
/// The key stays a literal here on purpose: `settings_keys.dart` is edited
/// upstream often.
abstract final class TrackingFeatures {
  /// The single settings entry holding every flag: `{flag: false}` disables.
  static const SettingKey<Map<dynamic, dynamic>> flagsKey =
      SettingKey<Map<dynamic, dynamic>>(
    'trackingFeatureFlags',
    <dynamic, dynamic>{},
    group: SettingGroup.misc,
  );

  /// Binding creation after Bangumi import, WebDAV apply and startup backfill.
  static bool get bindingsOnSync => _enabled('bindingsOnSync');

  /// The drawer's status change writing the local category.
  static bool get statusMirror => _enabled('statusMirror');

  /// The drain writing a Bangumi status into the library.
  static bool get remoteStatusFollow => _enabled('remoteStatusFollow');

  /// A received category enqueuing a Bangumi delta.
  static bool get writeBackOnSync => _enabled('writeBackOnSync');

  static bool _enabled(String flag) =>
      GStorage.getSetting(flagsKey)[flag] != false;
}

/// The Bangumi import's binding creation, gated by [TrackingFeatures.bindingsOnSync].
Future<void> ensureBangumiBindingOnSync(BangumiItem item) async {
  if (!TrackingFeatures.bindingsOnSync) return;
  await GStorage.bangumiBindingManager.ensureBangumiBinding(item);
}
