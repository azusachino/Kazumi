import 'package:kazumi/services/tracking/oauth_redirect_uris.dart';

sealed class KazumiDeepLink {
  const KazumiDeepLink();

  static KazumiDeepLink? parse(
    Uri uri, {
    String bangumiRedirectUri = defaultBangumiRedirectUri,
    String anilistRedirectUri = defaultAniListRedirectUri,
  }) {
    try {
      if (uri.scheme != 'kazumi') {
        if (_matchesRedirect(uri, bangumiRedirectUri)) {
          return BangumiAuthDeepLink(uri);
        }
        if (_matchesRedirect(uri, anilistRedirectUri)) {
          return AniListAuthDeepLink(uri);
        }
        return null;
      }
      if (uri.host == 'bangumi' && uri.pathSegments.length == 1) {
        final raw = uri.pathSegments.single;
        final id = int.tryParse(raw);
        // Plain digits only: no sign, whitespace or leading zeros.
        if (id != null && id > 0 && '$id' == raw) return BangumiDeepLink(id);
      }
      if (uri.host == 'bangumi-auth') return BangumiAuthDeepLink(uri);
      if (uri.host == 'anilist-auth') return AniListAuthDeepLink(uri);
      if (uri.host == 'search') {
        final query = uri.queryParameters['query']?.trim() ?? '';
        if (query.isNotEmpty) return SearchDeepLink(query);
      }
    } on FormatException {
      // Malformed percent-encoding.
    }
    return null;
  }

  static bool _matchesRedirect(Uri uri, String redirectUri) {
    final redirect = Uri.parse(redirectUri);
    return uri.scheme == redirect.scheme && uri.host == redirect.host;
  }
}

final class BangumiAuthDeepLink extends KazumiDeepLink {
  const BangumiAuthDeepLink(this.uri);
  final Uri uri;
}

final class AniListAuthDeepLink extends KazumiDeepLink {
  const AniListAuthDeepLink(this.uri);
  final Uri uri;
}

final class BangumiDeepLink extends KazumiDeepLink {
  const BangumiDeepLink(this.id);
  final int id;
}

final class SearchDeepLink extends KazumiDeepLink {
  const SearchDeepLink(this.query);
  final String query;
}
