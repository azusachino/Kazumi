import 'dart:async';
import 'dart:math' as math;

import 'package:kazumi/services/logging/logger.dart';

import 'models.dart';
import 'stores.dart';
import 'tracker.dart';
import 'tracking_entry_cache.dart';

typedef TrackingTimer = void Function();
typedef TrackingSchedule =
    TrackingTimer Function(Duration delay, void Function() callback);

class _BindingChanged implements Exception {}

TrackingTimer _schedule(Duration delay, void Function() callback) {
  final timer = Timer(delay, callback);
  return timer.cancel;
}

class TrackingSync {
  TrackingSync({
    required this.bindings,
    required this.outbox,
    required Iterable<Tracker> trackers,
    required this.tokenProvider,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    TrackingSchedule? schedule,
    this.cache,
    this.onRemoteStatus,
  }) : trackers = {for (final tracker in trackers) tracker.id: tracker},
       clock = clock ?? DateTime.now,
       delay = delay ?? Future<void>.delayed,
       schedule = schedule ?? _schedule;

  final BindingStore bindings;
  final OutboxStore outbox;
  final Map<TrackerId, Tracker> trackers;
  final Future<String?> Function(TrackerId) tokenProvider;
  final DateTime Function() clock;
  final Future<void> Function(Duration) delay;
  final TrackingSchedule schedule;
  final TrackingEntryCache? cache;

  /// Receives the status a successful Bangumi drain left on the tracker, so
  /// the library can follow its canonical source. Bangumi only: an AniList
  /// entry is a manual secondary match and never drives the local category.
  final Future<void> Function(int subjectId, TrackStatus status)?
  onRemoteStatus;
  final Map<TrackerId, DateTime> _lastCall = {};
  final Map<TrackerId, DateTime> _pausedUntil = {};
  Future<void> _queue = Future.value();
  Future<void>? _draining;
  bool _drainAgain = false;
  TrackingTimer? _cancelTimer;
  bool _disposed = false;
  static const _backoff = [
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 10),
    Duration(hours: 1),
  ];

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        result.complete(await action());
      } catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }

  Future<void> enqueue(
    int subjectId, {
    int? progress,
    TrackStatus? status,
    int? score,
    TrackerId? trackerId,
  }) async {
    await _exclusive(() async {
      for (final binding in await bindings.all()) {
        if (binding.subjectId != subjectId ||
            (trackerId != null && binding.trackerId != trackerId)) {
          continue;
        }
        final old = await outbox.get(binding.key);
        final same =
            old?.bindingGeneration == binding.generation &&
            old?.remoteId == binding.remoteId;
        final desired = progress == null
            ? (same ? old?.progress : null)
            : math.max(0, progress + binding.episodeOffset);
        final previous = same ? old?.progress : null;
        await outbox.put(
          OutboxEntry(
            subjectId: subjectId,
            trackerId: binding.trackerId,
            remoteId: binding.remoteId,
            bindingGeneration: binding.generation,
            progress: desired == null
                ? previous
                : previous == null
                ? desired
                : math.max(desired, previous),
            status: status ?? (same ? old?.status : null),
            score: score ?? (same ? old?.score : null),
            revision: (old?.revision ?? 0) + 1,
          ),
        );
      }
    });
    if (_draining != null) _drainAgain = true;
    unawaited(drain());
  }

  Future<void> retryFailed(TrackerId id) async {
    await _exclusive(() async {
      for (final row in await outbox.all()) {
        if (row.trackerId != id) continue;
        await outbox.put(
          OutboxEntry(
            subjectId: row.subjectId,
            trackerId: row.trackerId,
            remoteId: row.remoteId,
            bindingGeneration: row.bindingGeneration,
            progress: row.progress,
            status: row.status,
            score: row.score,
            revision: row.revision + 1,
          ),
        );
      }
    });
    if (_draining != null) _drainAgain = true;
    await drain();
  }

  Future<void> drain() {
    if (_disposed) return Future.value();
    return _draining ??=
        (() async {
          do {
            _drainAgain = false;
            await _runDrain();
          } while (_drainAgain && !_disposed);
        })().whenComplete(() {
          _draining = null;
        });
  }

  Future<void> _runDrain() async {
    final rows = await _exclusive(() => outbox.all());
    await Future.wait(
      trackers.values.map((tracker) async {
        for (final row in rows.where((row) => row.trackerId == tracker.id)) {
          if (_disposed) break;
          final paused = _pausedUntil[tracker.id];
          if (paused != null && paused.isAfter(clock())) break;
          await _process(tracker, row.key);
        }
      }),
    );
    await _armTimer();
  }

  Future<T> _call<T>(TrackerId id, Future<T> Function() action) async {
    final last = _lastCall[id];
    if (last != null) {
      final remaining = last
          .add(const Duration(milliseconds: 500))
          .difference(clock());
      if (remaining > Duration.zero) await delay(remaining);
    }
    _lastCall[id] = clock();
    return action();
  }

  bool _matches(TrackingBinding? binding, OutboxEntry row) =>
      binding != null &&
      binding.generation == row.bindingGeneration &&
      binding.remoteId == row.remoteId;

  Future<void> _dropIfUnchanged(OutboxEntry row) => _exclusive(() async {
    final current = await outbox.get(row.key);
    if (current?.revision == row.revision &&
        current?.bindingGeneration == row.bindingGeneration &&
        current?.remoteId == row.remoteId) {
      await outbox.delete(row.key);
    }
  });

  Future<void> _checkBinding(OutboxEntry row) async {
    if (!_matches(await bindings.get(row.key), row)) throw _BindingChanged();
  }

  Future<void> _process(Tracker tracker, String key) async {
    final row = await _exclusive(() => outbox.get(key));
    if (row == null ||
        row.error != null ||
        (row.retryAt?.isAfter(clock()) ?? false)) {
      return;
    }
    final binding = await bindings.get(key);
    if (!_matches(binding, row)) {
      await _dropIfUnchanged(row);
      return;
    }
    try {
      final token = await tokenProvider(tracker.id);
      if (token == null || token.isEmpty) throw const TrackerAuthException();
      // Captured before the read: a later account switch must not let this
      // response populate the new account's cached row.
      final scope = cache?.scopeFor(tracker.id);
      final remote = await _call(tracker.id, () async {
        await _checkBinding(row);
        return tracker.readEntry(token, row.remoteId);
      });
      final progress = math.max(remote?.progress ?? 0, row.progress ?? 0);
      final total = binding!.total ?? remote?.total;
      TrackStatus? status;
      if (row.status != null) {
        status = row.status;
      } else if (binding.statusLocked) {
        status = null;
      } else if (remote?.status == TrackStatus.completed) {
        status = TrackStatus.completed;
      } else if (total != null && total > 0 && progress >= total) {
        status = TrackStatus.completed;
      } else {
        status = remote == null ? TrackStatus.current : null;
      }
      final progressDelta =
          row.progress != null && progress > (remote?.progress ?? 0)
          ? progress
          : null;
      final statusDelta = status != remote?.status ? status : null;
      final scoreDelta = row.score != null && row.score != remote?.score
          ? row.score
          : null;
      var stored = remote?.progress ?? 0;
      if (progressDelta != null || statusDelta != null || scoreDelta != null) {
        stored = await _call(tracker.id, () async {
          await _checkBinding(row);
          // An already-started request cannot be cancelled by a rebind.
          return tracker.save(
            token,
            row.remoteId,
            progress: progressDelta,
            status: statusDelta,
            score: scoreDelta,
          );
        });
      }
      final effective = RemoteEntry(
        progress: stored,
        status: statusDelta ?? remote?.status ?? status ?? TrackStatus.current,
        score: scoreDelta ?? remote?.score,
        total: total,
        // The tracker's own edit time from this read. A write returns no new
        // one, and inventing one would hide a stale local change.
        updatedAt: remote?.updatedAt,
      );
      await _exclusive(() async {
        final currentBinding = await bindings.get(key);
        if (_matches(currentBinding, row)) {
          // Refresh the drawer's snapshot before the outbox row disappears,
          // so clearing a pending row never reverts the UI to stale state.
          await _remember(currentBinding!, effective, clock(), scope);
          await bindings.put(currentBinding.synced(stored, clock()));
        }
        final current = await outbox.get(key);
        if (current?.revision == row.revision &&
            current?.bindingGeneration == row.bindingGeneration &&
            current?.remoteId == row.remoteId) {
          await outbox.delete(key);
        }
      });
      await _propagate(tracker.id, row.subjectId, effective.status);
    } on _BindingChanged {
      await _dropIfUnchanged(row);
    } on TrackerException catch (e) {
      await _handleFailure(tracker.id, row, e);
    } catch (_) {
      // Exception text and stack traces may contain credentials or headers.
      KazumiLogger().e('Tracking: unexpected ${tracker.id.name} sync error');
      await _handleFailure(tracker.id, row, const TrackerServerException());
    }
  }

  Future<void> _propagate(
    TrackerId id,
    int subjectId,
    TrackStatus status,
  ) async {
    final callback = onRemoteStatus;
    if (callback == null || id != TrackerId.bangumi) return;
    try {
      // A queued local edit is never reverted by a remote read.
      final pending = await _exclusive(
        () async => (await outbox.all()).any((row) => row.subjectId == subjectId),
      );
      if (!pending) await callback(subjectId, status);
    } catch (_) {
      // A library write must never fail the drain.
      KazumiLogger().w('Tracking: failed to propagate ${id.name} status');
    }
  }

  Future<void> _remember(
    TrackingBinding binding,
    RemoteEntry? entry,
    DateTime at,
    String? scope,
  ) async {
    final cache = this.cache;
    if (cache == null) return;
    try {
      await cache.put(binding, entry, at, scope: scope);
    } catch (_) {
      // A cache failure must not turn a successful remote write into a retry.
      KazumiLogger().w('Tracking: failed to update entry cache');
    }
  }

  Future<void> _handleFailure(
    TrackerId id,
    OutboxEntry row,
    TrackerException error,
  ) async {
    await _exclusive(() async {
      final now = clock();
      if (error is TrackerRateLimitedException) {
        final wait =
            error.retryAfter != null &&
                error.retryAfter! > const Duration(seconds: 60)
            ? error.retryAfter!
            : const Duration(seconds: 60);
        _pausedUntil[id] = now.add(wait);
      }
      for (final current in await outbox.all()) {
        if (current.trackerId != id ||
            (error is! TrackerAuthException &&
                error is! TrackerRateLimitedException &&
                current.key != row.key)) {
          continue;
        }
        if (current.error != null) continue;
        if (current.key == row.key &&
            (current.revision != row.revision ||
                current.remoteId != row.remoteId ||
                current.bindingGeneration != row.bindingGeneration)) {
          continue;
        }
        final attempts =
            current.attempts +
            (error is TrackerNetworkException || error is TrackerServerException
                ? 1
                : 0);
        DateTime? retryAt;
        String? message;
        if (error is TrackerAuthException) {
          message = 'sign-in expired';
        }
        if (error is TrackerRequestException) {
          message = error.message;
        }
        if (error is TrackerRateLimitedException) {
          retryAt = _pausedUntil[id];
        }
        if (error is TrackerNetworkException ||
            error is TrackerServerException) {
          if (attempts > _backoff.length) {
            message = 'Sync failed after retries';
          } else {
            retryAt = now.add(_backoff[attempts - 1]);
          }
        }
        await outbox.put(
          OutboxEntry(
            subjectId: current.subjectId,
            trackerId: id,
            remoteId: current.remoteId,
            bindingGeneration: current.bindingGeneration,
            progress: current.progress,
            status: current.status,
            score: current.score,
            attempts: attempts,
            retryAt: retryAt,
            error: message,
            revision: current.revision,
          ),
        );
      }
    });
  }

  Future<void> _armTimer() async {
    _cancelTimer?.call();
    if (_disposed) return;
    final rows = await _exclusive(() => outbox.all());
    DateTime? next;
    for (final row in rows) {
      if (row.error != null || !trackers.containsKey(row.trackerId)) continue;
      var at = row.retryAt;
      final paused = _pausedUntil[row.trackerId];
      if (paused != null &&
          paused.isAfter(clock()) &&
          (at == null || paused.isAfter(at))) {
        at = paused;
      }
      if (at != null && (next == null || at.isBefore(next))) next = at;
    }
    if (next != null) {
      final wait = next.difference(clock());
      _cancelTimer = schedule(wait.isNegative ? Duration.zero : wait, () {
        unawaited(drain());
      });
    }
  }

  void dispose() {
    _disposed = true;
    _cancelTimer?.call();
  }
}
