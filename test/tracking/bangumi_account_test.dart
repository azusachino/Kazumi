import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/deep_links/kazumi_deep_link.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/tracking/bangumi_account.dart';
import 'package:kazumi/services/tracking/bangumi_tracker.dart';
import 'package:kazumi/services/tracking/tracker.dart';

import 'bangumi_tracker_test.dart' show FakeAdapter;

void main() {
  late Directory dir;
  late Box<dynamic> settings;
  late FakeAdapter adapter;
  late BangumiAccount account;
  late DateTime now;
  var status = 200;
  var offline = false;
  var calls = 0;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('kazumi-account-test');
    Hive.init(dir.path);
    settings = await Hive.openBox<dynamic>('settings');
    now = DateTime.utc(2026);
    status = 200;
    offline = false;
    calls = 0;
    adapter = FakeAdapter((request) {
      if (offline) {
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
        );
      }
      if (request.uri.host == 'api.bgm.tv') {
        return (
          status: status,
          body: {'id': 1, 'username': 'alice'},
          headers: null,
        );
      }
      return (
        status: status,
        body: {
          'access_token': 'oauth-token',
          'refresh_token': 'refresh',
          'expires_in': 7200,
        },
        headers: null,
      );
    });
    account = BangumiAccount(
      settings: settings,
      tracker: BangumiTracker(adapter: adapter),
      adapter: adapter,
      clock: () => now,
      clientId: 'id',
      clientSecret: 'secret',
      onSignIn: () async {
        calls++;
      },
    );
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('pasted token validates before storage', () async {
    await account.signInWithToken(' token ');
    expect(await account.validToken(), 'token');
    expect(account.kind, 'pasted');
    expect(account.username, 'alice');
    expect(calls, 1);
    expect(adapter.requests.single.uri.host, 'api.bgm.tv');
  });
  test('invalid pasted token is not stored', () async {
    status = 401;
    await expectLater(
      account.signInWithToken('bad'),
      throwsA(isA<TrackerAuthException>()),
    );
    expect(await account.validToken(), isNull);
  });
  test('authorization and redirects are bounded and single use', () async {
    final url = account.buildAuthorizeUrl();
    expect(url.host, 'bgm.tv');
    expect(url.path, '/oauth/authorize');
    expect(url.queryParameters['redirect_uri'], 'kazumi://bangumi-auth');
    final state = url.queryParameters['state']!;
    await expectLater(
      account.handleRedirect(
        Uri.parse('kazumi://bangumi-auth?code=x&state=wrong'),
      ),
      throwsFormatException,
    );
    await account.handleRedirect(
      Uri(
        scheme: 'kazumi',
        host: 'bangumi-auth',
        queryParameters: {'code': 'x', 'state': state},
      ),
    );
    expect(await account.validToken(), 'oauth-token');
    expect(account.kind, 'oauth');
    expect(calls, 1);
    await expectLater(
      account.handleRedirect(
        Uri(
          scheme: 'kazumi',
          host: 'bangumi-auth',
          queryParameters: {'code': 'x', 'state': state},
        ),
      ),
      throwsFormatException,
    );
    for (final request in adapter.requests) {
      expect(request.uri.scheme, 'https');
      expect(['bgm.tv', 'api.bgm.tv'], contains(request.uri.host));
      expect(request.followRedirects, false);
    }
    final next = account.buildAuthorizeUrl();
    now = now.add(const Duration(minutes: 11));
    await expectLater(
      account.handleRedirect(
        Uri(
          scheme: 'kazumi',
          host: 'bangumi-auth',
          queryParameters: {
            'code': 'x',
            'state': next.queryParameters['state']!,
          },
        ),
      ),
      throwsFormatException,
    );
  });
  test(
    'refreshes near expiry; network preserves session and 4xx signs out',
    () async {
      final url = account.buildAuthorizeUrl();
      await account.handleRedirect(
        Uri(
          scheme: 'kazumi',
          host: 'bangumi-auth',
          queryParameters: {
            'code': 'x',
            'state': url.queryParameters['state']!,
          },
        ),
      );
      now = now.add(const Duration(minutes: 61));
      offline = true;
      expect(await account.validToken(), 'oauth-token');
      offline = false;
      expect(await account.validToken(), 'oauth-token');
      expect(
        (adapter.requests.last.data as Map)['grant_type'],
        'refresh_token',
      );
      now = now.add(const Duration(minutes: 61));
      status = 400;
      expect(await account.validToken(), isNull);
      expect(account.kind, isEmpty);
    },
  );
  test('migration adopts legacy only once, even after sign out', () async {
    await settings.put(SettingsKeys.bangumiAccessToken.name, 'legacy');
    await account.migrate();
    expect(await account.validToken(), 'legacy');
    await account.signOut();
    await account.migrate();
    expect(await account.validToken(), isNull);
    expect(settings.get(SettingsKeys.bangumiAccessToken.name), 'legacy');
  });
  test('the OAuth deep link is routed with its query intact', () {
    final uri = Uri.parse('kazumi://bangumi-auth?code=abc&state=xyz');
    final link = KazumiDeepLink.parse(uri);
    expect(link, isA<BangumiAuthDeepLink>());
    expect((link as BangumiAuthDeepLink).uri, uri);
  });
  test('OAuth unavailable without credentials', () {
    final other = BangumiAccount(
      settings: settings,
      tracker: BangumiTracker(adapter: adapter),
      clientId: '',
      clientSecret: '',
    );
    expect(other.isOAuthAvailable, false);
    expect(other.buildAuthorizeUrl, throwsStateError);
  });
}
