import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/tracking/anilist_tracker.dart';
import 'package:kazumi/services/tracking/tracker.dart';

import 'bangumi_tracker_test.dart' show FakeAdapter;

void main() {
  const statuses = {
    'PLANNING': TrackStatus.planning,
    'CURRENT': TrackStatus.current,
    'COMPLETED': TrackStatus.completed,
    'PAUSED': TrackStatus.paused,
    'DROPPED': TrackStatus.dropped,
    'REPEATING': TrackStatus.current,
  };
  for (final mapping in statuses.entries) {
    test('maps ${mapping.key} and saves only supplied fields', () async {
      final adapter = FakeAdapter((request) {
        final query = (request.data as Map)['query'] as String;
        return (
          status: 200,
          headers: null,
          body: {
            'data': query.startsWith('mutation')
                ? {
                    'SaveMediaListEntry': {'progress': 7},
                  }
                : {
                    'Media': {
                      'episodes': 12,
                      'mediaListEntry': {
                        'status': mapping.key,
                        'progress': 7,
                        'score': 80,
                      },
                    },
                  },
          },
        );
      });
      final tracker = AniListTracker(adapter: adapter);
      final entry = await tracker.readEntry('secret', '42');
      expect(entry!.status, mapping.value);
      expect(entry.score, 80);
      expect(entry.total, 12);
      expect(await tracker.save('secret', '42', status: mapping.value), 7);
      final variables = (adapter.requests.last.data as Map)['variables'] as Map;
      expect(variables, {
        'mediaId': 42,
        'status': mapping.key == 'REPEATING' ? 'CURRENT' : mapping.key,
      });
      for (final request in adapter.requests) {
        expect(request.uri.toString(), 'https://graphql.anilist.co');
        expect(request.headers['Authorization'], 'Bearer secret');
        expect(request.followRedirects, false);
      }
    });
  }
  test('viewer, search, null entry, and raw score', () async {
    final adapter = FakeAdapter((request) {
      final q = (request.data as Map)['query'] as String;
      final data = q.contains('Viewer')
          ? {
              'Viewer': {
                'id': 1,
                'name': 'alice',
                'mediaListOptions': {'scoreFormat': 'POINT_10'},
              },
            }
          : q.contains('Page(')
          ? {
              'Page': {
                'media': [
                  {
                    'id': 9,
                    'title': {'native': null, 'romaji': 'title'},
                    'coverImage': {'medium': 'cover'},
                    'episodes': 12,
                    'format': 'TV',
                    'seasonYear': 2020,
                  },
                ],
              },
            }
          : q.startsWith('mutation')
          ? {
              'SaveMediaListEntry': {'progress': 3},
            }
          : {
              'Media': {'episodes': 12, 'mediaListEntry': null},
            };
      return (status: 200, headers: null, body: {'data': data});
    });
    final tracker = AniListTracker(adapter: adapter);
    expect((await tracker.viewer('secret')).scoreFormat, 'POINT_10');
    final result = (await tracker.search('title')).single;
    expect(result.title, 'title');
    expect(result.episodes, 12);
    expect(adapter.requests[1].headers.containsKey('Authorization'), false);
    expect(await tracker.readEntry('secret', '9'), isNull);
    await tracker.save('secret', '9', score: 87);
    expect((adapter.requests.last.data as Map)['variables'], {
      'mediaId': 9,
      'scoreRaw': 87,
    });
  });
  test('network failures and GraphQL auth types are mapped', () async {
    final offline = FakeAdapter(
      (request) => throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
      ),
    );
    await expectLater(
      AniListTracker(adapter: offline).viewer('secret'),
      throwsA(isA<TrackerNetworkException>()),
    );
    final auth = FakeAdapter(
      (_) => (
        status: 200,
        headers: null,
        body: {
          'errors': [
            {
              'message': 'Not allowed',
              'extensions': {'code': 'UNAUTHENTICATED'},
            },
          ],
        },
      ),
    );
    await expectLater(
      AniListTracker(adapter: auth).viewer('secret'),
      throwsA(isA<TrackerAuthException>()),
    );
  });
  for (final code in [401, 403, 429, 400, 500]) {
    for (final graphql in [false, true]) {
      test('maps ${graphql ? 'GraphQL' : 'HTTP'} $code', () async {
        final adapter = FakeAdapter(
          (_) => (
            status: graphql ? 200 : code,
            headers: {
              'retry-after': ['120'],
            },
            body: graphql
                ? {
                    'errors': [
                      {'status': code},
                    ],
                  }
                : {},
          ),
        );
        final tracker = AniListTracker(adapter: adapter);
        final matcher = code == 401 || code == 403
            ? isA<TrackerAuthException>()
            : code == 429
            ? isA<TrackerRateLimitedException>().having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 120),
              )
            : code == 500
            ? isA<TrackerServerException>()
            : isA<TrackerRequestException>();
        await expectLater(tracker.viewer('secret'), throwsA(matcher));
      });
    }
  }
}
