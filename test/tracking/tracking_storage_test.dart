import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/hive_registrar.g.dart';
import 'package:kazumi/services/tracking/models.dart';
import 'package:kazumi/services/tracking/stores.dart';
import 'package:kazumi/services/tracking/tracker.dart';

void main() {
  test('tracking boxes persist models across reopening', () async {
    final directory = await Directory.systemTemp.createTemp('kazumi-tracking');
    Hive.init(directory.path);
    Hive.registerAdapters();
    try {
      var (bindings, outbox) = await openTrackingStores();
      final binding = TrackingBinding(
        subjectId: 1,
        trackerId: TrackerId.anilist,
        remoteId: '42',
        total: 12,
      );
      await bindings.put(binding);
      await outbox.put(
        OutboxEntry(
          bindingGeneration: binding.generation,
          subjectId: 1,
          trackerId: TrackerId.anilist,
          remoteId: '42',
          progress: 8,
          status: TrackStatus.current,
          attempts: 2,
        ),
      );
      await bindings.box.close();
      await outbox.box.close();
      (bindings, outbox) = await openTrackingStores();
      expect((await bindings.get('1:anilist'))?.total, 12);
      expect((await bindings.get('1:anilist'))?.generation, binding.generation);
      expect(
        (await outbox.get('1:anilist'))?.bindingGeneration,
        binding.generation,
      );
      expect((await outbox.get('1:anilist'))?.attempts, 2);
      expect((await outbox.get('1:anilist'))?.status, TrackStatus.current);
    } finally {
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });
}
