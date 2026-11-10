import 'package:hive_ce/hive.dart';

part 'tracker.g.dart';

@HiveType(typeId: 11)
enum TrackerId {
  @HiveField(0)
  bangumi,
  @HiveField(1)
  anilist,
}

@HiveType(typeId: 12)
enum TrackStatus {
  @HiveField(0)
  planning,
  @HiveField(1)
  current,
  @HiveField(2)
  completed,
  @HiveField(3)
  paused,
  @HiveField(4)
  dropped,
}

class TrackerUser {
  const TrackerUser({required this.id, required this.name});
  final String id;
  final String name;
}

class TrackerSearchResult {
  const TrackerSearchResult({
    required this.id,
    required this.title,
    this.cover,
  });
  final String id;
  final String title;
  final String? cover;
}

class RemoteEntry {
  const RemoteEntry({
    required this.progress,
    required this.status,
    this.score,
    this.total,
  });
  final int progress;
  final TrackStatus status;
  final int? score;
  final int? total;
}

abstract interface class Tracker {
  TrackerId get id;
  Future<TrackerUser> viewer(String token);
  Future<List<TrackerSearchResult>> search(String query, {String? token});
  Future<RemoteEntry?> readEntry(String token, String remoteId);
  Future<int> save(
    String token,
    String remoteId, {
    int? progress,
    TrackStatus? status,
    int? score,
  });
}

sealed class TrackerException implements Exception {
  const TrackerException();
}

final class TrackerAuthException extends TrackerException {
  const TrackerAuthException();
}

final class TrackerRateLimitedException extends TrackerException {
  const TrackerRateLimitedException([this.retryAfter]);
  final Duration? retryAfter;
}

final class TrackerServerException extends TrackerException {
  const TrackerServerException();
}

final class TrackerRequestException extends TrackerException {
  const TrackerRequestException([this.message = 'Request rejected']);
  final String message;
}

final class TrackerNetworkException extends TrackerException {
  const TrackerNetworkException();
}
