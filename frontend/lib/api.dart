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
  static Uri _uri(String path, [String? personId]) => Uri.parse('$apiUrl$path').replace(
        queryParameters: personId == null ? null : {'person_id': personId},
      );

  static Future<dynamic> _get(String path, [String? personId]) async {
    try {
      final r = await http.get(_uri(path, personId)).timeout(const Duration(seconds: 15));
      return _decode(r);
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException(0, 'Backend not reachable at $apiUrl');
    }
  }

  static Future<dynamic> _send(String method, String path, {String? personId, Object? body}) async {
    try {
      final req = http.Request(method, _uri(path, personId))
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

  // ---- profiles ----
  static Future<List<dynamic>> people() async => await _get('/people') as List<dynamic>;
  static Future<Json> person(String id) async => await _get('/people/$id') as Json;
  static Future<Json> createPerson(String name, String relation, String? caregiver) async =>
      await _send('POST', '/people',
          body: {'name': name, 'relation': relation, 'caregiver': caregiver}) as Json;
  static Future<void> deletePerson(String id) async => await _send('DELETE', '/people/$id');

  // ---- one profile's records ----
  static Future<List<dynamic>> records(String pid) async =>
      await _get('/records', pid) as List<dynamic>;
  static Future<Json> record(String pid, String id) async => await _get('/records/$id', pid) as Json;
  static Future<Json> preparation(String pid) async => await _get('/preparation', pid) as Json;
  static Future<Json> latestChange(String pid) async => await _get('/changes/latest', pid) as Json;
  static Future<Json> graph(String pid) async => await _get('/graph', pid) as Json;

  static Future<Json> preview(String pid, String title, String date, String text) async =>
      await _send('POST', '/records/preview',
          personId: pid, body: {'title': title, 'date': date, 'text': text}) as Json;
  static Future<Json> confirm(String pid, String id, List<dynamic> facts) async =>
      await _send('POST', '/records/$id/confirm', personId: pid, body: {'facts': facts}) as Json;
  static Future<void> discard(String pid, String id) async =>
      await _send('DELETE', '/records/$id', personId: pid);
  static Future<Json> ask(String pid, String q, String lang) async =>
      await _send('POST', '/ask', personId: pid, body: {'question': q, 'lang': lang}) as Json;
}

/// Bumped whenever graph data changes, so screens refetch.
final dataVersion = ValueNotifier<int>(0);
void refreshAll() => dataVersion.value++;
