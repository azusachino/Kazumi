import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/storage/settings_keys.dart';

import 'oauth_redirect_uris.dart';
import 'tracker.dart';

class AniListAccount {
  AniListAccount({
    required this.settings,
    required this.tracker,
    this.onSignIn,
    DateTime Function()? clock,
    this.clientId = const String.fromEnvironment('ANILIST_CLIENT_ID'),
    this.redirectUri = defaultAniListRedirectUri,
  }) : clock = clock ?? DateTime.now;

  final Box<dynamic> settings;
  final Tracker tracker;
  final Future<void> Function()? onSignIn;
  final DateTime Function() clock;
  final String clientId;
  final String redirectUri;
  DateTime? _started;
  int _generation = 0;

  bool get isOAuthAvailable => clientId.isNotEmpty;
  bool get isSignedIn => _token.isNotEmpty;
  String get _token =>
      settings.get(SettingsKeys.anilistAccountToken.name, defaultValue: '')
          as String;
  String get username =>
      settings.get(SettingsKeys.anilistAccountUsername.name, defaultValue: '')
          as String;
  String get scoreFormat =>
      settings.get(
            SettingsKeys.anilistAccountScoreFormat.name,
            defaultValue: '',
          )
          as String;

  Uri buildAuthorizeUrl() {
    if (!isOAuthAvailable) throw StateError('AniList OAuth unavailable');
    _started = clock();
    // No redirect_uri: AniList rejects a custom-scheme one on device and
    // falls back to the client's single registered redirect (as Hana and
    // Mihon do). redirectUri is still used to accept the callback.
    return Uri.https('anilist.co', '/api/v2/oauth/authorize', {
      'client_id': clientId,
      'response_type': 'token',
    });
  }

  Future<void> handleRedirect(Uri uri) async {
    final now = clock();
    final started = _started;
    final redirect = Uri.parse(redirectUri);
    if (uri.scheme != redirect.scheme ||
        uri.host != redirect.host ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        started == null ||
        now.isBefore(started) ||
        now.difference(started) > const Duration(minutes: 10)) {
      throw const FormatException('Invalid AniList authorization redirect');
    }
    final fields = Uri.splitQueryString(uri.fragment);
    final token = fields['access_token'] ?? '';
    final seconds = int.tryParse(fields['expires_in'] ?? '');
    if (token.isEmpty || seconds == null || seconds <= 0) {
      throw const FormatException('Invalid AniList authorization redirect');
    }
    _started = null;
    await _signIn(
      token,
      now.add(Duration(seconds: seconds)).millisecondsSinceEpoch,
    );
  }

  /// Tests only: production sign-in goes through OAuth.
  @visibleForTesting
  Future<void> signInWithToken(String pasted) async {
    final token = pasted.trim();
    if (token.isEmpty) throw const TrackerAuthException();
    _started = null;
    await _signIn(token, 0);
  }

  Future<void> _signIn(String token, int expiry) async {
    final generation = ++_generation;
    final user = await tracker.viewer(token);
    if (generation != _generation) return;
    await settings.putAll({
      SettingsKeys.anilistAccountToken.name: token,
      SettingsKeys.anilistAccountExpiry.name: expiry,
      SettingsKeys.anilistAccountUsername.name: user.name,
      SettingsKeys.anilistAccountScoreFormat.name: user.scoreFormat ?? '',
    });
    await onSignIn?.call();
  }

  Future<String?> validToken() async {
    final token = _token;
    if (token.isEmpty) return null;
    final expiry =
        settings.get(SettingsKeys.anilistAccountExpiry.name, defaultValue: 0)
            as int;
    if (expiry != 0 && clock().millisecondsSinceEpoch >= expiry) {
      throw const TrackerAuthException();
    }
    return token;
  }

  Future<void> signOut() async {
    _generation++;
    _started = null;
    await settings.putAll({
      SettingsKeys.anilistAccountToken.name: '',
      SettingsKeys.anilistAccountExpiry.name: 0,
      SettingsKeys.anilistAccountUsername.name: '',
      SettingsKeys.anilistAccountScoreFormat.name: '',
    });
  }
}
