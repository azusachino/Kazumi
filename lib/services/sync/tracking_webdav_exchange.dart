import 'dart:io';

import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/modules/collect/collect_sync_merger.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/collect/collect_type_mapper.dart';
import 'package:kazumi/modules/tracking/tracking_sync_file.dart';
import 'package:kazumi/modules/tracking/tracking_sync_merger.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/tracking/models.dart';
import 'package:kazumi/services/tracking/tracker.dart';

/// Fork only: the WebDAV tracking exchange and the collect-side hooks around
/// it, kept out of the upstream `webdav.dart` so that file stays a transport.

/// Where the tracking file lives on the WebDAV server.
const String trackingFilePath = '$_trackingDirectoryPath/tracking.json';
const String _trackingDirectoryPath = '/kazumiSync';

/// Uploads a local file to a remote path through a temporary copy.
typedef RemoteFilePublisher = Future<void> Function({
  required String sourceFilePath,
  required String destinationPath,
  required String temporaryPath,
});

/// The four WebDAV operations the exchange actually uses.
abstract interface class TrackingWebDavTransport {
  /// A name listing of one remote directory.
  Future<List<String>> listNames(String directoryPath);

  /// Copies one remote file to [localPath].
  Future<void> download(String remotePath, String localPath);

  /// The publish operation, named rather than forwarded.
  RemoteFilePublisher get publish;

  /// A fresh scratch directory, once the transport is ready to transfer.
  Future<Directory> createScratchDirectory();
}

class TrackingWebDavExchange {
  TrackingWebDavExchange(this.transport);

  final TrackingWebDavTransport transport;

  Future<void> sync() async {
    final runDirectory = await transport.createScratchDirectory();
    try {
      final names = await transport.listNames(_trackingDirectoryPath);
      var remote = const TrackingSyncFile();
      if (names.contains('tracking.json')) {
        final download = File('${runDirectory.path}/remote.json');
        await transport.download(trackingFilePath, download.path);
        remote = TrackingSyncFile.decode(await download.readAsString());
      }
      final merged = TrackingSyncMerger.merge(_localTrackingFile(), remote);
      await _applyTrackingFile(merged);
      final upload = File('${runDirectory.path}/tracking.json');
      await upload.writeAsString(merged.encode(), flush: true);
      await transport.publish(
        sourceFilePath: upload.path,
        destinationPath: trackingFilePath,
        temporaryPath: '$trackingFilePath.cache',
      );
    } finally {
      try {
        await runDirectory.delete(recursive: true);
      } catch (e) {
        KazumiLogger().w('WebDav: failed to clean tracking sync files', error: e);
      }
    }
  }

  /// A category that arrived over WebDAV reaches Bangumi only when the owner
  /// changed it after the tracker's own last edit. A tracker-origin change
  /// never echoes back, AniList is never a target, and a pending row already
  /// owes a write.
  Future<void> enqueueReceivedStatuses() async {
    try {
      final changes = GStorage.collectChanges.values.toList();
      final cache = GStorage.trackingEntryCache;
      for (final binding in GStorage.trackingBindings.values) {
        if (binding.trackerId != TrackerId.bangumi) continue;
        if (GStorage.trackingOutbox.containsKey(binding.key)) continue;
        final status = CollectType.fromValue(
          GStorage.collectibles.get(binding.subjectId)?.type ??
              CollectType.none.value,
        ).toTrackStatus();
        if (status == null) continue;
        final recorded = cache.get(binding)?.entry;
        // Nothing to compare against, or nothing to write back.
        if (recorded == null || recorded.status == status) continue;
        final trackerAt = recorded.updatedAt;
        if (trackerAt == null) continue;
        final winner = CollectSyncMerger.winnerFor(binding.subjectId, changes);
        if (winner == null ||
            winner.origin != CollectChangeOrigin.user ||
            winner.action == 3) {
          continue;
        }
        final changedAt = DateTime.fromMillisecondsSinceEpoch(
          winner.timestamp * 1000,
          isUtc: true,
        );
        if (!changedAt.isAfter(trackerAt)) continue;
        await GStorage.trackingSync.enqueue(
          binding.subjectId,
          status: status,
          trackerId: TrackerId.bangumi,
        );
      }
    } catch (e) {
      // A tracker write must never fail the collect sync.
      KazumiLogger().e(
        'WebDav: failed to enqueue a received status',
        error: e,
      );
    }
  }

  Future<void> ensureCollectedBangumiBindings() async {
    try {
      await GStorage.bangumiBindingManager.ensureBangumiBindings(
        GStorage.collectibles.values
            .where((item) => CollectType.fromValue(item.type).isCollected)
            .map((item) => item.bangumiItem),
      );
    } catch (e) {
      KazumiLogger().e('WebDav: failed to backfill tracking bindings', error: e);
    }
  }

  TrackingSyncFile _localTrackingFile() {
    final bindings = GStorage.trackingBindings.values
        .where((binding) => binding.trackerId == TrackerId.anilist)
        .map((binding) => TrackingSyncBinding(
              subjectId: binding.subjectId,
              remoteId: binding.remoteId,
              title: binding.title,
              cover: binding.cover,
              total: binding.total,
              episodeOffset: binding.episodeOffset,
              statusLocked: binding.statusLocked,
              score: binding.score,
              updatedAt: binding.updatedAt,
            ))
        .toList();
    final tombstones = GStorage.trackingTombstones.keys
        .whereType<String>()
        .where((key) => key.endsWith(':anilist'))
        .map((key) => TrackingTombstone(
              key: key,
              deletedAt: GStorage.trackingTombstones.get(key) ?? 0,
            ))
        .toList();
    final excluded = GStorage.getStringListSettingByName(
      SettingsKeys.bangumiExcludedSubjectIds.name,
    ).map(int.tryParse).whereType<int>().toList();
    return TrackingSyncFile(
      bindings: bindings,
      tombstones: tombstones,
      bangumiExcluded: excluded,
    );
  }

  Future<void> _applyTrackingFile(TrackingSyncFile file) async {
    final excluded = file.bangumiExcluded.map((id) => '$id').toList();
    await GStorage.putStringListSettingByName(
      SettingsKeys.bangumiExcludedSubjectIds.name,
      excluded,
    );
    for (final id in file.bangumiExcluded) {
      if (GStorage.trackingBindings.containsKey('$id:bangumi')) {
        await GStorage.bangumiBindingManager.stopTracking(id);
      }
    }

    for (final binding in file.bindings) {
      final key = binding.key;
      final local = GStorage.trackingBindings.get(key);
      if (local == null || !_sameSyncedBinding(local, binding)) {
        await GStorage.trackingTombstones.delete(key);
        await GStorage.trackingBindings.put(
          key,
          TrackingBinding(
            subjectId: binding.subjectId,
            trackerId: TrackerId.anilist,
            remoteId: binding.remoteId,
            episodeOffset: binding.episodeOffset,
            statusLocked: binding.statusLocked,
            score: binding.score,
            title: binding.title,
            cover: binding.cover,
            total: binding.total,
            updatedAt: binding.updatedAt,
          ),
        );
      } else if (GStorage.trackingTombstones.containsKey(key)) {
        await GStorage.trackingTombstones.delete(key);
      }
    }
    for (final tombstone in file.tombstones) {
      await GStorage.trackingTombstones.put(
        tombstone.key,
        tombstone.deletedAt,
      );
      await GStorage.trackingBindings.delete(tombstone.key);
    }
  }

  bool _sameSyncedBinding(
    TrackingBinding local,
    TrackingSyncBinding remote,
  ) =>
      local.subjectId == remote.subjectId &&
      local.trackerId == TrackerId.anilist &&
      local.remoteId == remote.remoteId &&
      local.title == remote.title &&
      local.cover == remote.cover &&
      local.total == remote.total &&
      local.episodeOffset == remote.episodeOffset &&
      local.statusLocked == remote.statusLocked &&
      local.score == remote.score &&
      local.updatedAt == remote.updatedAt;
}
