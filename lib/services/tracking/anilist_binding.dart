import 'package:kazumi/modules/bangumi/bangumi_item.dart';

import 'anilist_account.dart';
import 'models.dart';
import 'stores.dart';
import 'tracker.dart';
import 'tracking_sync.dart';

class AniListBindingManager {
  AniListBindingManager(this.account, this.bindings, this.sync);
  final AniListAccount account;
  final BindingStore bindings;
  final TrackingSync sync;

  Future<void> bind(
    BangumiItem item,
    TrackerSearchResult result, {
    TrackStatus? initialStatus,
  }) async {
    final key = '${item.id}:${TrackerId.anilist.name}';
    if (await bindings.get(key) != null)
      throw StateError('AniList already bound');
    final token = await account.validToken();
    if (token == null) throw const TrackerAuthException();
    final remote = await account.tracker.readEntry(token, result.id);
    await bindings.put(
      TrackingBinding(
        subjectId: item.id,
        trackerId: TrackerId.anilist,
        remoteId: result.id,
        title: result.title,
        cover: result.cover,
        total: result.episodes,
      ),
    );
    if (remote == null) {
      await sync.enqueue(
        item.id,
        status: initialStatus ?? TrackStatus.planning,
        trackerId: TrackerId.anilist,
      );
    }
  }

  Future<void> unbind(int subjectId) =>
      bindings.delete('$subjectId:${TrackerId.anilist.name}');

  Future<void> rebind(
    BangumiItem item,
    TrackerSearchResult result, {
    TrackStatus? initialStatus,
  }) async {
    await unbind(item.id);
    await bind(item, result, initialStatus: initialStatus);
  }
}
