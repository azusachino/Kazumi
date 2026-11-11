import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';

import 'anilist_account.dart';
import 'models.dart';
import 'stores.dart';
import 'tracker.dart';
import 'tracking_sync.dart';

class AniListBindingManager {
  AniListBindingManager(this.account, this.bindings, this.sync,
      {required this.tombstones, DateTime Function()? clock})
      : clock = clock ?? DateTime.now;
  final AniListAccount account;
  final BindingStore bindings;
  final TrackingSync sync;
  final Box<int> tombstones;
  final DateTime Function() clock;

  Future<void> bind(
    BangumiItem item,
    TrackerSearchResult result, {
    TrackStatus? initialStatus,
  }) async {
    final key = '${item.id}:${TrackerId.anilist.name}';
    if (await bindings.get(key) != null) {
      throw StateError('AniList already bound');
    }
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
        updatedAt: clock(),
      ),
    );
    await tombstones.delete(key);
    if (remote == null) {
      await sync.enqueue(
        item.id,
        status: initialStatus ?? TrackStatus.planning,
        trackerId: TrackerId.anilist,
      );
    }
  }

  Future<void> unbind(int subjectId) async {
    final key = '$subjectId:${TrackerId.anilist.name}';
    await tombstones.put(key, clock().millisecondsSinceEpoch);
    await bindings.delete(key);
  }

  Future<void> rebind(
    BangumiItem item,
    TrackerSearchResult result, {
    TrackStatus? initialStatus,
  }) async {
    await unbind(item.id);
    await bind(item, result, initialStatus: initialStatus);
  }
}
