import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/clients/bangumi_client.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';

import 'bangumi_tracker_test.dart' show FakeAdapter;

void main() {
  test('public Bangumi requests never attach Authorization', () async {
    final adapter = FakeAdapter((_) => (status: 200, body: {}, headers: null));
    final dio = Dio()..httpClientAdapter = adapter;
    final client = BangumiClient(dio: dio, acceleration: () => BangumiAcceleration.mirror);
    await client.get('https://api.bgm.tv/v0/subjects/123');
    await client.post('https://api.bgm.tv/v0/search/subjects', data: {'keyword': 'show'});
    expect(adapter.requests, hasLength(2));
    for (final request in adapter.requests) {
      expect(request.headers.keys.map((key) => key.toLowerCase()), isNot(contains('authorization')));
    }
  });
}
