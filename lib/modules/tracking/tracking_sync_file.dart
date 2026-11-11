import 'dart:convert';

class TrackingSyncBinding {
  const TrackingSyncBinding({
    required this.subjectId,
    required this.remoteId,
    this.title,
    this.cover,
    this.total,
    this.episodeOffset = 0,
    this.statusLocked = false,
    this.score,
    this.updatedAt,
  }) : trackerId = 'anilist';

  final int subjectId;
  final String trackerId;
  final String remoteId;
  final String? title;
  final String? cover;
  final int? total;
  final int episodeOffset;
  final bool statusLocked;
  final int? score;
  final DateTime? updatedAt;

  String get key => '$subjectId:$trackerId';

  Map<String, Object?> toJson() => {
    'subjectId': subjectId,
    'trackerId': trackerId,
    'remoteId': remoteId,
    'title': title,
    'cover': cover,
    'total': total,
    'episodeOffset': episodeOffset,
    'statusLocked': statusLocked,
    'score': score,
    'updatedAt': updatedAt?.toIso8601String(),
  };

  static TrackingSyncBinding fromJson(Object? value) {
    final json = _object(value, {
      'subjectId',
      'trackerId',
      'remoteId',
      'title',
      'cover',
      'total',
      'episodeOffset',
      'statusLocked',
      'score',
      'updatedAt',
    });
    final trackerId = json['trackerId'];
    final subjectId = json['subjectId'];
    final remoteId = json['remoteId'];
    final offset = json['episodeOffset'];
    final locked = json['statusLocked'];
    if (subjectId is! int ||
        subjectId < 0 ||
        trackerId != 'anilist' ||
        remoteId is! String ||
        remoteId.isEmpty ||
        offset is! int ||
        locked is! bool) {
      throw const FormatException('Invalid tracking binding');
    }
    return TrackingSyncBinding(
      subjectId: subjectId,
      remoteId: remoteId,
      title: _optionalString(json['title']),
      cover: _optionalString(json['cover']),
      total: _optionalInt(json['total']),
      episodeOffset: offset,
      statusLocked: locked,
      score: _optionalInt(json['score']),
      updatedAt: _optionalDate(json['updatedAt']),
    );
  }
}

class TrackingTombstone {
  const TrackingTombstone({required this.key, required this.deletedAt});

  final String key;
  final int deletedAt;

  Map<String, Object> toJson() => {'key': key, 'deletedAt': deletedAt};

  static TrackingTombstone fromJson(Object? value) {
    final json = _object(value, {'key', 'deletedAt'});
    final key = json['key'];
    final deletedAt = json['deletedAt'];
    if (key is! String ||
        !RegExp(r'^\d+:anilist$').hasMatch(key) ||
        deletedAt is! int ||
        deletedAt < 0) {
      throw const FormatException('Invalid tracking tombstone');
    }
    return TrackingTombstone(key: key, deletedAt: deletedAt);
  }
}

class TrackingSyncFile {
  const TrackingSyncFile({
    this.bindings = const [],
    this.tombstones = const [],
    this.bangumiExcluded = const [],
  });

  static const version = 1;

  final List<TrackingSyncBinding> bindings;
  final List<TrackingTombstone> tombstones;
  final List<int> bangumiExcluded;

  Map<String, Object> toJson() => {
    'version': version,
    'bindings': bindings.map((binding) => binding.toJson()).toList(),
    'tombstones': tombstones.map((tombstone) => tombstone.toJson()).toList(),
    'bangumiExcluded': bangumiExcluded,
  };

  String encode() => jsonEncode(toJson());

  static TrackingSyncFile decode(String source) {
    final json = _object(jsonDecode(source), {
      'version',
      'bindings',
      'tombstones',
      'bangumiExcluded',
    });
    if (json['version'] != version ||
        json['bindings'] is! List ||
        json['tombstones'] is! List ||
        json['bangumiExcluded'] is! List) {
      throw const FormatException('Invalid tracking sync file');
    }
    final bindings = (json['bindings'] as List)
        .map(TrackingSyncBinding.fromJson)
        .toList();
    final tombstones = (json['tombstones'] as List)
        .map(TrackingTombstone.fromJson)
        .toList();
    final excluded = (json['bangumiExcluded'] as List).toList();
    if (excluded.any((id) => id is! int || id < 0)) {
      throw const FormatException('Invalid Bangumi exclusion list');
    }
    final bindingKeys = bindings.map((binding) => binding.key).toSet();
    final tombstoneKeys = tombstones.map((tombstone) => tombstone.key).toSet();
    if (bindingKeys.length != bindings.length ||
        tombstoneKeys.length != tombstones.length ||
        bindingKeys.intersection(tombstoneKeys).isNotEmpty ||
        excluded.toSet().length != excluded.length) {
      throw const FormatException('Duplicate tracking sync entry');
    }
    return TrackingSyncFile(
      bindings: bindings,
      tombstones: tombstones,
      bangumiExcluded: excluded.cast<int>(),
    );
  }
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(value.keys.toSet()).isNotEmpty) {
    throw const FormatException('Invalid tracking sync object');
  }
  return value;
}

String? _optionalString(Object? value) {
  if (value == null || value is String) return value as String?;
  throw const FormatException('Invalid optional string');
}

int? _optionalInt(Object? value) {
  if (value == null || value is int) return value as int?;
  throw const FormatException('Invalid optional integer');
}

DateTime? _optionalDate(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const FormatException('Invalid update time');
  try {
    return DateTime.parse(value);
  } on FormatException {
    throw const FormatException('Invalid update time');
  }
}
