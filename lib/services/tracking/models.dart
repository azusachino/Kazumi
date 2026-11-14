import 'package:hive_ce/hive.dart';
import 'package:uuid/uuid.dart';
import 'tracker.dart';

part 'models.g.dart';

@HiveType(typeId: 9)
class TrackingBinding {
  TrackingBinding({
    required this.subjectId,
    required this.trackerId,
    required this.remoteId,
    this.episodeOffset = 0,
    this.statusLocked = false,
    this.score,
    this.lastRemoteProgress,
    this.lastSyncAt,
    this.title,
    this.cover,
    this.total,
    this.updatedAt,
    String? generation,
  }) : generation = generation ?? const Uuid().v4();
  @HiveField(0)
  final int subjectId;
  @HiveField(1)
  final TrackerId trackerId;
  @HiveField(2)
  final String remoteId;
  @HiveField(3)
  final int episodeOffset;
  @HiveField(4)
  final bool statusLocked;
  @HiveField(5)
  final int? score;
  @HiveField(6)
  final int? lastRemoteProgress;
  @HiveField(7)
  final DateTime? lastSyncAt;
  @HiveField(8)
  final String? title;
  @HiveField(9)
  final String? cover;
  @HiveField(10)
  final int? total;
  @HiveField(11)
  final String generation;
  @HiveField(12)
  final DateTime? updatedAt;

  String get key => '$subjectId:${trackerId.name}';
  TrackingBinding synced(int progress, DateTime at) => TrackingBinding(
    subjectId: subjectId,
    trackerId: trackerId,
    remoteId: remoteId,
    episodeOffset: episodeOffset,
    statusLocked: statusLocked,
    score: score,
    lastRemoteProgress: progress,
    lastSyncAt: at,
    title: title,
    cover: cover,
    total: total,
    generation: generation,
    updatedAt: updatedAt,
  );
}

@HiveType(typeId: 10)
class OutboxEntry {
  const OutboxEntry({
    required this.subjectId,
    required this.trackerId,
    required this.remoteId,
    required this.bindingGeneration,
    this.progress,
    this.status,
    this.score,
    this.attempts = 0,
    this.retryAt,
    this.error,
    this.revision = 0,
  });
  @HiveField(0)
  final int subjectId;
  @HiveField(1)
  final TrackerId trackerId;
  @HiveField(2)
  final String remoteId;
  @HiveField(3)
  final int? progress;
  @HiveField(4)
  final TrackStatus? status;
  @HiveField(5)
  final int? score;
  @HiveField(6)
  final int attempts;
  @HiveField(7)
  final DateTime? retryAt;
  @HiveField(8)
  final String? error;
  @HiveField(9)
  final int revision;
  @HiveField(10)
  final String bindingGeneration;
  String get key => '$subjectId:${trackerId.name}';
}
