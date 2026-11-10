import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/hive_registrar.g.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/info/anilist_search_page.dart';
import 'package:kazumi/pages/info/tracking_sheet.dart';
import 'package:kazumi/pages/settings/sync/bangumi_sync_page.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/tracking/anilist_account.dart';
import 'package:kazumi/services/tracking/anilist_binding.dart';
import 'package:kazumi/services/tracking/bangumi_account.dart';
import 'package:kazumi/services/tracking/bangumi_binding.dart';
import 'package:kazumi/services/tracking/models.dart';
import 'package:kazumi/services/tracking/stores.dart';
import 'package:kazumi/services/tracking/tracker.dart';
import 'package:kazumi/services/tracking/tracking_sync.dart';

class _FakeTracker implements Tracker {
  _FakeTracker(this.id);
  @override
  final TrackerId id;
  RemoteEntry? remote;
  List<TrackerSearchResult> results = const [];
  int saves = 0;
  String? lastQuery;

  @override
  Future<TrackerUser> viewer(String token) async => TrackerUser(
    id: '1',
    name: id == TrackerId.bangumi ? 'bgm-user' : 'ani-user',
  );
  @override
  Future<List<TrackerSearchResult>> search(
    String query, {
    String? token,
  }) async {
    lastQuery = query;
    return results;
  }
  @override
  Future<RemoteEntry?> readEntry(String token, String remoteId) async => remote;
  @override
  Future<int> save(
    String token,
    String remoteId, {
    int? progress,
    TrackStatus? status,
    int? score,
  }) async {
    saves++;
    return progress ?? remote?.progress ?? 0;
  }
}

late Directory _dir;
late Box<dynamic> _settings;
var _boxNumber = 0;
late _FakeTracker _bangumiTracker;
late _FakeTracker _anilistTracker;
late HiveBindingStore _bindings;
late HiveOutboxStore _outbox;

BangumiItem _item() => BangumiItem(
  id: 123,
  type: 2,
  name: 'Example',
  nameCn: '示例番剧',
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

Future<void> _initialize() async {
  _dir = await Directory.systemTemp.createTemp('kazumi-tracking-ui');
  Hive.init(_dir.path);
  if (!Hive.isAdapterRegistered(0)) Hive.registerAdapters();
}

Future<void> _setup() async {
  final suffix = '${_boxNumber++}';
  _settings = await Hive.openBox<dynamic>('settings_$suffix');
  GStorage.trackingBindings = await Hive.openBox<TrackingBinding>(
    'trackingBindings_$suffix',
  );
  GStorage.trackingOutbox = await Hive.openBox<OutboxEntry>(
    'trackingOutbox_$suffix',
  );
  _bangumiTracker = _FakeTracker(TrackerId.bangumi);
  _anilistTracker = _FakeTracker(TrackerId.anilist);
  _bindings = HiveBindingStore(GStorage.trackingBindings);
  _outbox = HiveOutboxStore(GStorage.trackingOutbox);
  GStorage.bangumiAccount = BangumiAccount(
    settings: _settings,
    tracker: _bangumiTracker,
  );
  GStorage.anilistAccount = AniListAccount(
    settings: _settings,
    tracker: _anilistTracker,
  );
  GStorage.trackingSync = TrackingSync(
    bindings: _bindings,
    outbox: _outbox,
    trackers: [_bangumiTracker, _anilistTracker],
    tokenProvider: (_) async => 'token',
    delay: (_) async {},
    schedule: (_, _) => () {},
  );
  GStorage.bangumiBindingManager = BangumiBindingManager(
    GStorage.bangumiAccount,
    _bindings,
    GStorage.trackingSync,
  );
  GStorage.anilistBindingManager = AniListBindingManager(
    GStorage.anilistAccount,
    _bindings,
    GStorage.trackingSync,
  );
}

Future<void> _cleanup() async {
  GStorage.trackingSync.dispose();
}

void main() {
  setUpAll(_initialize);
  setUp(_setup);
  tearDown(_cleanup);

  testWidgets('signed-out state points to account settings', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Material(child: TrackingSheet(item: _item())),
      ),
    );
    expect(find.text('尚未登录追踪账号'), findsOneWidget);
    expect(find.text('追踪账号'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('开始追踪 clears opt-out and re-enables Bangumi binding', (tester) async {
    await tester.runAsync(() async {
      await _settings.put(
        SettingsKeys.bangumiExcludedSubjectIds.name,
        ['123'],
      );
      await GStorage.bangumiAccount.signInWithToken('token');
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Material(child: TrackingSheet(item: _item())),
      ),
    );
    await tester.tap(find.text('添加追踪'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(GStorage.trackingBindings.get('123:bangumi')?.remoteId, '123');
    expect(
      _settings.get(SettingsKeys.bangumiExcludedSubjectIds.name),
      isNot(contains('123')),
    );
    expect(find.text('bgm'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('bound row shows progress, status and retry for failed sync', (
    tester,
  ) async {
    await tester.runAsync(
      () => GStorage.bangumiAccount.signInWithToken('token'),
    );
    final binding = TrackingBinding(
      subjectId: 123,
      trackerId: TrackerId.bangumi,
      remoteId: '123',
      title: '绑定番剧',
      total: 12,
      lastRemoteProgress: 4,
    );
    await tester.runAsync(() => _bindings.put(binding));
    _bangumiTracker.remote = const RemoteEntry(
      progress: 4,
      status: TrackStatus.current,
      score: 80,
      total: 12,
    );
    await tester.runAsync(
      () => _outbox.put(
        OutboxEntry(
          subjectId: 123,
          trackerId: TrackerId.bangumi,
          remoteId: '123',
          bindingGeneration: binding.generation,
          progress: 5,
          error: 'Sync failed after retries',
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Material(child: TrackingSheet(item: _item())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('4 / 12'), findsOneWidget);
    expect(find.text('8.0'), findsOneWidget);
    expect(find.text('在看'), findsOneWidget);
    expect(find.textContaining('同步失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manual progress accounts for a non-zero episode offset', (
    tester,
  ) async {
    await tester.runAsync(
      () => GStorage.bangumiAccount.signInWithToken('token'),
    );
    final binding = TrackingBinding(
      subjectId: 123,
      trackerId: TrackerId.bangumi,
      remoteId: '123',
      episodeOffset: 12,
      total: 24,
    );
    await tester.runAsync(() => _bindings.put(binding));
    _bangumiTracker.remote = const RemoteEntry(
      progress: 12,
      status: TrackStatus.current,
      total: 24,
    );
    await tester.pumpWidget(
      MaterialApp(home: Material(child: TrackingSheet(item: _item()))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('12 / 24'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListWheelScrollView), const Offset(0, -40));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(
      GStorage.trackingOutbox.get('123:bangumi')?.progress,
      13,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('remove confirmation deletes only the local binding', (
    tester,
  ) async {
    await tester.runAsync(
      () => GStorage.bangumiAccount.signInWithToken('token'),
    );
    await tester.runAsync(
      () => _bindings.put(
        TrackingBinding(
          subjectId: 123,
          trackerId: TrackerId.bangumi,
          remoteId: '123',
          title: 'Bound',
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Material(child: TrackingSheet(item: _item())),
      ),
    );
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('远端追番列表不会改变'), findsOneWidget);
    await tester.tap(find.text('移除').last);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(GStorage.trackingBindings.get('123:bangumi'), isNull);
    expect(_bangumiTracker.saves, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AniList search selects and creates a binding', (tester) async {
    await tester.runAsync(
      () => GStorage.anilistAccount.signInWithToken('token'),
    );
    _anilistTracker.results = const [
      TrackerSearchResult(
        id: '42',
        title: 'Ani title',
        subtitle: 'Romanized',
        format: 'TV',
        seasonYear: 2024,
        episodes: 12,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Material(child: AniListSearchPage(item: _item())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ani title'), findsOneWidget);
    expect(find.textContaining('TV'), findsOneWidget);
    await tester.tap(find.text('Ani title'));
    await tester.pump();
    await tester.tap(find.text('追踪'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(GStorage.trackingBindings.get('123:anilist')?.remoteId, '42');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AniList add opens search with original title', (tester) async {
    await tester.runAsync(() => GStorage.anilistAccount.signInWithToken('token'));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TrackingSheet(item: _item()))));
    await tester.tap(find.text('添加追踪'));
    await tester.pumpAndSettle();
    expect(find.byType(AniListSearchPage), findsOneWidget);
    expect(find.text('Example'), findsOneWidget);
    expect(_anilistTracker.lastQuery, 'Example');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('status and score selectors enqueue chosen values', (tester) async {
    await tester.runAsync(() => GStorage.bangumiAccount.signInWithToken('token'));
    await tester.runAsync(() => _bindings.put(TrackingBinding(
      subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123',
    )));
    GStorage.trackingSync.dispose();
    await tester.pumpWidget(MaterialApp(home: Material(child: TrackingSheet(item: _item()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('在看'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(GStorage.trackingOutbox.get('123:bangumi')?.status, TrackStatus.current);
    await tester.tap(find.text('评分'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListWheelScrollView), const Offset(0, -80));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(GStorage.trackingOutbox.get('123:bangumi')?.score, 20);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('accounts page displays user and signs out', (tester) async {
    await tester.runAsync(
      () => GStorage.anilistAccount.signInWithToken('token'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPaneScope(
          embedded: true,
          showBackButton: false,
          onBack: () {},
          child: const BangumiSyncPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已登录 · ani-user'), findsOneWidget);
    await tester.tap(find.text('退出登录').last);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(GStorage.anilistAccount.isSignedIn, isFalse);
    expect(find.text('已退出登录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
