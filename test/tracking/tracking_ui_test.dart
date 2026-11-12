import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/bean/widget/collect_button.dart';
import 'package:kazumi/bean/widget/tracker_logo.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
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
import 'package:kazumi/services/tracking/tracking_entry_cache.dart';
import 'package:kazumi/services/tracking/tracking_sync.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _FakeTracker implements Tracker {
  _FakeTracker(this.id);
  @override
  final TrackerId id;
  RemoteEntry? remote;
  List<TrackerSearchResult> results = const [];
  int saves = 0;
  int reads = 0;
  Completer<void>? readGate;
  bool failReads = false;
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
  Future<RemoteEntry?> readEntry(String token, String remoteId) async {
    reads++;
    final gate = readGate;
    if (gate != null) await gate.future;
    if (failReads) throw const TrackerNetworkException();
    return remote;
  }
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
  PathProviderPlatform.instance = _TestPaths(_dir.path);
  Hive.init(_dir.path);
  await GStorage.init();
  GStorage.trackingSync.dispose();
}

Future<void> _setup() async {
  await GStorage.collectibles.clear();
  await GStorage.collectChanges.clear();
  await GStorage.putSetting(SettingsKeys.preferOriginalTitle, false);
  bootstrapModule(createModule(register: (c) {
    c.addInstance<CollectController>(CollectController(CollectCrudRepository()));
  }));
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
  GStorage.trackingEntryCache = TrackingEntryCache(
    accountScope: (id) => id == TrackerId.bangumi
        ? GStorage.bangumiAccount.username
        : GStorage.anilistAccount.username,
  );
  GStorage.bangumiBindingManager = BangumiBindingManager(
    GStorage.bangumiAccount,
    _bindings,
    GStorage.trackingSync,
    tombstones: GStorage.trackingTombstones,
  );
  GStorage.anilistBindingManager = AniListBindingManager(
    GStorage.anilistAccount,
    _bindings,
    GStorage.trackingSync,
    tombstones: GStorage.trackingTombstones,
  );
}

Future<void> _cleanup() async {
  GStorage.trackingSync.dispose();
}

void main() {
  setUpAll(_initialize);
  setUp(_setup);
  tearDown(_cleanup);

  test('info page has no separate tracking icon', () {
    final source = File('lib/pages/info/info_page.dart').readAsStringSync();
    expect(source, isNot(contains('Icons.sync_alt_rounded')));
    expect(source, isNot(contains('showTrackingSheet(')));
  });

  testWidgets('tracking action does not present local library status as tracker status', (tester) async {
    await tester.runAsync(() => GStorage.bangumiAccount.signInWithToken('token'));
    await tester.runAsync(() => _bindings.put(TrackingBinding(
      subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123',
    )));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      CollectButton.extend(bangumiItem: _item()),
    )));
    expect(find.text('已追踪'), findsOneWidget);
    expect(find.textContaining('未追'), findsNothing);
    expect(find.byType(Badge), findsNothing);
    expect(find.textContaining('· 1'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending tracker status remains visible while remote is stale', (tester) async {
    await tester.runAsync(() => GStorage.bangumiAccount.signInWithToken('token'));
    final binding = TrackingBinding(subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123');
    await tester.runAsync(() => _bindings.put(binding));
    await tester.runAsync(() => CollectCrudRepository().addCollectibleIfMissing(_item(), 1));
    _bangumiTracker.remote = const RemoteEntry(progress: 2, status: TrackStatus.planning, total: 12);
    GStorage.trackingSync.dispose();
    await tester.pumpWidget(MaterialApp(home: Material(child: TrackingSheet(item: _item()))));
    await tester.pumpAndSettle();
    expect(find.text('想看'), findsOneWidget);
    await tester.runAsync(() => _outbox.put(OutboxEntry(
      subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123',
      bindingGeneration: binding.generation, status: TrackStatus.current,
    )));
    await tester.pumpAndSettle();
    expect(find.text('在看'), findsOneWidget);
    expect(find.text('想看'), findsNothing);
    expect(find.text('等待同步'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed tracker reads are visible and retry without writing a status', (tester) async {
    await tester.runAsync(() => GStorage.bangumiAccount.signInWithToken('token'));
    await tester.runAsync(() => _bindings.put(TrackingBinding(
      subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123',
    )));
    _bangumiTracker.failReads = true;
    await tester.pumpWidget(MaterialApp(home: Material(child: TrackingSheet(item: _item()))));
    await tester.pumpAndSettle();
    expect(find.text('读取失败'), findsOneWidget);
    expect(find.text('重新读取'), findsOneWidget);
    _bangumiTracker.failReads = false;
    _bangumiTracker.remote = const RemoteEntry(progress: 0, status: TrackStatus.planning);
    await tester.tap(find.text('重新读取'));
    await tester.pumpAndSettle();
    expect(find.text('想看'), findsOneWidget);
    expect(find.text('读取失败'), findsNothing);
    expect(_bangumiTracker.saves, 0);
    expect(GStorage.trackingOutbox, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stale-generation pending status cannot mask the current tracker', (tester) async {
    await tester.runAsync(() => GStorage.bangumiAccount.signInWithToken('token'));
    await tester.runAsync(() async {
      await _bindings.put(TrackingBinding(
        subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123', generation: 'new',
      ));
      await _outbox.put(const OutboxEntry(
        subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123',
        bindingGeneration: 'old', status: TrackStatus.current,
      ));
    });
    _bangumiTracker.remote = const RemoteEntry(progress: 0, status: TrackStatus.planning);
    await tester.pumpWidget(MaterialApp(home: Material(child: TrackingSheet(item: _item()))));
    await tester.pumpAndSettle();
    expect(find.text('想看'), findsOneWidget);
    expect(find.text('在看'), findsNothing);
    expect(find.text('等待同步'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('episode wheel identifies the selected episode before confirmation', (tester) async {
    await tester.runAsync(() => GStorage.bangumiAccount.signInWithToken('token'));
    await tester.runAsync(() => _bindings.put(TrackingBinding(
      subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123', total: 12,
    )));
    _bangumiTracker.remote = const RemoteEntry(progress: 4, status: TrackStatus.planning, total: 12);
    await tester.pumpWidget(MaterialApp(home: Material(child: TrackingSheet(item: _item()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4 / 12'));
    await tester.pumpAndSettle();
    final wheel = find.byType(ListWheelScrollView);
    Finder selected(int value) => find.descendant(of: wheel, matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.selected == true &&
          widget.properties.label == '已看集数：$value',
    ));
    expect(selected(4), findsOneWidget);
    await tester.drag(wheel, const Offset(0, -40));
    await tester.pumpAndSettle();
    expect(selected(5), findsOneWidget);
    expect(selected(4), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  test('a tracker status change also moves the show in the local library', () async {
    final controller = CollectController(CollectCrudRepository());
    final item = _item();
    await controller.addCollectFromTracker(item, CollectType.watching.value);
    expect(GStorage.collectibles.get(123)?.type, CollectType.watching.value);
    expect(
      GStorage.collectChanges.values.where((change) => change.bangumiID == 123),
      hasLength(1),
    );
    expect(GStorage.trackingOutbox.get('123:bangumi'), isNull);
    expect(GStorage.trackingOutbox.get('123:anilist'), isNull);

    // Re-selecting a status only records the change; it never fans out to a
    // tracker, because the drawer already wrote the one the owner chose.
    await controller.addCollectFromTracker(item, CollectType.watched.value);
    expect(GStorage.collectibles.get(123)?.type, CollectType.watched.value);
    expect(GStorage.trackingOutbox, isEmpty);
  });

  test('mirroring a status keeps the stored item and its timestamp', () async {
    final controller = CollectController(CollectCrudRepository());
    final stored = _item()..name = 'Stored richer title';
    final addedAt = DateTime(2020, 1, 2, 3, 4, 5);
    await GStorage.collectibles.put(
      123,
      CollectedBangumi(stored, addedAt, CollectType.planToWatch.value),
    );

    await controller.addCollectFromTracker(_item(), CollectType.watching.value);

    final row = GStorage.collectibles.get(123)!;
    expect(row.type, CollectType.watching.value);
    expect(row.bangumiItem.name, 'Stored richer title');
    expect(row.time, addedAt);
    expect(
      GStorage.collectChanges.values.where((change) => change.bangumiID == 123),
      hasLength(1),
    );

    // An absent row is still inserted with the sheet's item.
    await controller.addCollectFromTracker(
      _item()..id = 456,
      CollectType.watched.value,
    );
    final inserted = GStorage.collectibles.get(456)!;
    expect(inserted.type, CollectType.watched.value);
    expect(inserted.bangumiItem.id, 456);
  });

  test('following a tracker status keeps the item and records no collect change',
      () async {
    final controller = CollectController(CollectCrudRepository());
    final stored = _item()
      ..id = 789
      ..name = 'Stored richer title';
    final addedAt = DateTime(2021, 5, 6);
    await GStorage.collectibles.put(
      789,
      CollectedBangumi(stored, addedAt, CollectType.planToWatch.value),
    );

    await controller.followTrackerStatus(_item()..id = 789,
        CollectType.watched.value);

    final row = GStorage.collectibles.get(789)!;
    expect(row.type, CollectType.watched.value);
    expect(row.bangumiItem.name, 'Stored richer title');
    expect(row.time, addedAt);
    expect(
      GStorage.collectChanges.values.where((change) => change.bangumiID == 789),
      isEmpty,
    );
  });

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
    expect(find.byType(TrackerLogo), findsOneWidget);
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
    expect(find.text('5 / 12'), findsOneWidget);
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
    late Future<void> removing;
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
        home: Material(
          child: TrackingSheet(
            item: _item(),
            onRemoveBinding: (binding) => removing = tester.runAsync(
              () => GStorage.bangumiBindingManager.stopTracking(binding.subjectId),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('远端追番列表不会改变'), findsOneWidget);
    await tester.tap(find.text('移除').last);
    await tester.pumpAndSettle();
    await removing;
    expect(GStorage.trackingTombstones.get('123:bangumi'), isNotNull);
    expect(GStorage.trackingBindings.get('123:bangumi'), isNull);
    expect(
      _settings.get(SettingsKeys.bangumiExcludedSubjectIds.name),
      contains('123'),
    );
    expect(GStorage.trackingOutbox.get('123:bangumi'), isNull);
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
    await tester.pumpWidget(MaterialApp(
      home: Material(
        child: TrackingSheet(
          item: _item(),
          onMirrorStatus: (item, type) async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog), matching: find.text('在看'),
    ));
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

  testWidgets('a failed library mirror is visible and keeps the tracker edit',
      (tester) async {
    await tester.runAsync(() => GStorage.bangumiAccount.signInWithToken('token'));
    await tester.runAsync(() async {
      await _bindings.put(TrackingBinding(
        subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123',
      ));
      // Local category 想看, so choosing 在看 must reach the mirror.
      await CollectController(CollectCrudRepository())
          .addCollectFromTracker(_item(), CollectType.planToWatch.value);
    });
    GStorage.trackingSync.dispose();
    var mirrorCalls = 0;
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      home: Scaffold(
        body: TrackingSheet(
          item: _item(),
          onMirrorStatus: (item, type) async {
            mirrorCalls++;
            throw StateError('local write');
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog), matching: find.text('在看'),
    ));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(GStorage.trackingOutbox.get('123:bangumi')?.status, TrackStatus.current);

    // The mirror runs after the awaited tracker enqueue; let it run.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pumpAndSettle();
    expect(mirrorCalls, 1);
    expect(GStorage.collectibles.get(123)?.type, CollectType.planToWatch.value);
    expect(find.text('本地追番状态未更新，追踪状态已保存'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tracking sheet has tracker controls without local collection picker', (tester) async {
    await tester.runAsync(() => GStorage.bangumiAccount.signInWithToken('token'));
    await tester.runAsync(() => GStorage.anilistAccount.signInWithToken('token'));
    await tester.runAsync(() async {
      await _bindings.put(TrackingBinding(
        subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123',
      ));
      await _bindings.put(TrackingBinding(
        subjectId: 123, trackerId: TrackerId.anilist, remoteId: '42',
      ));
    });
    GStorage.trackingSync.dispose();
    final mirrored = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Material(
        child: TrackingSheet(
          item: _item(),
          onMirrorStatus: (item, type) async => mirrored.add(type.value),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('收藏'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('状态'), findsNWidgets(2));
    expect(find.text('评分'), findsNWidgets(2));
    await tester.tap(find.text('状态').first);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog), matching: find.text('在看'),
    ));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    expect(GStorage.trackingOutbox.get('123:bangumi')?.status, TrackStatus.current);
    expect(GStorage.trackingOutbox.get('123:anilist'), isNull);

    await tester.ensureVisible(find.text('状态').last);
    await tester.tap(find.text('状态').last);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog), matching: find.text('抛弃'),
    ));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(GStorage.trackingOutbox.get('123:anilist')?.status, TrackStatus.dropped);
    expect(GStorage.trackingOutbox.get('123:bangumi')?.status, TrackStatus.current);
    // A drawer status change also moves the show in the local library that
    // 追番 lists; the seam records it because a real write is Hive I/O. The
    // mirror runs after the awaited tracker enqueue, so let its microtasks run.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    expect(mirrored, [CollectType.watching.value, CollectType.abandoned.value]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('collection button opens sheet and controller updates local status and bindings', (tester) async {
    await tester.runAsync(() => GStorage.bangumiAccount.signInWithToken('token'));
    GStorage.trackingSync.dispose();
    final controller = CollectController(CollectCrudRepository());
    var opened = 0;
    var closed = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(
      child: CollectButton.extend(
        bangumiItem: _item(), onOpen: () => opened++, onClose: () => closed++,
      ),
    ))));
    expect(find.text('追踪'), findsOneWidget);
    await tester.tap(find.text('追踪'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.byType(TrackingSheet), findsOneWidget);
    expect(find.text('收藏'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);

    await tester.runAsync(() => controller.addCollect(_item(), type: 1));
    await tester.pumpAndSettle();
    expect(GStorage.collectibles.get(123)?.type, 1);
    expect(GStorage.trackingOutbox.get('123:bangumi')?.status, TrackStatus.current);
    expect(GStorage.trackingBindings.get('123:bangumi')?.title, 'Example');
    expect(find.text('已追踪'), findsOneWidget);
    expect(find.text('在看'), findsOneWidget);

    await tester.runAsync(() => controller.deleteCollect(_item()));
    await tester.pumpAndSettle();
    expect(GStorage.collectibles.get(123), isNull);
    expect(GStorage.trackingBindings.get('123:bangumi'), isNotNull);
    expect(GStorage.trackingOutbox.get('123:bangumi')?.status, TrackStatus.current);
    expect(find.text('已追踪'), findsOneWidget);
    Navigator.of(tester.element(find.byType(TrackingSheet))).pop();
    await tester.pumpAndSettle();
    expect(closed, 1);
    expect(find.text('已追踪'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Bangumi title follows display preference', (tester) async {
    await tester.runAsync(() => GStorage.bangumiAccount.signInWithToken('token'));
    await tester.runAsync(() => _bindings.put(TrackingBinding(
      subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123', title: 'old snapshot',
    )));
    await tester.pumpWidget(MaterialApp(home: Material(child: TrackingSheet(item: _item()))));
    await tester.pumpAndSettle();
    expect(find.text('示例番剧'), findsOneWidget);
    expect(find.text('old snapshot'), findsNothing);
    await tester.runAsync(() => GStorage.putSetting(SettingsKeys.preferOriginalTitle, true));
    await tester.pumpWidget(MaterialApp(home: Material(child: TrackingSheet(key: UniqueKey(), item: _item()))));
    await tester.pumpAndSettle();
    expect(find.text('Example'), findsOneWidget);
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

  testWidgets('fresh cached tracker state avoids another network read on reopen', (tester) async {
    await tester.runAsync(() => GStorage.bangumiAccount.signInWithToken('token'));
    final binding = TrackingBinding(
      subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123',
    );
    await tester.runAsync(() async {
      await _bindings.put(binding);
      await GStorage.trackingEntryCache.put(
        binding,
        const RemoteEntry(progress: 3, status: TrackStatus.current, total: 12),
        DateTime.now(),
      );
    });
    for (var open = 0; open < 2; open++) {
      await tester.pumpWidget(MaterialApp(home: Material(child: TrackingSheet(item: _item()))));
      await tester.pumpAndSettle();
      expect(find.text('在看'), findsOneWidget);
      expect(find.text('3 / 12'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
    expect(_bangumiTracker.reads, 0);
  });

  testWidgets('stale cached state stays visible while its refresh is outstanding', (tester) async {
    await tester.runAsync(() => GStorage.bangumiAccount.signInWithToken('token'));
    final binding = TrackingBinding(
      subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123',
    );
    final gate = Completer<void>();
    _bangumiTracker.readGate = gate;
    _bangumiTracker.remote = const RemoteEntry(
      progress: 4, status: TrackStatus.current, total: 12,
    );
    await tester.runAsync(() async {
      await _bindings.put(binding);
      await GStorage.trackingEntryCache.put(
        binding,
        const RemoteEntry(progress: 3, status: TrackStatus.planning, total: 12),
        DateTime.now().subtract(const Duration(minutes: 10)),
      );
    });
    await tester.pumpWidget(MaterialApp(home: Material(child: TrackingSheet(item: _item()))));
    await tester.pump();
    expect(find.text('想看'), findsOneWidget);
    expect(find.text('3 / 12'), findsOneWidget);
    expect(find.text('读取中…'), findsNothing);
    expect(find.text('正在刷新追踪状态…'), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('在看'), findsOneWidget);
    expect(find.text('4 / 12'), findsOneWidget);
    expect(find.text('正在刷新追踪状态…'), findsNothing);
    expect(_bangumiTracker.reads, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('number picker stays a compact dialog on a wide tablet', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => GStorage.bangumiAccount.signInWithToken('token'));
    await tester.runAsync(() => _bindings.put(TrackingBinding(
      subjectId: 123, trackerId: TrackerId.bangumi, remoteId: '123', total: 12,
    )));
    _bangumiTracker.remote = const RemoteEntry(
      progress: 4, status: TrackStatus.planning, total: 12,
    );
    await tester.pumpWidget(MaterialApp(home: Material(child: TrackingSheet(item: _item()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4 / 12'));
    await tester.pumpAndSettle();
    // AlertDialog's render box is the full-screen route; the wheel is the
    // actual dialog content whose width the compact constraint controls.
    final width = tester.getSize(find.byType(ListWheelScrollView)).width;
    expect(width, lessThanOrEqualTo(360));
    expect(width, greaterThanOrEqualTo(240));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
