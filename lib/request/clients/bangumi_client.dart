import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/utils/bangumi_mirror_credentials.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/crypto.dart';

class BangumiClient {
  BangumiClient({Dio? dio, BangumiAcceleration Function()? acceleration})
      : _dio = dio,
        _acceleration = acceleration ?? (() => BangumiAcceleration.current);

  static final BangumiClient instance = BangumiClient();
  final Dio? _dio;
  final BangumiAcceleration Function() _acceleration;

  Future<dynamic> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await (_dio ?? DioFactory.bangumiDio).get(
        url,
        queryParameters: queryParameters,
        options: Options(
          headers: _headers(
            url: url,
            method: 'GET',
          ),
        ),
        cancelToken: cancelToken,
      );
      return response.data;
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Future<dynamic> post(
    String url, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await (_dio ?? DioFactory.bangumiDio).post(
        url,
        data: data,
        queryParameters: queryParameters,
        options: Options(
          headers: _headers(
            url: url,
            method: 'POST',
            data: data,
          ),
        ),
        cancelToken: cancelToken,
      );
      return response.data;
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Map<String, dynamic> _headers({
    required String url,
    required String method,
    Object? data,
  }) {
    final headers = <String, dynamic>{...bangumiHTTPHeader};
    if (_shouldSignProtectedMirrorRequest(url, method)) {
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final body = data == null ? '' : jsonEncode(data);
      headers['X-AppId'] = bangumiMirrorCredentials['id'];
      headers['X-Timestamp'] = timestamp;
      headers['X-Signature'] = generateBangumiMirrorSearchSignature(
        method: method,
        path: Uri.parse(url).path,
        body: body,
        timestamp: timestamp,
      );
    }
    return headers;
  }

  bool _shouldSignProtectedMirrorRequest(String url, String method) {
    final uri = Uri.parse(url);
    if (_acceleration() != BangumiAcceleration.mirror ||
        !ApiEndpoints.bangumiPublicApiHosts.contains(uri.host)) {
      return false;
    }
    final path = uri.path;
    if (method == 'POST' && path == '/v0/search/subjects') {
      return true;
    }
    if (method != 'GET') {
      return false;
    }
    return path.startsWith('/p1/subjects/') && path.endsWith('/comments') ||
        path.startsWith('/p1/episodes/') && path.endsWith('/comments') ||
        path.startsWith('/p1/characters/') && path.endsWith('/comments');
  }
}
