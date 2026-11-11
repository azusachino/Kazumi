import 'dart:async';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/storage/settings_keys.dart';

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

  Future<void> _queued(Future<void> Function() action) {
    final result = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        await action();
        result.complete();
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  List<String> get _excludedSubjectIds {
    final saved = account.settings.get(
      SettingsKeys.bangumiExcludedSubjectIds.name,
      defaultValue: const <String>[],
    );
    return saved is List ? saved.whereType<String>().toList() : <String>[];
  }

  Future<bool> _ensureBinding(BangumiItem item) async {
    final id = '${item.id}';
    if (!account.isSignedIn || _excludedSubjectIds.contains(id)) {
      return false;
    }
    final key = '${item.id}:${TrackerId.bangumi.name}';
    if (await bindings.get(key) != null) {
      return false;
    }
    await bindings.put(
      TrackingBinding(
        subjectId: item.id,
        trackerId: TrackerId.bangumi,
        remoteId: id,
        title: item.name.trim().isEmpty ? item.nameCn : item.name,
        cover: item.images['medium'],
      ),
    );
    return true;
  }

  Future<void> ensureBangumiBinding(BangumiItem item) => _queued(() async {
    await _ensureBinding(item);
  });

  Future<int> ensureBangumiBindings(Iterable<BangumiItem> items) async {
    var created = 0;
    await _queued(() async {
      for (final item in items) {
        if (await _ensureBinding(item)) created++;
      }
    });
    return created;
  }

  Future<void> stopTracking(int subjectId) => _queued(() async {
    final ids = _excludedSubjectIds;
    final id = '$subjectId';
    if (!ids.contains(id)) {
      ids.add(id);
      await account.settings.put(
        SettingsKeys.bangumiExcludedSubjectIds.name,
        ids,
      );
    }
    await bindings.delete('$subjectId:${TrackerId.bangumi.name}');
  });

  Future<void> startTracking(BangumiItem item) => _queued(() async {
    final ids = _excludedSubjectIds..remove('${item.id}');
    await account.settings.put(
      SettingsKeys.bangumiExcludedSubjectIds.name,
      ids,
    );
    await _ensureBinding(item);
  });

  Future<void> statusChanged(BangumiItem item, CollectType type) async {
    final status = switch (type) {
      CollectType.watching => TrackStatus.current,
      CollectType.planToWatch => TrackStatus.planning,
      CollectType.onHold => TrackStatus.paused,
      CollectType.watched => TrackStatus.completed,
      CollectType.abandoned => TrackStatus.dropped,
      CollectType.none => null,
    };
    if (status == null) return;
    await ensureBangumiBinding(item);
    await sync.enqueue(item.id, status: status);
  }

  Future<void> watched(BangumiItem item, int progress) async {
    await ensureBangumiBinding(item);
    await sync.enqueue(item.id, progress: progress);
  }
}
