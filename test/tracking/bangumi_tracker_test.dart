import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/tracking/bangumi_tracker.dart';
import 'package:kazumi/services/tracking/tracker.dart';

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handle);
  final ({int status, Object? body, Map<String, List<String>>? headers})
  Function(RequestOptions)
  handle;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final result = handle(options);
    return ResponseBody.fromString(
      jsonEncode(result.body),
      result.status,
      headers: {
        'content-type': ['application/json'],
        ...?result.headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> episode(
  int id,
  double sort,
  bool watched, {
  int type = 0,
}) => {
  'type': watched ? 2 : 0,
  'episode': {'id': id, 'sort': sort, 'type': type},
};

void main() {
  test('imports paginated anime collections from the official host', () async {
    final adapter = FakeAdapter((request) {
      final offset = request.queryParameters['offset'] as int;
      return (status: 200, headers: null, body: {
        'total': 2,
        'data': [{
          'subject_id': offset + 1,
          'type': 3,
          'updated_at': '2026-01-01T00:00:00Z',
          'subject': {'id': offset + 1},
        }],
      });
    });
    final tracker = BangumiTracker(adapter: adapter);
    final entries = await tracker.collections('secret', 'alice');
    expect(entries.map((entry) => entry.bangumiId), [1, 2]);
    for (final request in adapter.requests) {
      expect(request.uri.host, 'api.bgm.tv');
      expect(request.headers['Authorization'], 'Bearer secret');
      expect(request.queryParameters['subject_type'], 2);
    }
  });

  test('rating uses the official host and bearer token', () async {
    final adapter = FakeAdapter((_) => (status: 200, body: {}, headers: null));
    final tracker = BangumiTracker(adapter: adapter);
    await tracker.updateCollection('secret', 123, {'type': 3, 'rate': 8});
    final request = adapter.requests.single;
    expect(request.uri.toString(), 'https://api.bgm.tv/v0/users/-/collections/123');
    expect(request.headers['Authorization'], 'Bearer secret');
    expect(request.data, {'type': 3, 'rate': 8});
  });

  const statuses = {
    1: TrackStatus.planning,
    2: TrackStatus.completed,
    3: TrackStatus.current,
    4: TrackStatus.paused,
    5: TrackStatus.dropped,
  };
  for (final mapping in statuses.entries) {
    test('maps status ${mapping.key} in both directions and score', () async {
      Map<String, dynamic>? posted;
      final adapter = FakeAdapter((request) {
        if (request.path.endsWith('/me')) {
          return (
            status: 200,
            body: {'id': 42, 'username': 'alice'},
            headers: null,
          );
        }
        if (request.method == 'POST') {
          posted = request.data as Map<String, dynamic>;
          return (status: 200, body: {}, headers: null);
        }
        if (request.path.endsWith('/episodes')) {
          return (status: 200, body: {'total': 0, 'data': []}, headers: null);
        }
        return (
          status: 200,
          body: {
            'type': mapping.key,
            'rate': 7,
            'subject': {'eps': 12},
          },
          headers: null,
        );
      });
      final tracker = BangumiTracker(adapter: adapter);
      final entry = await tracker.readEntry('secret', '123');
      expect(entry!.status, mapping.value);
      expect(entry.score, 70);
      expect(entry.total, 12);
      await tracker.save('secret', '123', status: mapping.value, score: 76);
      expect(posted, {'type': mapping.key, 'rate': 8});
      expect(adapter.requests.where((r) => r.path.endsWith('/me')).length, 1);
      for (final request in adapter.requests) {
        expect(request.uri.scheme, 'https');
        expect(request.uri.host, 'api.bgm.tv');
        expect(request.headers['Authorization'], 'Bearer secret');
        expect(request.followRedirects, false);
        expect(request.connectTimeout, const Duration(seconds: 15));
        expect(request.sendTimeout, const Duration(seconds: 30));
        expect(request.receiveTimeout, const Duration(seconds: 30));
        expect(request.headers['user-agent'], isNotEmpty);
      }
    });
  }

  test('404 is absent and progress creates an entry', () async {
    final requests = <RequestOptions>[];
    final adapter = FakeAdapter((r) {
      requests.add(r);
      if (r.path.endsWith('/me')) {
        return (
          status: 200,
          body: {'id': 1, 'username': 'alice'},
          headers: null,
        );
      }
      if (r.method == 'POST') return (status: 200, body: {}, headers: null);
      if (r.path.endsWith('/episodes')) {
        return (status: 200, body: {'total': 0, 'data': []}, headers: null);
      }
      return (status: 404, body: {}, headers: null);
    });
    final tracker = BangumiTracker(adapter: adapter);
    expect(await tracker.readEntry('token', '1'), isNull);
    expect(await tracker.save('token', '1', progress: 1), 0);
    expect(requests.singleWhere((r) => r.method == 'POST').data, {'type': 3});
  });

  test(
    'paginates, counts watched and only marks unwatched first episodes',
    () async {
      final all = [
        episode(3, 3, false),
        episode(1, 1, true),
        episode(4, 4, true),
        episode(2, 2, false),
        episode(9, 0, true, type: 1),
      ];
      final adapter = FakeAdapter((r) {
        if (r.path.endsWith('/me')) {
          return (
            status: 200,
            body: {'id': 1, 'username': 'alice'},
            headers: null,
          );
        }
        if (r.method == 'PUT') return (status: 200, body: {}, headers: null);
        if (r.path.endsWith('/episodes')) {
          final offset = r.queryParameters['offset'] as int;
          final page = offset == 0 ? all.sublist(0, 2) : all.sublist(2);
          return (
            status: 200,
            body: {'total': all.length, 'data': page},
            headers: null,
          );
        }
        return (status: 200, body: {'type': 3, 'rate': 0}, headers: null);
      });
      final tracker = BangumiTracker(adapter: adapter);
      final entry = await tracker.readEntry('token', '1');
      expect(entry!.progress, 2);
      expect(entry.score, isNull);
      expect(await tracker.save('token', '1', progress: 3), 4);
      final puts = adapter.requests.where((r) => r.method == 'PUT').toList();
      expect(puts.map((r) => r.uri.path).toList(), [
        '/v0/users/-/collections/-/episodes/2',
        '/v0/users/-/collections/-/episodes/3',
      ]);
      expect(puts.every((r) => (r.data as Map)['type'] == 2), isTrue);
      expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
      expect(
        adapter.requests.where(
          (r) =>
              r.path.endsWith('/episodes') && r.queryParameters['offset'] == 2,
        ),
        isNotEmpty,
      );
    },
  );

  test('no writes when progress is already watched', () async {
    final adapter = FakeAdapter((r) {
      if (r.path.endsWith('/me')) {
        return (
          status: 200,
          body: {'id': 1, 'username': 'alice'},
          headers: null,
        );
      }
      if (r.path.endsWith('/episodes')) {
        return (
          status: 200,
          body: {
            'total': 2,
            'data': [episode(1, 1, true), episode(2, 2, true)],
          },
          headers: null,
        );
      }
      return (status: 200, body: {'type': 3, 'rate': 0}, headers: null);
    });
    expect(
      await BangumiTracker(adapter: adapter).save('token', '1', progress: 1),
      2,
    );
    expect(adapter.requests.where((r) => r.method != 'GET'), isEmpty);
  });

  test('maps connection and timeout failures to network errors', () async {
    for (final type in [
      DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
    ]) {
      final adapter = FakeAdapter(
        (r) => throw DioException(requestOptions: r, type: type),
      );
      await expectLater(
        BangumiTracker(adapter: adapter).viewer('token'),
        throwsA(isA<TrackerNetworkException>()),
      );
    }
  });

  test('keeps viewer cache separate for each token', () async {
    final adapter = FakeAdapter((r) {
      if (r.path.endsWith('/me')) {
        final name = r.headers['Authorization'] == 'Bearer first'
            ? 'alice'
            : 'bob';
        return (status: 200, body: {'id': 1, 'username': name}, headers: null);
      }
      return (status: 404, body: {}, headers: null);
    });
    final tracker = BangumiTracker(adapter: adapter);
    await tracker.readEntry('first', '1');
    await tracker.readEntry('second', '1');
    await tracker.readEntry('first', '1');
    expect(adapter.requests.where((r) => r.path.endsWith('/me')).length, 2);
    expect(adapter.requests.last.uri.path, '/v0/users/alice/collections/1');
  });

  for (final code in [401, 403, 429, 500, 400]) {
    test('maps HTTP $code', () async {
      final adapter = FakeAdapter(
        (r) => (
          status: code,
          body: {},
          headers: {
            'retry-after': ['12'],
          },
        ),
      );
      final matcher = switch (code) {
        401 || 403 => isA<TrackerAuthException>(),
        429 => isA<TrackerRateLimitedException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 12),
        ),
        500 => isA<TrackerServerException>(),
        _ => isA<TrackerRequestException>(),
      };
      await expectLater(
        BangumiTracker(adapter: adapter).viewer('token'),
        throwsA(matcher),
      );
    });
  }
}
