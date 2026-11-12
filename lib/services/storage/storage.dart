import 'dart:async';
import 'dart:io';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/hive_registrar.g.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/modules/collect/collect_type_mapper.dart';
import 'package:kazumi/modules/collect/collect_sync_merger.dart';
import 'package:kazumi/modules/search/search_history_module.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/storage/history_storage_coordinator.dart';
import 'package:kazumi/services/download/download_path_migration.dart';
import 'package:kazumi/services/tracking/anilist_account.dart';
import 'package:kazumi/services/tracking/anilist_binding.dart';
import 'package:kazumi/services/tracking/anilist_tracker.dart';
import 'package:kazumi/services/tracking/bangumi_account.dart';
import 'package:kazumi/services/tracking/bangumi_binding.dart';
import 'package:kazumi/services/tracking/bangumi_tracker.dart';
import 'package:kazumi/services/tracking/tracker.dart';
import 'package:kazumi/services/tracking/models.dart';
import 'package:kazumi/services/tracking/stores.dart';
import 'package:kazumi/services/tracking/tracking_entry_cache.dart';
import 'package:kazumi/services/tracking/tracking_sync.dart';

import 'package:kazumi/services/storage/settings_keys.dart';
export 'package:kazumi/services/storage/settings_keys.dart';

class GStorage {
  /// Don't use favorites box, it's replaced by collectibles.
  static late Box<BangumiItem> favorites;
  static late Box<CollectedBangumi> collectibles;
  static late Box<History> histories;
  static late Box<CollectedBangumiChange> collectChanges;
  static late Box<String> shieldList;
  static late final Box<dynamic> _setting;
  static late Box<SearchHistory> searchHistory;
  static late Box<DownloadRecord> downloads;
  static late Box<TrackingBinding> trackingBindings;
  static late Box<int> trackingTombstones;
  static late Box<OutboxEntry> trackingOutbox;
  static late TrackingEntryCache trackingEntryCache;
  static late TrackingSync trackingSync;
  static late BangumiAccount bangumiAccount;
  static late AniListAccount anilistAccount;
  static late AniListBindingManager anilistBindingManager;
  static late BangumiBindingManager bangumiBindingManager;

  /// Hive directory path, initialized during init()
  static String? _hivePath;

  /// Queue to serialize write operations
  static Future<void> _collectChangesWriteQueue = Future.value();

  /// Next ID
  static int _nextCollectChangeId = 0;

  /// Flag to indicate if the next ID has initialized
  static bool _collectChangeIdInitialized = false;

  /// Ensure collect-related write sequentially
  static Future<T> _runCollectChangesWriteExclusive<T>(
    Future<T> Function() action,
  ) {
    final completer = Completer<T>();
    final previousWrite = _collectChangesWriteQueue;

    _collectChangesWriteQueue = (() async {
      try {
        await previousWrite;
      } catch (_) {}

      try {
        completer.complete(await action());
      } catch (e, stackTrace) {
        completer.completeError(e, stackTrace);
      }
    })();

    return completer.future;
  }

  /// init id generator
  static void _initializeNextCollectChangeIdLocked() {
    if (_collectChangeIdInitialized) {
      return;
    }

    var maxExistingId = 0;
    for (final key in collectChanges.keys) {
      if (key is int && key > maxExistingId) {
        maxExistingId = key;
      }
    }

    _nextCollectChangeId = maxExistingId;
    _collectChangeIdInitialized = true;
  }

  /// Generate id for collect change
  static int _generateCollectChangeIdLocked() {
    _initializeNextCollectChangeIdLocked();

    final currentSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Ensure ID is greater than any existing ID, or equal to current timestamp.
    var nextId = _nextCollectChangeId < currentSeconds
        ? currentSeconds
        : _nextCollectChangeId + 1;
    while (collectChanges.containsKey(nextId)) {
      nextId++;
    }
    _nextCollectChangeId = nextId;
    return nextId;
  }

  /// Append a new collect change
  static Future<CollectedBangumiChange> appendCollectChange({
    required int bangumiId,
    required int action,
    required int type,
    int? timestamp,
    int origin = CollectChangeOrigin.user,
  }) {
    return _runCollectChangesWriteExclusive(
      () => _appendCollectChangeLocked(
        bangumiId: bangumiId,
        action: action,
        type: type,
        timestamp: timestamp,
        origin: origin,
      ),
    );
  }

  /// Appends a change inside an already held collect write block.
  static Future<CollectedBangumiChange> _appendCollectChangeLocked({
    required int bangumiId,
    required int action,
    required int type,
    int? timestamp,
    int origin = CollectChangeOrigin.user,
  }) async {
    final change = CollectedBangumiChange(
      _generateCollectChangeIdLocked(),
      bangumiId,
      action,
      type,
      timestamp ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
      origin: origin,
    );
    await collectChanges.put(change.id, change);
    await collectChanges.flush();
    return change;
  }

  /// Update an existing collect change
  static Future<void> putCollectChange(CollectedBangumiChange change) {
    return _runCollectChangesWriteExclusive(() async {
      _initializeNextCollectChangeIdLocked();
      if (change.id > _nextCollectChangeId) {
        _nextCollectChangeId = change.id;
      }
      await collectChanges.put(change.id, change);
      await collectChanges.flush();
    });
  }

  /// Put a collectible using the same write queue
  static Future<void> putCollectible(CollectedBangumi collectible) {
    return _runCollectChangesWriteExclusive(() async {
      await collectibles.put(collectible.bangumiItem.id, collectible);
      await collectibles.flush();
    });
  }

  /// Insert only if no other local write has already added this subject.
  static Future<bool> putCollectibleIfAbsent(CollectedBangumi collectible) {
    return _runCollectChangesWriteExclusive(() async {
      final id = collectible.bangumiItem.id;
      if (collectibles.containsKey(id)) return false;
      await collectibles.put(id, collectible);
      await collectibles.flush();
      return true;
    });
  }

  /// Rewrites only the category of an existing row, keeping its item and
  /// timestamp; a subject that is not collected is left alone.
  static Future<void> setCollectTypeIfPresent(int bangumiId, int type) {
    return _runCollectChangesWriteExclusive(() async {
      final existing = collectibles.get(bangumiId);
      if (existing == null || existing.type == type) return;
      existing.type = type;
      await collectibles.put(bangumiId, existing);
      await collectibles.flush();
    });
  }

  /// Follows a status the tracker already holds: the category rewrite and its
  /// `tracker`-origin change land in one write block, so the next collectibles
  /// merge cannot revert the status the drain just observed.
  ///
  /// No outbox row is created: the remote is the source of this status.
  static Future<void> followTrackerStatus(int bangumiId, int type) {
    return _runCollectChangesWriteExclusive(() async {
      final existing = collectibles.get(bangumiId);
      if (existing == null || existing.type == type) return;
      existing.type = type;
      await collectibles.put(bangumiId, existing);
      await collectibles.flush();
      await _appendCollectChangeLocked(
        bangumiId: bangumiId,
        action: 2,
        type: type,
        origin: CollectChangeOrigin.tracker,
      );
    });
  }

  /// Delete a collectible using the shared collect write queue.
  static Future<void> deleteCollectible(int bangumiId) {
    return _runCollectChangesWriteExclusive(() async {
      await collectibles.delete(bangumiId);
      await collectibles.flush();
    });
  }

  static Future init() async {
    _hivePath = '${(await getApplicationSupportDirectory()).path}/hive';

    Hive.registerAdapters();

    // Open each box with automatic recovery on corruption
    favorites = await _openBoxSafe<BangumiItem>('favorites');
    collectibles = await _openBoxSafe<CollectedBangumi>('collectibles');
    histories = await _openBoxSafe<History>('histories');
    _setting = await _openBoxSafe<dynamic>('setting');
    collectChanges =
        await _openBoxSafe<CollectedBangumiChange>('collectchanges');
    shieldList = await _openBoxSafe<String>('shieldList');
    searchHistory = await _openBoxSafe<SearchHistory>('searchHistory');
    downloads = await _openBoxSafe<DownloadRecord>('downloads');
    trackingBindings = await _openBoxSafe<TrackingBinding>('trackingBindings');
    trackingTombstones = await _openBoxSafe<int>('trackingTombstones');
    trackingOutbox = await _openBoxSafe<OutboxEntry>('trackingOutbox');
    final trackingEntryCacheBox = await _openBoxSafe<String>(
      'trackingEntryCache',
    );
    final tracker = BangumiTracker();
    final anilistTracker = AniListTracker();
    final bindings = HiveBindingStore(trackingBindings);
    bangumiAccount = BangumiAccount(
      settings: _setting,
      tracker: tracker,
      onSignIn: () => trackingSync.retryFailed(TrackerId.bangumi),
    );
    await bangumiAccount.discardPastedTokens();
    anilistAccount = AniListAccount(
      settings: _setting,
      tracker: anilistTracker,
      onSignIn: () => trackingSync.retryFailed(TrackerId.anilist),
    );
    trackingSync = TrackingSync(
      bindings: bindings,
      outbox: HiveOutboxStore(trackingOutbox),
      trackers: [tracker, anilistTracker],
      tokenProvider: (id) => id == TrackerId.bangumi
          ? bangumiAccount.validToken() : anilistAccount.validToken(),
      cache: trackingEntryCache = TrackingEntryCache(
        box: trackingEntryCacheBox,
        accountScope: (id) => id == TrackerId.bangumi
            ? bangumiAccount.username
            : anilistAccount.username,
      ),
      // A status set on bgm.tv or on another device reaches 追番 through the
      // same in-place write, recording a tracker-origin change so the next
      // WebDAV merge keeps it.
      onRemoteStatus: (subjectId, status) =>
          followTrackerStatus(subjectId, status.toCollectType().value),
    );
    bangumiBindingManager = BangumiBindingManager(
      bangumiAccount,
      bindings,
      trackingSync,
      tombstones: trackingTombstones,
    );
    anilistBindingManager = AniListBindingManager(
      anilistAccount,
      bindings,
      trackingSync,
      tombstones: trackingTombstones,
    );
    if (Platform.isIOS) {
      await rebaseIosDownloadPaths(downloads);
    }
  }

  /// Open a Hive box with automatic recovery on corruption.
  /// If the box is corrupted, delete it and create a new empty one.
  static Future<Box<T>> _openBoxSafe<T>(String boxName) async {
    try {
      return await Hive.openBox<T>(boxName);
    } catch (e) {
      KazumiLogger().e(
          'GStorage: Box "$boxName" corrupted, attempting recovery',
          error: e);

      // Delete the corrupted box files
      await _deleteBoxFiles(boxName);

      // Try to open again (will create a new empty box)
      try {
        final box = await Hive.openBox<T>(boxName);
        KazumiLogger()
            .i('GStorage: Box "$boxName" recovered successfully (data lost)');
        return box;
      } catch (e2) {
        KazumiLogger()
            .e('GStorage: Failed to recover box "$boxName"', error: e2);
        rethrow;
      }
    }
  }

  /// Delete Hive box files for a given box name
  static Future<void> _deleteBoxFiles(String boxName) async {
    if (_hivePath == null) return;

    final boxFile = File('$_hivePath/$boxName.hive');
    final lockFile = File('$_hivePath/$boxName.lock');

    try {
      if (await boxFile.exists()) {
        await boxFile.delete();
        KazumiLogger().i('GStorage: Deleted corrupted box file: $boxName.hive');
      }
      if (await lockFile.exists()) {
        await lockFile.delete();
        KazumiLogger().i('GStorage: Deleted lock file: $boxName.lock');
      }
    } catch (e) {
      KazumiLogger()
          .e('GStorage: Failed to delete box files for "$boxName"', error: e);
    }
  }

  static Future<void> backupBox(String boxName, String backupFilePath) async {
    final appDocumentDir = await getApplicationSupportDirectory();
    final hiveBoxFile = File('${appDocumentDir.path}/hive/$boxName.hive');
    if (await hiveBoxFile.exists()) {
      await hiveBoxFile.copy(backupFilePath);
      KazumiLogger().i('GStorage: backup success: $backupFilePath');
    } else {
      KazumiLogger().w('GStorage: Hive box does not exist: $boxName');
    }
  }

  static Future<void> patchHistory(String backupFilePath) async {
    final backupFile = File(backupFilePath);
    final backupContent = await backupFile.readAsBytes();
    final tempBox = await Hive.openBox('tempHistoryBox', bytes: backupContent);
    try {
      final tempBoxItems = tempBox.toMap().entries;
      await HistoryStorageCoordinator().run(() async {
        for (final tempBoxItem in tempBoxItems) {
          final tempHistory = tempBoxItem.value as History;
          tempHistory.entryKind =
              HistoryEntryKind.normalize(tempHistory.entryKind);
          final targetKey = tempHistory.key;
          final existing = histories.get(targetKey);
          if (existing == null ||
              existing.lastWatchTime.isBefore(tempHistory.lastWatchTime)) {
            await histories.put(targetKey, tempHistory);
          }
        }
      });
    } finally {
      await tempBox.close();
    }
  }

  static Future<void> restoreCollectibles(String backupFilePath) async {
    final backupFile = File(backupFilePath);
    final backupContent = await backupFile.readAsBytes();
    final tempBox =
        await Hive.openBox('tempCollectiblesBox', bytes: backupContent);
    final tempBoxItems = tempBox.toMap().entries;
    KazumiLogger().i(
        'WebDav: restoring collectibles. tempCollectiblesBox length ${tempBoxItems.length}');

    await collectibles.clear();
    for (var tempBoxItem in tempBoxItems) {
      await collectibles.put(tempBoxItem.key, tempBoxItem.value);
    }
    await tempBox.close();
  }

  static Future<List<CollectedBangumi>> getCollectiblesFromFile(
      String backupFilePath) async {
    final backupFile = File(backupFilePath);
    final backupContent = await backupFile.readAsBytes();
    final tempBox =
        await Hive.openBox('tempCollectiblesBox', bytes: backupContent);
    final tempBoxItems = tempBox.toMap().entries;
    KazumiLogger().i(
        'WebDav: get collectibles from file. tempCollectiblesBox length ${tempBoxItems.length}');

    final List<CollectedBangumi> collectibles = [];
    for (var tempBoxItem in tempBoxItems) {
      collectibles.add(tempBoxItem.value);
    }
    await tempBox.close();
    return collectibles;
  }

  static Future<List<CollectedBangumiChange>> getCollectChangesFromFile(
      String backupFilePath) async {
    final backupFile = File(backupFilePath);
    final backupContent = await backupFile.readAsBytes();
    final tempBox =
        await Hive.openBox('tempCollectChangesBox', bytes: backupContent);
    final tempBoxItems = tempBox.toMap().entries;
    KazumiLogger().i(
        'WebDav: get collectChanges from file. tempCollectChangesBox length ${tempBoxItems.length}');

    final List<CollectedBangumiChange> collectChanges = [];
    for (var tempBoxItem in tempBoxItems) {
      collectChanges.add(tempBoxItem.value);
    }
    await tempBox.close();
    return collectChanges;
  }

  static Future<void> patchCollectibles(
      List<CollectedBangumi> remoteCollectibles,
      List<CollectedBangumiChange> remoteChanges) async {
    await _runCollectChangesWriteExclusive(() async {
      final mergeResult = CollectSyncMerger.mergeWebDav(
        localCollectibles: collectibles.values.toList(),
        localChanges: collectChanges.values.toList(),
        remoteCollectibles: remoteCollectibles,
        remoteChanges: remoteChanges,
      );

      // Update local storage
      await collectibles.clear();
      for (var collect in mergeResult.collectibles) {
        await collectibles.put(collect.bangumiItem.id, collect);
      }
      await collectibles.flush();

      await collectChanges.clear();
      _collectChangeIdInitialized = false;
      _initializeNextCollectChangeIdLocked();
      for (var change in mergeResult.changes) {
        final existing = collectChanges.get(change.id);
        if (existing != null && existing.bangumiID != change.bangumiID) {
          // Another device minted this id for a different subject: keep both
          // edits by moving the incoming one to a fresh local id.
          change = CollectedBangumiChange(
            _generateCollectChangeIdLocked(),
            change.bangumiID,
            change.action,
            change.type,
            change.timestamp,
            origin: change.origin,
          );
        }
        await collectChanges.put(change.id, change);
      }
      await collectChanges.flush();

      _collectChangeIdInitialized = false;
      _initializeNextCollectChangeIdLocked();
    });
  }

  static T getSetting<T>(
    SettingKey<T> key, {
    SettingContext context = const SettingContext(),
  }) {
    final defaultValue = key.resolveDefault(context);
    final storedValue = _setting.get(key.name);
    if (storedValue is T) {
      return storedValue;
    }
    return defaultValue;
  }

  static Future<void> putSetting<T>(SettingKey<T> key, T value) async {
    await _setting.put(key.name, value);
  }

  static Stream<void> watchSettings(Iterable<SettingKey<Object?>> keys) {
    final names = keys.map((key) => key.name).toSet();
    return _setting.watch().where((event) => names.contains(event.key)).map((_) {});
  }

  static List<String> getStringListSettingByName(
    String key, {
    List<String> defaultValue = const [],
  }) {
    final storedValue = _setting.get(key);
    if (storedValue is List) {
      return storedValue.whereType<String>().toList();
    }
    return defaultValue;
  }

  static Future<void> putStringListSettingByName(
    String key,
    List<String> value,
  ) async {
    await _setting.put(key, value);
  }

  static Future<void> resetSettings(Iterable<SettingKey<Object?>> keys) async {
    await _setting.deleteAll(keys.map((key) => key.name));
    await _setting.flush();
  }

  static Future<void> resetPlayerSettings() async {
    await resetSettings(SettingsKeys.byGroup(SettingGroup.player));
  }

  static Future<void> resetDanmakuSettings() async {
    await resetSettings(SettingsKeys.byGroup(SettingGroup.danmaku));
  }

  GStorage._();
}
