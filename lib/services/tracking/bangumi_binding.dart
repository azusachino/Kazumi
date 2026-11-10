import 'dart:async';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';

import 'bangumi_account.dart';
import 'models.dart';
import 'stores.dart';
import 'tracker.dart';
import 'tracking_sync.dart';

class BangumiBindingManager {
  BangumiBindingManager(this.account, this.bindings, this.sync);
  final BangumiAccount account;
  final BindingStore bindings;
  final TrackingSync sync;
  Future<void> _queue = Future.value();

  Future<void> ensureBangumiBinding(BangumiItem item) {
    final result = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        if (account.isSignedIn) {
          final key = '${item.id}:${TrackerId.bangumi.name}';
          if (await bindings.get(key) == null) {
            await bindings.put(
              TrackingBinding(
                subjectId: item.id,
                trackerId: TrackerId.bangumi,
                remoteId: '${item.id}',
                title: item.nameCn.isEmpty ? item.name : item.nameCn,
                cover: item.images['medium'],
              ),
            );
          }
        }
        result.complete();
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<void> watched(BangumiItem item, int progress) async {
    await ensureBangumiBinding(item);
    await sync.enqueue(item.id, progress: progress);
  }
}
