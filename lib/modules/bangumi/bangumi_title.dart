import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/storage/storage.dart';

String bangumiTitle(String name, String nameCn, {required bool preferOriginal}) {
  final preferred = preferOriginal ? name : nameCn;
  final fallback = preferOriginal ? nameCn : name;
  return preferred.trim().isNotEmpty ? preferred : fallback;
}

String bangumiSecondaryTitle(String name, String nameCn,
    {required bool preferOriginal}) {
  final title = bangumiTitle(name, nameCn, preferOriginal: preferOriginal);
  final other = preferOriginal ? nameCn : name;
  return other.trim().isNotEmpty && other != title ? other : '';
}

extension BangumiItemTitle on BangumiItem {
  bool get _preferOriginalTitle =>
      GStorage.getSetting(SettingsKeys.preferOriginalTitle);

  String get displayTitle => bangumiTitle(
        name,
        nameCn,
        preferOriginal: _preferOriginalTitle,
      );

  String get secondaryTitle => bangumiSecondaryTitle(
        name,
        nameCn,
        preferOriginal: _preferOriginalTitle,
      );
}
