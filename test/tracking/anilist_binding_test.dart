import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/tracking/anilist_account.dart';
import 'package:kazumi/services/tracking/anilist_binding.dart';
import 'package:kazumi/services/tracking/bangumi_account.dart';
import 'package:kazumi/services/tracking/bangumi_binding.dart';
import 'package:kazumi/services/tracking/tracker.dart';
import 'package:kazumi/services/tracking/tracking_sync.dart';

import 'tracking_sync_test.dart' show FakeTracker, MemoryBindings, MemoryOutbox;

void main() {
  test(
    'binding preserves remote entry, unbind is local, watched fans out',
    () async {
      final dir = await Directory.systemTemp.createTemp('anilist-binding');
      Hive.init(dir.path);
      final settings = await Hive.openBox<dynamic>('settings');
      final ani = FakeTracker(TrackerId.anilist);
      final bgm = FakeTracker(TrackerId.bangumi);
      final account = AniListAccount(settings: settings, tracker: ani);
      final bangumi = BangumiAccount(settings: settings, tracker: bgm);
      await account.signInWithToken('token');
      await bangumi.signInWithToken('token');
      final bindings = MemoryBindings();
      final outbox = MemoryOutbox();
      final sync = TrackingSync(
        bindings: bindings,
        outbox: outbox,
        trackers: [],
        tokenProvider: (_) async => 'token',
      );
      final manager = AniListBindingManager(account, bindings, sync);
      final watched = BangumiBindingManager(bangumi, bindings, sync);
      final item = BangumiItem(
        id: 123,
        type: 2,
        name: 'show',
        nameCn: '',
        summary: '',
        airDate: '',
        airWeekday: 0,
        rank: 0,
        images: {},
        tags: [],
        alias: [],
        ratingScore: 0,
        votes: 0,
        votesCount: [],
        info: '',
      );
      const result = TrackerSearchResult(
        id: '42',
        title: 'title',
        episodes: 12,
        cover: 'cover',
      );
      ani.remote = const RemoteEntry(progress: 4, status: TrackStatus.current);
      await manager.bind(item, result);
      expect(outbox.rows, isEmpty);
      expect(ani.calls, isEmpty);
      expect(bindings.rows['123:anilist']!.total, 12);
      await watched.watched(item, 5);
      expect(outbox.rows['123:anilist']!.progress, 5);
      expect(outbox.rows['123:bangumi']!.progress, 5);
      await watched.statusChanged(item, CollectType.onHold);
      expect(outbox.rows['123:anilist']!.status, TrackStatus.paused);
      expect(outbox.rows['123:bangumi']!.status, TrackStatus.paused);
      final generation = bindings.rows['123:anilist']!.generation;
      await manager.unbind(123);
      expect(bindings.rows.containsKey('123:anilist'), false);
      expect(ani.calls, isEmpty);
      ani.remote = null;
      await manager.bind(item, result);
      expect(bindings.rows['123:anilist']!.generation, isNot(generation));
      expect(outbox.rows['123:anilist']!.status, TrackStatus.planning);
      expect(outbox.rows['123:bangumi']!.status, TrackStatus.paused);
      sync.dispose();
      await Hive.close();
      await dir.delete(recursive: true);
    },
  );
}
