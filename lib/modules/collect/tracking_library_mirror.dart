import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/tracking/tracking_features.dart';
import 'package:kazumi/services/tracking/tracking_storage.dart';

/// Fork only: the library side of a tracker status change.
///
/// The tracking drawer already enqueued one specific tracker, so this must not
/// fan out to every tracker: that would write the other one and could create a
/// binding nobody asked for.
Future<void> mirrorTrackerStatus(
  ICollectCrudRepository repository,
  BangumiItem item,
  int type,
  void Function() reload,
) async {
  if (!TrackingFeatures.statusMirror) return;
  if (type == CollectType.none.value) return;
  final currentType = repository.getCollectType(item.id);
  // An existing row keeps its stored item and timestamp; the category is the
  // only thing a tracker status owns.
  if (!await setCollectTypeIfPresent(item.id, type)) {
    await repository.addCollectible(item, type);
  }
  await GStorage.appendCollectChange(
    bangumiId: item.id,
    action: currentType == 0 ? 1 : 2,
    type: type,
  );
  reload();
}
