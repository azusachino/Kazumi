import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/clients/bangumi_client.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_relation.dart';
import 'package:kazumi/modules/comments/comment_response.dart';
import 'package:kazumi/modules/characters/characters_response.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/modules/character/character_full_item.dart';
import 'package:kazumi/modules/staff/staff_response.dart';
import 'package:kazumi/utils/search_parser.dart';

class BangumiSearchPage {
  const BangumiSearchPage({
    required this.items,
    required this.rawCount,
  });

  final List<BangumiItem> items;
  final int rawCount;
}

class BangumiApi {
  static final BangumiClient _client = BangumiClient.instance;

  static Future<List<List<BangumiItem>>> getCalendar() async {
    List<List<BangumiItem>> bangumiCalendar = [];
    try {
      final jsonData = await _client.get(
        ApiEndpoints.bangumiAPINextDomain + ApiEndpoints.bangumiCalendar,
      );
      for (int i = 1; i <= 7; i++) {
        List<BangumiItem> bangumiList = [];
        final jsonList = jsonData['$i'];
        for (dynamic jsonItem in jsonList) {
          try {
            BangumiItem bangumiItem = BangumiItem.fromJson(jsonItem['subject']);
            bangumiList.add(bangumiItem);
          } catch (_) {}
        }
        bangumiCalendar.add(bangumiList);
      }
    } catch (e) {
      KazumiLogger().e('Resolve calendar failed', error: e);
    }
    return bangumiCalendar;
  }

  // Official fallback for season switching. Mirror mode uses the cached
  // /kazumi/v1/calendar/season endpoint instead of Bangumi search.
  static Future<List<List<BangumiItem>>> getCalendarBySearch(
      List<String> dateRange, int limit, int offset) async {
    List<BangumiItem> bangumiList = [];
    List<List<BangumiItem>> bangumiCalendar = [];
    var params = <String, dynamic>{
      "keyword": "",
      "sort": "rank",
      "filter": {
        "type": [2],
        "tag": ["日本"],
        "air_date": [">=${dateRange[0]}", "<${dateRange[1]}"],
        "rank": [">0", "<=99999"],
        "nsfw": true
      }
    };
    try {
      final url = ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiRankSearch,
          [limit, offset]);
      final jsonData = await _client.post(
        url,
        data: params,
      );
      final jsonList = jsonData['data'];
      for (dynamic jsonItem in jsonList) {
        if (jsonItem is Map<String, dynamic>) {
          bangumiList.add(BangumiItem.fromJson(jsonItem));
        }
      }
    } catch (e) {
      KazumiLogger().e('Resolve bangumi list failed', error: e);
    }
    try {
      for (int weekday = 1; weekday <= 7; weekday++) {
        List<BangumiItem> bangumiDayList = [];
        for (BangumiItem bangumiItem in bangumiList) {
          if (bangumiItem.airWeekday == weekday) {
            bangumiDayList.add(bangumiItem);
          }
        }
        bangumiCalendar.add(bangumiDayList);
      }
    } catch (e) {
      KazumiLogger()
          .e('Network: fetch bangumi item to calendar failed', error: e);
    }
    return bangumiCalendar;
  }

  static String buildBangumiMirrorSeasonCalendarPath(List<String> dateRange) {
    return Uri(
      path: ApiEndpoints.bangumiMirrorSeasonCalendar,
      queryParameters: {
        'start': dateRange[0],
        'end': dateRange[1],
      },
    ).toString();
  }

  static Future<List<List<BangumiItem>>> getBangumiMirrorSeasonCalendar(
      List<String> dateRange) async {
    List<List<BangumiItem>> bangumiCalendar = [];
    try {
      final jsonData = await _client.get(
        ApiEndpoints.bangumiMirrorDomain +
            buildBangumiMirrorSeasonCalendarPath(dateRange),
      );
      for (int i = 1; i <= 7; i++) {
        List<BangumiItem> bangumiList = [];
        final jsonList = jsonData['$i'] ?? [];
        for (dynamic jsonItem in jsonList) {
          try {
            final subject =
                jsonItem is Map<String, dynamic> ? jsonItem['subject'] : null;
            if (subject is Map<String, dynamic>) {
              bangumiList.add(BangumiItem.fromJson(subject));
            }
          } catch (_) {}
        }
        bangumiCalendar.add(bangumiList);
      }
    } catch (e) {
      KazumiLogger().e('Network: resolve bangumi mirror season calendar failed',
          error: e);
    }
    return bangumiCalendar;
  }

  static Future<List<BangumiItem>> getBangumiList(
      {int rank = 2, String tag = ''}) async {
    List<BangumiItem> bangumiList = [];
    late Map<String, dynamic> params;
    if (tag == '') {
      params = <String, dynamic>{
        'keyword': '',
        'sort': 'rank',
        "filter": {
          "type": [2],
          "tag": ["日本"],
          "rank": [">$rank", "<=1050"],
          "nsfw": false
        },
      };
    } else {
      params = <String, dynamic>{
        'keyword': '',
        'sort': 'rank',
        "filter": {
          "type": [2],
          "tag": [tag],
          "rank": [">$rank", "<=99999"],
          "nsfw": false
        },
      };
    }
    try {
      final jsonData = await _client.post(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiRankSearch,
            [100, 0]),
        data: params,
      );
      final jsonList = jsonData['data'];
      for (dynamic jsonItem in jsonList) {
        if (jsonItem is Map<String, dynamic>) {
          bangumiList.add(BangumiItem.fromJson(jsonItem));
        }
      }
    } catch (e) {
      KazumiLogger().e('Network: resolve bangumi list failed', error: e);
    }
    return bangumiList;
  }

  static Future<List<BangumiItem>> getBangumiTrendsList(
      {int type = 2, int limit = 24, int offset = 0}) async {
    List<BangumiItem> bangumiList = [];
    var params = <String, dynamic>{
      'type': type,
      'limit': limit,
      'offset': offset,
    };
    try {
      final jsonData = await _client.get(
        ApiEndpoints.bangumiAPINextDomain + ApiEndpoints.bangumiTrendsNext,
        queryParameters: params,
      );
      final jsonList = jsonData['data'];
      for (dynamic jsonItem in jsonList) {
        if (jsonItem is Map<String, dynamic>) {
          bangumiList.add(BangumiItem.fromJson(jsonItem['subject']));
        }
      }
    } catch (e) {
      KazumiLogger().e('Network: resolve bangumi trends list failed', error: e);
    }
    return bangumiList;
  }

  static String buildBangumiMirrorPopularPath({
    String tag = '',
    int limit = 24,
    int offset = 0,
  }) {
    return Uri(
      path: ApiEndpoints.bangumiMirrorPopularSubjects,
      queryParameters: {
        if (tag.isNotEmpty) 'tag': tag,
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
    ).toString();
  }

  static Future<List<BangumiItem>> getBangumiMirrorPopularSubjects({
    String tag = '',
    int limit = 24,
    int offset = 0,
  }) async {
    List<BangumiItem> bangumiList = [];
    try {
      final jsonData = await _client.get(
        ApiEndpoints.bangumiMirrorDomain +
            buildBangumiMirrorPopularPath(
              tag: tag,
              limit: limit,
              offset: offset,
            ),
      );
      final jsonList = jsonData is List ? jsonData : jsonData['data'];
      for (dynamic jsonItem in jsonList) {
        if (jsonItem is Map<String, dynamic>) {
          bangumiList.add(BangumiItem.fromJson(jsonItem));
        }
      }
    } catch (e) {
      KazumiLogger()
          .e('Network: resolve bangumi mirror popular list failed', error: e);
    }
    return bangumiList;
  }

  static List<String> _buildNumberFilter<T extends num>(T? min, T? max) {
    return [
      if (min != null) '>=$min',
      if (max != null) '<=$max',
    ];
  }

  static Map<String, dynamic> buildBangumiSearchParams(
    String keyword, {
    List<String> tags = const [],
    String sort = 'heat',
    SearchDateRange? dateRange,
    SearchIntRange? rankRange,
    SearchDoubleRange? scoreRange,
    List<int> weekdays = const [],
  }) {
    final rankFilter = rankRange?.isValid == true
        ? _buildNumberFilter<int>(rankRange!.min, rankRange.max)
        : (sort == 'rank')
            ? [">0", "<=99999"]
            : [">=0", "<=99999"];

    final filter = <String, dynamic>{
      "type": [2],
      "tag": tags,
      "rank": rankFilter,
      "nsfw": false
    };

    if (dateRange?.isValid == true) {
      filter["air_date"] = [">=${dateRange!.start}", "<${dateRange.end}"];
    }
    if (scoreRange?.isValid == true) {
      filter["rating"] =
          _buildNumberFilter<double>(scoreRange!.min, scoreRange.max);
    }
    if (weekdays.isNotEmpty) {
      filter["air_weekday"] = weekdays.toSet().toList()..sort();
    }

    return <String, dynamic>{
      'keyword': keyword,
      'sort': sort,
      "filter": filter,
    };
  }

  static Future<BangumiSearchPage?> bangumiSearch(String keyword,
      {List<String> tags = const [],
      int limit = 20,
      int offset = 0,
      String sort = 'heat',
      SearchDateRange? dateRange,
      SearchIntRange? rankRange,
      SearchDoubleRange? scoreRange,
      List<int> weekdays = const []}) async {
    List<BangumiItem> bangumiList = [];

    final params = buildBangumiSearchParams(
      keyword,
      tags: tags,
      sort: sort,
      dateRange: dateRange,
      rankRange: rankRange,
      scoreRange: scoreRange,
      weekdays: weekdays,
    );

    try {
      final jsonData = await _client.post(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiRankSearch,
            [limit, offset]),
        data: params,
      );
      final jsonList = jsonData['data'];
      for (dynamic jsonItem in jsonList) {
        if (jsonItem is Map<String, dynamic>) {
          try {
            BangumiItem bangumiItem = BangumiItem.fromJson(jsonItem);
            if (bangumiItem.nameCn != '') {
              bangumiList.add(bangumiItem);
            }
          } catch (e) {
            KazumiLogger()
                .e('Network: resolve search results failed', error: e);
          }
        }
      }
      return BangumiSearchPage(
        items: bangumiList,
        rawCount: jsonList.length,
      );
    } catch (e) {
      KazumiLogger().e('Network: unknown search problem', error: e);
      return null;
    }
  }

  static Future<BangumiItem?> getBangumiInfoByID(int id) async {
    try {
      final jsonData = await _client.get(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAPINextDomain +
                ApiEndpoints.bangumiInfoByIDNext,
            [id]),
      );
      return BangumiItem.fromJson(jsonData);
    } catch (e) {
      KazumiLogger().e('Network: resolve bangumi item failed', error: e);
      return null;
    }
  }

  static Future<List<BangumiRelation>> getBangumiRelationsByID(int id) async {
    final jsonData = await _client.get(
      ApiEndpoints.formatUrl(
        ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiRelationsByID,
        [id],
      ),
    );
    if (jsonData is! List) {
      throw const FormatException('Bangumi relations response must be a list');
    }

    final relations = <BangumiRelation>[];
    for (final jsonItem in jsonData) {
      try {
        if (jsonItem is! Map) {
          throw const FormatException('Bangumi relation must be an object');
        }
        relations.add(
          BangumiRelation.fromJson(Map<String, dynamic>.from(jsonItem)),
        );
      } catch (e, stackTrace) {
        KazumiLogger().w(
          'BangumiApi: skipped malformed relation item',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }
    return relations;
  }

  static Future<EpisodeInfo> getBangumiEpisodeByID(int id, int episode) async {
    EpisodeInfo episodeInfo = EpisodeInfo.fromTemplate();
    var params = <String, dynamic>{
      'subject_id': id,
      'offset': episode - 1,
      'limit': 1
    };
    try {
      final jsonData = await _client.get(
        ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiEpisodeByID,
        queryParameters: params,
      );
      episodeInfo = EpisodeInfo.fromJson(jsonData['data'][0]);
    } catch (e) {
      KazumiLogger().e('Network: resolve bangumi episode failed', error: e);
    }
    return episodeInfo;
  }

  static Future<List<EpisodeInfo>> getBangumiEpisodesByID(int id) async {
    final List<EpisodeInfo> episodeList = [];
    const int limit = 100;
    int offset = 0;
    int? total;
    try {
      do {
        final params = <String, dynamic>{
          'subject_id': id,
          'offset': offset,
          'limit': limit,
        };
        final jsonData = await _client.get(
          ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiEpisodeByID,
          queryParameters: params,
        );
        total ??= jsonData['total'] as int?;
        final data = jsonData['data'] as List<dynamic>? ?? [];
        if (data.isEmpty) {
          break;
        }
        episodeList.addAll(data
            .whereType<Map<String, dynamic>>()
            .map((jsonItem) => EpisodeInfo.fromJson(jsonItem)));
        offset += data.length;
      } while (total == null || offset < total);
    } catch (e) {
      KazumiLogger()
          .e('Network: resolve bangumi episode list failed', error: e);
    }
    return episodeList;
  }

  static Future<CommentResponse> getBangumiCommentsByID(int id,
      {int offset = 0}) async {
    final jsonData = await _client.get(
      ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPINextDomain +
              ApiEndpoints.bangumiCommentsByIDNext,
          [id, 20, offset]),
    );
    return CommentResponse.fromJson(jsonData);
  }

  static Future<EpisodeCommentResponse> getBangumiCommentsByEpisodeID(
      int id) async {
    final jsonData = await _client.get(
      ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPINextDomain +
              ApiEndpoints.bangumiEpisodeCommentsByIDNext,
          [id]),
    );
    return EpisodeCommentResponse.fromJson(jsonData);
  }

  static Future<CharacterCommentResponse> getCharacterCommentsByCharacterID(
      int id) async {
    final jsonData = await _client.get(
      ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPINextDomain +
              ApiEndpoints.bangumiCharacterCommentsByIDNext,
          [id]),
    );
    return CharacterCommentResponse.fromJson(jsonData);
  }

  static Future<StaffResponse> getBangumiStaffByID(int id) async {
    final jsonData = await _client.get(
      ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiStaffByID, [id]),
    );
    return StaffResponse.fromJson(jsonData);
  }

  static Future<CharactersResponse> getCharatersByBangumiID(int id) async {
    final jsonData = await _client.get(
      ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiCharacterByID,
          [id]),
    );
    return CharactersResponse.fromJson(jsonData);
  }

  static Future<CharacterFullItem> getCharacterByCharacterID(int id) async {
    CharacterFullItem characterFullItem = CharacterFullItem.fromTemplate();
    try {
      final jsonData = await _client.get(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAPINextDomain +
                ApiEndpoints.bangumiCharacterInfoByCharacterIDNext,
            [id]),
      );
      characterFullItem = CharacterFullItem.fromJson(jsonData);
    } catch (e) {
      KazumiLogger().e('Network: resolve character info failed', error: e);
    }
    return characterFullItem;
  }

}
