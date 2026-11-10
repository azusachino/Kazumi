import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/storage/settings_keys.dart';

import 'oauth_redirect_uris.dart';
import 'tracker.dart';

class BangumiAccount {
  BangumiAccount({
    required this.settings,
    required this.tracker,
    this.onSignIn,
    HttpClientAdapter? adapter,
    DateTime Function()? clock,
    this.clientId = const String.fromEnvironment('BANGUMI_APP_ID'),
    this.clientSecret = const String.fromEnvironment('BANGUMI_APP_SECRET'),
    this.redirectUri = defaultBangumiRedirectUri,
  }) : clock = clock ?? DateTime.now,
       _dio = Dio(
         BaseOptions(
           connectTimeout: const Duration(seconds: 15),
           sendTimeout: const Duration(seconds: 30),
           receiveTimeout: const Duration(seconds: 30),
           followRedirects: false,
         ),
       ) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  final Box<dynamic> settings;
  final Tracker tracker;
  final Future<void> Function()? onSignIn;
  final DateTime Function() clock;
  final String clientId;
  final String clientSecret;
  final String redirectUri;
  final Dio _dio;
  String? _state;
  DateTime? _started;
  Future<String?>? _refreshing;
  int _generation = 0;
  bool get isOAuthAvailable => clientId.isNotEmpty && clientSecret.isNotEmpty;
  bool get isSignedIn => _token.isNotEmpty;
  String get username =>
      settings.get(SettingsKeys.bangumiAccountUsername.name, defaultValue: '')
          as String;
  String get kind =>
      settings.get(SettingsKeys.bangumiAccountKind.name, defaultValue: '')
          as String;
  String get _token =>
      settings.get(SettingsKeys.bangumiAccountToken.name, defaultValue: '')
          as String;

  Future<void> migrate() async {
    if (settings.get(
          SettingsKeys.bangumiAccountMigrated.name,
          defaultValue: false,
        ) ==
        true) {
      return;
    }
    final legacy =
        (settings.get(SettingsKeys.bangumiAccessToken.name, defaultValue: '')
                as String)
            .trim();
    if (_token.isEmpty && legacy.isNotEmpty) {
      await settings.putAll({
        SettingsKeys.bangumiAccountToken.name: legacy,
        SettingsKeys.bangumiAccountKind.name: 'pasted',
      });
    }
    await settings.put(SettingsKeys.bangumiAccountMigrated.name, true);
  }

  Future<void> signInWithToken(String pasted) async {
    final token = pasted.trim();
    if (token.isEmpty) throw const TrackerAuthException();
    final generation = ++_generation;
    final user = await tracker.viewer(token);
    if (_generation != generation) return;
    await _store(token, '', 0, user.name, 'pasted');
    await onSignIn?.call();
  }

  Uri buildAuthorizeUrl() {
    if (!isOAuthAvailable) throw StateError('Bangumi OAuth unavailable');
    final random = Random.secure();
    _state = base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    _started = clock();
    return Uri.https('bgm.tv', '/oauth/authorize', {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'state': _state!,
    });
  }

  Future<void> handleRedirect(Uri uri) async {
    final now = clock();
    final redirect = Uri.parse(redirectUri);
    if (uri.scheme != redirect.scheme ||
        uri.host != redirect.host ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.hasFragment ||
        _state == null ||
        uri.queryParametersAll['state']?.length != 1 ||
        uri.queryParameters['state'] != _state ||
        _started == null ||
        now.isBefore(_started!) ||
        now.difference(_started!) > const Duration(minutes: 10) ||
        uri.queryParametersAll['code']?.length != 1 ||
        (uri.queryParameters['code'] ?? '').isEmpty) {
      throw const FormatException('Invalid Bangumi authorization redirect');
    }
    final code = uri.queryParameters['code']!;
    _state = null;
    _started = null;
    final generation = ++_generation;
    final data = await _exchange({
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
    });
    final token = data['access_token'] as String;
    final user = await tracker.viewer(token);
    if (_generation != generation) return;
    await _store(
      token,
      data['refresh_token'] as String? ?? '',
      _expiry(data),
      user.name,
      'oauth',
    );
    await onSignIn?.call();
  }

  int _expiry(Map<String, dynamic> data) => clock()
      .add(Duration(seconds: (data['expires_in'] as num).toInt()))
      .millisecondsSinceEpoch;

  Future<Map<String, dynamic>> _exchange(Map<String, dynamic> fields) async {
    final response = await _dio.post<dynamic>(
      'https://bgm.tv/oauth/access_token',
      data: {...fields, 'client_id': clientId, 'client_secret': clientSecret},
      options: Options(followRedirects: false),
    );
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<String?> validToken() async {
    final token = _token;
    if (token.isEmpty) return null;
    final expiry =
        settings.get(SettingsKeys.bangumiAccountExpiry.name, defaultValue: 0)
            as int;
    if (kind != 'oauth' ||
        clock().millisecondsSinceEpoch <
            expiry - const Duration(hours: 1).inMilliseconds) {
      return token;
    }
    return _refreshing ??= _refresh(
      token,
      _generation,
    ).whenComplete(() => _refreshing = null);
  }

  Future<String?> _refresh(String token, int generation) async {
    final refresh =
        settings.get(
              SettingsKeys.bangumiAccountRefreshToken.name,
              defaultValue: '',
            )
            as String;
    if (refresh.isEmpty || !isOAuthAvailable) return token;
    try {
      final data = await _exchange({
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
      });
      if (_generation != generation) return _token.isEmpty ? null : _token;
      final next = data['access_token'] as String;
      await _store(
        next,
        data['refresh_token'] as String? ?? refresh,
        _expiry(data),
        username,
        'oauth',
      );
      return next;
    } on DioException catch (error) {
      if (_generation != generation) return _token.isEmpty ? null : _token;
      final status = error.response?.statusCode;
      if (status != null && status >= 400 && status < 500) {
        await signOut();
        return null;
      }
      return token;
    }
  }

  Future<void> _store(
    String token,
    String refresh,
    int expiry,
    String user,
    String sessionKind,
  ) => settings.putAll({
    SettingsKeys.bangumiAccountToken.name: token,
    SettingsKeys.bangumiAccountRefreshToken.name: refresh,
    SettingsKeys.bangumiAccountExpiry.name: expiry,
    SettingsKeys.bangumiAccountUsername.name: user,
    SettingsKeys.bangumiAccountKind.name: sessionKind,
  });

  Future<void> signOut() async {
    _generation++;
    _state = null;
    _started = null;
    await _store('', '', 0, '', '');
  }
}
