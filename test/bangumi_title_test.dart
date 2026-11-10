import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/bean/card/bangumi_card.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_title.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

BangumiItem _item({String name = '日本語タイトル', String nameCn = '中文标题'}) =>
    BangumiItem(
      id: 123,
      type: 2,
      name: name,
      nameCn: nameCn,
      summary: '',
      airDate: '',
      airWeekday: 0,
      rank: 0,
      images: const {},
      tags: [],
      alias: [],
      ratingScore: 0,
      votes: 0,
      votesCount: [],
      info: '',
    );

void main() {
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('kazumi-title-test-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    GStorage.trackingSync.dispose();
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  test('title selection supports preference and fallbacks', () {
    expect(bangumiTitle('日本語', '中文', preferOriginal: true), '日本語');
    expect(bangumiTitle('日本語', '中文', preferOriginal: false), '中文');
    expect(bangumiTitle('', '中文', preferOriginal: true), '中文');
    expect(bangumiTitle('日本語', '', preferOriginal: false), '日本語');
  });

  test('secondary title is the other distinct name', () {
    expect(bangumiSecondaryTitle('日本語', '中文', preferOriginal: true), '中文');
    expect(bangumiSecondaryTitle('日本語', '中文', preferOriginal: false), '日本語');
    expect(bangumiSecondaryTitle('同名', '同名', preferOriginal: true), '');
    expect(bangumiSecondaryTitle('', '中文', preferOriginal: true), '');
  });

  testWidgets('Bangumi card shows original title when setting is on',
      (tester) async {
    await tester.runAsync(() =>
        GStorage.putSetting(SettingsKeys.preferOriginalTitle, true));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 280,
              child: BangumiCardV(bangumiItem: _item()),
            ),
          ),
        ),
      ),
    );

    expect(find.text('日本語タイトル'), findsOneWidget);
    expect(find.text('中文标题'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
