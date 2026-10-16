import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Backend base URL.
/// Web/desktop: http://localhost:8000 (default)
/// Android emulator: flutter run --dart-define=API_URL=http://10.0.2.2:8000
const String apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8000');

typedef Json = Map<String, dynamic>;

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => message;
}

class Api {
  static Future<dynamic> _get(String path) async {
    try {
      final r = await http.get(Uri.parse('$apiUrl$path')).timeout(const Duration(seconds: 15));
      return _decode(r);
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException(0, 'Backend not reachable at $apiUrl');
    }
  }

  static Future<dynamic> _send(String method, String path, [Object? body]) async {
    try {
      final req = http.Request(method, Uri.parse('$apiUrl$path'))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body ?? {});
      final streamed = await req.send().timeout(const Duration(seconds: 30));
      return _decode(await http.Response.fromStream(streamed));
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException(0, 'Backend not reachable at $apiUrl');
    }
  }

  static dynamic _decode(http.Response r) {
    final data = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 400) {
      final detail = data is Map ? data['detail'] : null;
      throw ApiException(r.statusCode, detail is String ? detail : 'Request failed (${r.statusCode})');
    }
    return data;
  }

  static Future<Json> health() async => await _get('/health') as Json;
  static Future<Json> person() async => await _get('/person') as Json;
  static Future<List<dynamic>> records() async => await _get('/records') as List<dynamic>;
  static Future<Json> record(String id) async => await _get('/records/$id') as Json;
  static Future<Json> preparation() async => await _get('/preparation') as Json;
  static Future<Json> latestChange() async => await _get('/changes/latest') as Json;
  static Future<Json> graph() async => await _get('/graph') as Json;
  static Future<Json> nextDemoRecord() async => await _get('/demo/next-record') as Json;

  static Future<Json> preview(String title, String date, String text) async =>
      await _send('POST', '/records/preview', {'title': title, 'date': date, 'text': text}) as Json;
  static Future<Json> confirm(String id, List<dynamic> facts) async =>
      await _send('POST', '/records/$id/confirm', {'facts': facts}) as Json;
  static Future<void> discard(String id) async => await _send('DELETE', '/records/$id');
  static Future<Json> ask(String q, String lang) async =>
      await _send('POST', '/ask', {'question': q, 'lang': lang}) as Json;
  static Future<Json> resetDemo() async => await _send('POST', '/demo/reset') as Json;
}

/// Bumped whenever graph data changes, so screens refetch.
final dataVersion = ValueNotifier<int>(0);
void refreshAll() => dataVersion.value++;
