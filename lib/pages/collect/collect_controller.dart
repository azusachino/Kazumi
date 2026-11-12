import 'package:flutter/material.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/services/logging/logger.dart';

part 'collect_controller.g.dart';

class CollectController = _CollectController with _$CollectController;

abstract class _CollectController with Store {
  _CollectController(this._collectCrudRepository);

  final ICollectCrudRepository _collectCrudRepository;

  @observable
  ObservableList<CollectedBangumi> collectibles =
      ObservableList<CollectedBangumi>();

  void loadCollectibles() {
    collectibles.clear();
    collectibles.addAll(_collectCrudRepository.getAllCollectibles());
  }

  int getCollectType(BangumiItem bangumiItem) {
    return _collectCrudRepository.getCollectType(bangumiItem.id);
  }

  @action
  Future<void> addCollect(BangumiItem bangumiItem, {type = 1}) async {
    if (type == 0) {
      await deleteCollect(bangumiItem);
      return;
    }

    final int currentCollectType = getCollectType(bangumiItem);
    final int collectChangeAction = currentCollectType == 0 ? 1 : 2;

    await _collectCrudRepository.addCollectible(bangumiItem, type);
    await GStorage.appendCollectChange(
      bangumiId: bangumiItem.id,
      action: collectChangeAction,
      type: type,
    );
    loadCollectibles();
    try {
      await GStorage.bangumiBindingManager.statusChanged(
          bangumiItem, CollectType.fromValue(type));
    } catch (_) {
      KazumiLogger().e('Tracking: failed to enqueue collection status');
    }
  }

  /// Mirrors a tracker status into the local library only.
  ///
  /// The tracking drawer already enqueued one specific tracker, so this must
  /// not call [statusChanged]: that would also write the other tracker and
  /// create bindings the owner did not ask for.
  Future<void> addCollectFromTracker(BangumiItem bangumiItem, int type) async {
    if (type == CollectType.none.value) return;
    final currentCollectType = getCollectType(bangumiItem);
    // An existing row keeps its stored item and timestamp; the category is
    // the only thing a tracker status owns.
    if (!await _collectCrudRepository.setCollectType(bangumiItem.id, type)) {
      await _collectCrudRepository.addCollectible(bangumiItem, type);
    }
    await GStorage.appendCollectChange(
      bangumiId: bangumiItem.id,
      action: currentCollectType == 0 ? 1 : 2,
      type: type,
    );
    loadCollectibles();
  }

  /// Follows a status the tracker itself already holds.
  ///
  /// No collect change is recorded and no tracker is written: the remote is
  /// the source, so echoing it back would only loop.
  Future<void> followTrackerStatus(BangumiItem bangumiItem, int type) async {
    if (type == CollectType.none.value) return;
    if (getCollectType(bangumiItem) == type) return;
    await _collectCrudRepository.setCollectType(bangumiItem.id, type);
    loadCollectibles();
  }

  @action
  Future<void> deleteCollect(BangumiItem bangumiItem) async {
    await _collectCrudRepository.deleteCollectible(bangumiItem.id);
    await GStorage.appendCollectChange(
      bangumiId: bangumiItem.id,
      action: 3,
      type: 5,
    );
    loadCollectibles();
  }

  Future<void> updateLocalCollect(BangumiItem bangumiItem) async {
    await _collectCrudRepository.updateCollectible(bangumiItem);
    loadCollectibles();
  }

  void _reportSyncError(String message, ValueChanged<String> onError,
      {Object? error}) {
    if (error != null) {
      KazumiLogger().e(message, error: error);
    }
    onError(message);
  }

  Future<bool> _connectWebDav(ValueChanged<String> onError) async {
    final bool webDavCollectEnable =
        GStorage.getSetting(SettingsKeys.webDavEnableCollect);
    if (!webDavCollectEnable) {
      _reportSyncError('请开启 WebDAV 收藏同步', onError);
      return false;
    }
    if (!WebDav().initialized) {
      _reportSyncError('WebDAV 未连接，请检查配置', onError);
      return false;
    }
    try {
      await WebDav().ping();
    } catch (e) {
      _reportSyncError('WebDAV 连接失败，请检查网络或配置', onError, error: e);
      return false;
    }
    return true;
  }

  Future<bool> syncCollectibles({
    required ValueChanged<String> onError,
  }) async {
    if (!await _connectWebDav(onError)) return false;
    try {
      await WebDav().syncCollectibles();
    } catch (e) {
      _reportSyncError('WebDAV 同步失败，请检查连接', onError, error: e);
      return false;
    }
    loadCollectibles();
    return true;
  }

  Future<void> migrateCollect() async {
    final favorites = _collectCrudRepository.getFavorites();
    if (favorites.isNotEmpty) {
      int count = 0;
      for (BangumiItem bangumiItem in favorites) {
        // Migration must work before Bangumi is initialized.
        final int currentCollectType = getCollectType(bangumiItem);
        final int collectChangeAction = currentCollectType == 0 ? 1 : 2;
        await _collectCrudRepository.addCollectible(bangumiItem, 1);
        await GStorage.appendCollectChange(
          bangumiId: bangumiItem.id,
          action: collectChangeAction,
          type: 1,
        );
        count++;
      }
      await _collectCrudRepository.clearFavorites();
      loadCollectibles();
      KazumiLogger().d(
          'GStorage: detected $count uncategorized favorites, migrated to collectibles');
    }
  }

}
