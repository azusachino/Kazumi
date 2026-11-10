import 'package:dio/dio.dart';

import 'tracker.dart';

/// Isolated from the application's mirror and logging interceptors.
class AniListTracker implements Tracker {
  AniListTracker({HttpClientAdapter? adapter})
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: false,
        ),
      ) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  final Dio _dio;
  @override
  TrackerId get id => TrackerId.anilist;

  Never _error(int? code, String? retryAfter) {
    if (code == 401 || code == 403) throw const TrackerAuthException();
    if (code == 429) {
      final seconds = int.tryParse(retryAfter ?? '');
      throw TrackerRateLimitedException(
        seconds == null ? null : Duration(seconds: seconds < 0 ? 0 : seconds),
      );
    }
    if (code != null && code >= 500) throw const TrackerServerException();
    if (code != null) {
      throw const TrackerRequestException('AniList request rejected');
    }
    throw const TrackerNetworkException();
  }

  Future<Map<String, dynamic>> _request(
    String query,
    Map<String, dynamic> variables, {
    String? token,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        'https://graphql.anilist.co',
        data: {'query': query, 'variables': variables},
        options: Options(
          headers: {if (token != null) 'Authorization': 'Bearer $token'},
          followRedirects: false,
        ),
      );
      final body = Map<String, dynamic>.from(response.data as Map);
      final errors = body['errors'] as List<dynamic>?;
      if (errors != null && errors.isNotEmpty) {
        for (final raw in errors) {
          final error = raw as Map;
          final code =
              (error['status'] as num?)?.toInt() ??
              (error['extensions'] is Map
                  ? ((error['extensions'] as Map)['status'] as num?)?.toInt()
                  : null);
          final message = (error['message'] as String? ?? '').toLowerCase();
          final type = error['extensions'] is Map
              ? (((error['extensions'] as Map)['code'] as String?) ?? '')
                    .toLowerCase()
              : '';
          if (code == 401 ||
              code == 403 ||
              message.contains('unauthenticated') ||
              message.contains('unauthorized') ||
              message.contains('invalid token') ||
              type == 'unauthenticated' ||
              type == 'unauthorized' ||
              type == 'forbidden') {
            throw const TrackerAuthException();
          }
          if (code == 429 || code != null && code >= 500) {
            _error(code, response.headers.value('retry-after'));
          }
        }
        throw const TrackerRequestException('AniList GraphQL request rejected');
      }
      return Map<String, dynamic>.from(body['data'] as Map);
    } on DioException catch (error) {
      _error(
        error.response?.statusCode,
        error.response?.headers.value('retry-after'),
      );
    }
  }

  @override
  Future<TrackerUser> viewer(String token) async {
    final data = await _request(
      'query { Viewer { id name mediaListOptions { scoreFormat } } }',
      {},
      token: token,
    );
    final user = data['Viewer'] as Map;
    return TrackerUser(
      id: user['id'].toString(),
      name: user['name'] as String,
      scoreFormat:
          (user['mediaListOptions'] as Map?)?['scoreFormat'] as String?,
    );
  }

  @override
  Future<List<TrackerSearchResult>> search(
    String query, {
    String? token,
  }) async {
    final data = await _request(
      'query (\$search: String) { Page(perPage: 20) { media(search: \$search, type: ANIME) { id title { native romaji english } coverImage { medium } episodes format seasonYear } } }',
      {'search': query},
      token: token,
    );
    final media = (data['Page'] as Map)['media'] as List;
    return media.map((raw) {
      final row = raw as Map;
      final titles = row['title'] as Map;
      final title =
          titles['native'] as String? ??
          titles['romaji'] as String? ??
          titles['english'] as String? ??
          '';
      return TrackerSearchResult(
        id: row['id'].toString(),
        title: title,
        subtitle: titles['romaji'] == title
            ? null
            : titles['romaji'] as String?,
        cover: (row['coverImage'] as Map?)?['medium'] as String?,
        episodes: (row['episodes'] as num?)?.toInt(),
        format: row['format'] as String?,
        seasonYear: (row['seasonYear'] as num?)?.toInt(),
      );
    }).toList();
  }

  @override
  Future<RemoteEntry?> readEntry(String token, String remoteId) async {
    final data = await _request(
      'query (\$id: Int) { Media(id: \$id) { episodes mediaListEntry { progress status score(format: POINT_100) } } }',
      {'id': int.parse(remoteId)},
      token: token,
    );
    final media = data['Media'] as Map;
    final entry = media['mediaListEntry'] as Map?;
    if (entry == null) return null;
    final score = (entry['score'] as num?)?.round();
    return RemoteEntry(
      progress: (entry['progress'] as num?)?.toInt() ?? 0,
      status: _fromStatus(entry['status'] as String),
      score: score == 0 ? null : score,
      total: (media['episodes'] as num?)?.toInt(),
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
    final variables = <String, dynamic>{'mediaId': int.parse(remoteId)};
    if (progress != null) variables['progress'] = progress;
    if (status != null) variables['status'] = _toStatus(status);
    if (score != null) variables['scoreRaw'] = score;
    final data = await _request(
      'mutation (\$mediaId: Int, \$progress: Int, \$status: MediaListStatus, \$scoreRaw: Int) { SaveMediaListEntry(mediaId: \$mediaId, progress: \$progress, status: \$status, scoreRaw: \$scoreRaw) { progress } }',
      variables,
      token: token,
    );
    return ((data['SaveMediaListEntry'] as Map)['progress'] as num).toInt();
  }
}

TrackStatus _fromStatus(String status) => switch (status) {
  'PLANNING' => TrackStatus.planning,
  'CURRENT' || 'REPEATING' => TrackStatus.current,
  'COMPLETED' => TrackStatus.completed,
  'PAUSED' => TrackStatus.paused,
  'DROPPED' => TrackStatus.dropped,
  _ => throw const TrackerRequestException('Unknown AniList status'),
};

String _toStatus(TrackStatus status) => switch (status) {
  TrackStatus.planning => 'PLANNING',
  TrackStatus.current => 'CURRENT',
  TrackStatus.completed => 'COMPLETED',
  TrackStatus.paused => 'PAUSED',
  TrackStatus.dropped => 'DROPPED',
};
