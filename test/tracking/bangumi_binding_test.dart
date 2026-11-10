import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/tracking/bangumi_account.dart';
import 'package:kazumi/services/tracking/bangumi_binding.dart';
import 'package:kazumi/services/tracking/tracker.dart';
import 'package:kazumi/services/tracking/tracking_sync.dart';

import 'tracking_sync_test.dart' show FakeTracker, MemoryBindings, MemoryOutbox;

void main() {
  test('watched events create one binding only when signed in', () async {
    final dir = await Directory.systemTemp.createTemp('kazumi-binding-test');
    Hive.init(dir.path);
    final settings = await Hive.openBox<dynamic>('settings');
    final tracker = FakeTracker(TrackerId.bangumi);
    final account = BangumiAccount(settings: settings, tracker: tracker);
    final bindings = MemoryBindings();
    final outbox = MemoryOutbox();
    final sync = TrackingSync(
      bindings: bindings,
      outbox: outbox,
      trackers: [],
      tokenProvider: (_) => account.validToken(),
    );
    final manager = BangumiBindingManager(account, bindings, sync);
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
    await manager.watched(item, 1);
    expect(bindings.rows, isEmpty);
    expect(outbox.rows, isEmpty);
    await account.signInWithToken('token');
    await Future.wait([manager.watched(item, 1), manager.watched(item, 2)]);
    expect(bindings.rows.length, 1);
    final binding = bindings.rows['123:bangumi']!;
    expect(binding.remoteId, '123');
    expect(outbox.rows['123:bangumi']!.progress, 2);
    await manager.watched(item, 3);
    expect(bindings.rows['123:bangumi']!.generation, binding.generation);
    sync.dispose();
    await Hive.close();
    await dir.delete(recursive: true);
  });
}
