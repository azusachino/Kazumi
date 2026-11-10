import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/deep_links/kazumi_deep_link.dart';
import 'package:kazumi/services/tracking/anilist_account.dart';
import 'package:kazumi/services/tracking/anilist_tracker.dart';
import 'package:kazumi/services/tracking/tracker.dart';

import 'bangumi_tracker_test.dart' show FakeAdapter;

void main() {
  late Directory dir;
  late Box<dynamic> settings;
  late DateTime now;
  late AniListAccount account;
  var status = 200;
  var signedIn = 0;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('anilist-account');
    Hive.init(dir.path);
    settings = await Hive.openBox<dynamic>('settings');
    now = DateTime.utc(2026);
    status = 200;
    signedIn = 0;
    final adapter = FakeAdapter(
      (_) => (
        status: status,
        headers: null,
        body: {
          'data': {
            'Viewer': {
              'id': 1,
              'name': 'alice',
              'mediaListOptions': {'scoreFormat': 'POINT_100'},
            },
          },
        },
      ),
    );
    account = AniListAccount(
      settings: settings,
      tracker: AniListTracker(adapter: adapter),
      clock: () => now,
      clientId: 'client',
      onSignIn: () async {
        signedIn++;
      },
    );
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('pasted token is validated before storage', () async {
    status = 401;
    await expectLater(
      account.signInWithToken('bad'),
      throwsA(isA<TrackerAuthException>()),
    );
    expect(await account.validToken(), isNull);
    status = 200;
    await account.signInWithToken(' secret ');
    expect(await account.validToken(), 'secret');
    expect(account.username, 'alice');
    expect(account.scoreFormat, 'POINT_100');
    expect(signedIn, 1);
    await account.signOut();
    expect(await account.validToken(), isNull);
  });
  test('redirect checks host, fragment, expiry, and single use', () async {
    final uri = Uri.parse(
      'kazumi://anilist-auth#access_token=secret&expires_in=60',
    );
    expect(KazumiDeepLink.parse(uri), isA<AniListAuthDeepLink>());
    expect(account.buildAuthorizeUrl().queryParameters, {
      'client_id': 'client',
      'response_type': 'token',
    });
    await expectLater(
      account.handleRedirect(
        Uri.parse('kazumi://wrong#access_token=secret&expires_in=60'),
      ),
      throwsFormatException,
    );
    await expectLater(
      account.handleRedirect(Uri.parse('kazumi://anilist-auth#expires_in=60')),
      throwsFormatException,
    );
    await account.handleRedirect(uri);
    await expectLater(account.handleRedirect(uri), throwsFormatException);
    now = now.add(const Duration(seconds: 60));
    await expectLater(
      account.validToken(),
      throwsA(isA<TrackerAuthException>()),
    );
    account.buildAuthorizeUrl();
    now = now.add(const Duration(minutes: 11));
    await expectLater(account.handleRedirect(uri), throwsFormatException);
  });
  test('configured redirect is used and rejects the default scheme', () async {
    final custom = AniListAccount(
      settings: settings,
      tracker: account.tracker,
      clock: () => now,
      clientId: 'client',
      redirectUri: 'hana://anilist-auth',
    );
    expect(
      custom.buildAuthorizeUrl().queryParameters.containsKey('redirect_uri'),
      isFalse,
    );
    await expectLater(
      custom.handleRedirect(
        Uri.parse('kazumi://anilist-auth#access_token=secret&expires_in=60'),
      ),
      throwsFormatException,
    );
    await custom.handleRedirect(
      Uri.parse('hana://anilist-auth#access_token=secret&expires_in=60'),
    );
  });

  test('OAuth disabled without client id', () {
    final noClient = AniListAccount(
      settings: settings,
      tracker: account.tracker,
      clientId: '',
    );
    expect(noClient.isOAuthAvailable, false);
    expect(noClient.buildAuthorizeUrl, throwsStateError);
  });
}
