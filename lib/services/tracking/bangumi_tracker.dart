import 'package:dio/dio.dart';
import 'package:kazumi/modules/bangumi/bangumi_collection.dart';
import 'package:kazumi/modules/comments/comment_item.dart';
import 'package:kazumi/utils/constants.dart' show bangumiHTTPHeader;

import 'tracker.dart';

/// Uses a private Dio without the application's mirror or logging interceptors.
class BangumiTracker implements Tracker {
  BangumiTracker({HttpClientAdapter? adapter})
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
        ),
      ) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  final Dio _dio;
  final Map<String, String> _usernames = {};
  static const _base = 'https://api.bgm.tv';
  static const _pageSize = 100;

  @override
  TrackerId get id => TrackerId.bangumi;

  Future<Response<dynamic>> _request(
    String token,
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? query,
    bool allowNotFound = false,
  }) async {
    try {
      return await _dio.request<dynamic>(
        '$_base$path',
        data: data,
        queryParameters: query,
        options: Options(
          method: method,
          headers: {...bangumiHTTPHeader, 'Authorization': 'Bearer $token'},
          followRedirects: false,
          validateStatus: (status) =>
              status != null &&
              ((status >= 200 && status < 300) ||
                  (allowNotFound && status == 404)),
        ),
      );
    } on DioException catch (error) {
      final code = error.response?.statusCode;
      if (code == 401 || code == 403) throw const TrackerAuthException();
      if (code == 429) {
        final value = error.response?.headers.value('retry-after');
        final seconds = value == null ? null : int.tryParse(value);
        throw TrackerRateLimitedException(
          seconds == null ? null : Duration(seconds: seconds < 0 ? 0 : seconds),
        );
      }
      if (code != null && code >= 500) throw const TrackerServerException();
      if (code != null && code >= 400) {
        throw TrackerRequestException('Bangumi request rejected ($code)');
      }
      if (code != null) {
        throw TrackerRequestException('Bangumi unexpected response ($code)');
      }
      throw const TrackerNetworkException();
    }
  }

  Future<User> currentUser(String token) async {
    final response = await _request(token, 'GET', '/v0/me');
    return User.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  Future<void> updateCollection(String token, int id, Map<String, dynamic> data) async {
    await _request(token, 'POST', _subjectPath('$id'), data: data);
  }

  Future<List<BangumiCollection>> collections(String token, String username) async {
    final result = <BangumiCollection>[];
    var offset = 0;
    while (true) {
      final response = await _request(token, 'GET',
          '/v0/users/${Uri.encodeComponent(username)}/collections',
          query: {'subject_type': 2, 'limit': _pageSize, 'offset': offset});
      final data = response.data as Map<String, dynamic>;
      final page = data['data'] as List<dynamic>;
      result.addAll(page.map((row) => BangumiCollection.fromJson(row as Map)));
      offset += page.length;
      final total = (data['total'] as num).toInt();
      if (offset >= total) break;
      if (page.isEmpty) throw const FormatException('Incomplete Bangumi collections');
    }
    return result;
  }

  @override
  Future<TrackerUser> viewer(String token) async {
    final response = await _request(token, 'GET', '/v0/me');
    final data = response.data as Map<String, dynamic>;
    final username = data['username'] as String;
    _usernames[token] = username;
    return TrackerUser(id: data['id'].toString(), name: username);
  }

  @override
  Future<List<TrackerSearchResult>> search(
    String query, {
    String? token,
  }) async => [];

  String _subjectPath(String remoteId) =>
      '/v0/users/-/collections/${Uri.encodeComponent(remoteId)}';

  Future<List<_Episode>> _episodes(String token, String remoteId) async {
    final episodes = <_Episode>[];
    var offset = 0;
    while (true) {
      final response = await _request(
        token,
        'GET',
        '${_subjectPath(remoteId)}/episodes',
        query: {'episode_type': 0, 'limit': _pageSize, 'offset': offset},
      );
      final data = response.data as Map<String, dynamic>;
      final page = data['data'] as List<dynamic>;
      for (final item in page) {
        final row = item as Map<String, dynamic>;
        final episode = row['episode'] as Map<String, dynamic>;
        if (episode['type'] == 0) {
          episodes.add(
            _Episode(
              (episode['id'] as num).toInt(),
              (episode['sort'] as num).toDouble(),
              row['type'] == 2,
            ),
          );
        }
      }
      offset += page.length;
      final total = (data['total'] as num?)?.toInt();
      if (page.isEmpty ||
          (total != null ? offset >= total : page.length < _pageSize)) {
        break;
      }
    }
    episodes.sort((a, b) {
      final order = a.sort.compareTo(b.sort);
      return order != 0 ? order : a.id.compareTo(b.id);
    });
    return episodes;
  }

  @override
  Future<RemoteEntry?> readEntry(String token, String remoteId) async {
    final username = _usernames[token] ?? (await viewer(token)).name;
    final response = await _request(
      token,
      'GET',
      '/v0/users/${Uri.encodeComponent(username)}/collections/${Uri.encodeComponent(remoteId)}',
      allowNotFound: true,
    );
    if (response.statusCode == 404) return null;
    final data = response.data as Map<String, dynamic>;
    final episodes = await _episodes(token, remoteId);
    final rate = (data['rate'] as num?)?.toInt() ?? 0;
    final subject = data['subject'] as Map<String, dynamic>?;
    return RemoteEntry(
      progress: episodes.where((episode) => episode.watched).length,
      status: _statusFromBangumi((data['type'] as num).toInt()),
      score: rate == 0 ? null : rate * 10,
      total: (subject?['eps'] as num?)?.toInt(),
      updatedAt: DateTime.tryParse((data['updated_at'] as String?) ?? ''),
    );
  }

  @override
  Future<int> save(
    String token,
    String remoteId, {
    int? progress,
    TrackStatus? status,
    int? score,
  }) async {
    RemoteEntry? existing;
    if (status == null && score == null) {
      existing = await readEntry(token, remoteId);
    }
    if (status != null ||
        score != null ||
        (progress != null && existing == null)) {
      final body = <String, dynamic>{
        if (status != null) 'type': _statusToBangumi(status),
        if (status == null && score == null) 'type': 3,
        if (score != null) 'rate': (score / 10).round().clamp(0, 10),
      };
      await _request(token, 'POST', _subjectPath(remoteId), data: body);
    }
    if (progress == null && existing != null) return existing.progress;
    final episodes = await _episodes(token, remoteId);
    var watched = episodes.where((episode) => episode.watched).length;
    if (progress != null) {
      for (final episode in episodes.take(progress.clamp(0, episodes.length))) {
        if (!episode.watched) {
          await _request(
            token,
            'PUT',
            '/v0/users/-/collections/-/episodes/${episode.id}',
            data: {'type': 2},
          );
          watched++;
        }
      }
    }
    return watched;
  }
}

TrackStatus _statusFromBangumi(int type) => switch (type) {
  1 => TrackStatus.planning,
  2 => TrackStatus.completed,
  3 => TrackStatus.current,
  4 => TrackStatus.paused,
  5 => TrackStatus.dropped,
  _ => throw const TrackerRequestException('Unknown Bangumi collection type'),
};

int _statusToBangumi(TrackStatus status) => switch (status) {
  TrackStatus.planning => 1,
  TrackStatus.completed => 2,
  TrackStatus.current => 3,
  TrackStatus.paused => 4,
  TrackStatus.dropped => 5,
};

class _Episode {
  const _Episode(this.id, this.sort, this.watched);
  final int id;
  final double sort;
  final bool watched;
}
