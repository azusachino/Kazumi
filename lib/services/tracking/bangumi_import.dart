import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type_mapper.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/services/storage/storage.dart';

import 'bangumi_account.dart';
import 'bangumi_tracker.dart';
import 'tracker.dart';

class BangumiImport {
  BangumiImport(
    this.account,
    this.tracker,
    this.repository, {
    this.recordChange,
    this.ensureBinding,
  });

  final BangumiAccount account;
  final BangumiTracker tracker;
  final ICollectCrudRepository repository;
  final Future<void> Function(int id, int type)? recordChange;
  final Future<void> Function(BangumiItem item)? ensureBinding;

  Future<int> run() async {
    final token = await account.validToken();
    if (token == null) throw const TrackerAuthException();
    final username = account.username.isEmpty
        ? (await tracker.viewer(token)).name
        : account.username;
    final collections = await tracker.collections(token, username);
    var count = 0;
    for (final entry in collections) {
      final type = entry.type.toCollectType();
      if (!type.isCollected) continue;
      final item = entry.toBangumiItem();
      final inserted = await repository.addCollectibleIfMissing(
        item,
        type.value,
      );
      await ensureBinding?.call(item);
      if (!inserted) continue;
      if (recordChange != null) {
        await recordChange!(entry.bangumiId, type.value);
      } else {
        await GStorage.appendCollectChange(
          bangumiId: entry.bangumiId,
          action: 1,
          type: type.value,
        );
      }
      count++;
    }
    return count;
  }
}
