import 'dart:convert';

import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/logging/logger.dart';

import 'models.dart';
import 'tracker.dart';

/// A tracker entry read at a point in time.
///
/// A null [entry] is a remembered "no remote entry", which is different from
/// a cache miss: the drawer must not fall back to an older local progress
/// guess just because the tracker has nothing for this subject yet.
class TrackingEntrySnapshot {
  const TrackingEntrySnapshot({required this.entry, required this.fetchedAt});

  static const freshness = Duration(minutes: 5);

  final RemoteEntry? entry;
  final DateTime fetchedAt;

  bool isFresh(DateTime now) =>
      !now.isBefore(fetchedAt) && now.difference(fetchedAt) < freshness;

  Map<String, Object?> toJson() => {
    'entry': entry == null
        ? null
        : {
            'progress': entry!.progress,
            'status': entry!.status.name,
            'score': entry!.score,
            'total': entry!.total,
          },
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
  };

  static TrackingEntrySnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final fetchedAt = raw['fetchedAt'];
    if (fetchedAt is! String) return null;
    final parsedAt = DateTime.tryParse(fetchedAt);
    if (parsedAt == null) return null;
    final rawEntry = raw['entry'];
    RemoteEntry? entry;
    if (rawEntry != null) {
      if (rawEntry is! Map) return null;
      final progress = rawEntry['progress'];
      final statusName = rawEntry['status'];
      final score = rawEntry['score'];
      final total = rawEntry['total'];
      if (progress is! int ||
          statusName is! String ||
          (score != null && score is! int) ||
          (total != null && total is! int)) {
        return null;
      }
      final status = TrackStatus.values.asNameMap()[statusName];
      if (status == null) return null;
      entry = RemoteEntry(
        progress: progress,
        status: status,
        score: score as int?,
        total: total as int?,
      );
    }
    return TrackingEntrySnapshot(entry: entry, fetchedAt: parsedAt);
  }
}

/// Per-device snapshots of the last tracker entries this device read.
///
/// The drawer renders a snapshot synchronously, so a slow Bangumi read no
/// longer blanks the row. Snapshots are keyed by account scope, subject,
/// tracker, remote id and binding generation: switching accounts or rebinding
/// cannot surface another account's or another subject's entry.
///
/// This is deliberately excluded from the WebDAV tracking payload. It is a
/// display cache, not account state.
class TrackingEntryCache {
  TrackingEntryCache({this.accountScope, Box<String>? box}) : _box = box;

  /// Account identity (the tracker username), never a token.
  final String? Function(TrackerId tracker)? accountScope;
  final Box<String>? _box;
  final Map<String, TrackingEntrySnapshot> _memory = {};

  String scopeFor(TrackerId tracker) => accountScope?.call(tracker) ?? '';

  String _key(TrackingBinding binding, String scope) =>
      '$scope\u0000${binding.key}\u0000${binding.remoteId}'
      '\u0000${binding.generation}';

  TrackingEntrySnapshot? get(TrackingBinding binding) {
    final key = _key(binding, scopeFor(binding.trackerId));
    final memo = _memory[key];
    if (memo != null) return memo;
    final raw = _box?.get(key);
    if (raw == null) return null;
    final snapshot = TrackingEntrySnapshot.fromJson(
      _decode(raw),
    );
    if (snapshot == null) {
      // A corrupt row is a miss, not a display error. Drop it so it is not
      // parsed on every open.
      _box?.delete(key).catchError((Object _) {});
      return null;
    }
    _memory[key] = snapshot;
    return snapshot;
  }

  /// Records a read (or a successful write) under [scope], defaulting to the
  /// currently signed-in account.
  ///
  /// Callers that read asynchronously must capture [scopeFor] before awaiting
  /// and pass it here, so a response that arrives after an account switch
  /// cannot populate the new account's row.
  Future<void> put(
    TrackingBinding binding,
    RemoteEntry? entry,
    DateTime fetchedAt, {
    String? scope,
  }) async {
    final key = _key(binding, scope ?? scopeFor(binding.trackerId));
    final snapshot = TrackingEntrySnapshot(entry: entry, fetchedAt: fetchedAt);
    _memory[key] = snapshot;
    final box = _box;
    if (box == null) return;
    try {
      await box.put(key, jsonEncode(snapshot.toJson()));
    } catch (_) {
      // A cache write failure must never turn a successful remote read or
      // write into a retry.
      KazumiLogger().w('Tracking: failed to persist entry cache');
    }
  }

  Future<void> remove(TrackingBinding binding, {String? scope}) async {
    final key = _key(binding, scope ?? scopeFor(binding.trackerId));
    _memory.remove(key);
    try {
      await _box?.delete(key);
    } catch (_) {
      KazumiLogger().w('Tracking: failed to clear entry cache');
    }
  }

  Object? _decode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
}
