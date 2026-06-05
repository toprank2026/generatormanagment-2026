import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:generatormanagment/core/api_config.dart';
import 'package:generatormanagment/core/logger.dart';
import 'package:generatormanagment/core/secure_store.dart';

/// Raised for any non-2xx response or transport failure.
/// [statusCode] == 0 means a network/timeout error (offline).
class ApiException implements Exception {
  final int statusCode;
  final String message;
  final dynamic body;
  ApiException(this.statusCode, this.message, [this.body]);

  bool get isAuthError => statusCode == 401 || statusCode == 403;
  bool get isNetworkError => statusCode == 0;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Single REST client for the accounts-only backend. Injects the Bearer JWT,
/// decodes JSON, and normalises errors into [ApiException].
class ApiClient {
  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;
  ApiClient._internal();

  final SecureStore _store = SecureStore();

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final uri = Uri.parse('${ApiConfig.baseUrl}$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(
      queryParameters: query.map((k, v) => MapEntry(k, '$v')),
    );
  }

  Future<Map<String, String>> _headers({bool auth = true, bool json = true}) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (json) headers['Content-Type'] = 'application/json';
    if (auth) {
      final token = await _store.readToken();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }
    return headers;
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query, bool auth = true}) {
    return _wrap('GET', path, () async {
      final h = await _headers(auth: auth, json: false);
      return http.get(_uri(path, query), headers: h).timeout(ApiConfig.timeout);
    });
  }

  Future<dynamic> post(String path, {Object? body, bool auth = true}) {
    return _wrap('POST', path, () async {
      final h = await _headers(auth: auth);
      return http
          .post(_uri(path), headers: h, body: body == null ? null : jsonEncode(body))
          .timeout(ApiConfig.timeout);
    });
  }

  Future<dynamic> put(String path, {Object? body, bool auth = true}) {
    return _wrap('PUT', path, () async {
      final h = await _headers(auth: auth);
      return http
          .put(_uri(path), headers: h, body: body == null ? null : jsonEncode(body))
          .timeout(ApiConfig.timeout);
    });
  }

  Future<dynamic> delete(String path, {Object? body, bool auth = true}) {
    return _wrap('DELETE', path, () async {
      final h = await _headers(auth: auth);
      return http
          .delete(_uri(path), headers: h, body: body == null ? null : jsonEncode(body))
          .timeout(ApiConfig.timeout);
    });
  }

  /// Multipart upload (used for cloud DB backup). [fields] are extra text fields.
  Future<dynamic> uploadFile(
    String path, {
    required String filePath,
    String field = 'file',
    Map<String, String>? fields,
    bool auth = true,
  }) {
    return _wrap('POST(multipart)', path, () async {
      final request = http.MultipartRequest('POST', _uri(path));
      request.headers.addAll(await _headers(auth: auth, json: false));
      if (fields != null) request.fields.addAll(fields);
      request.files.add(await http.MultipartFile.fromPath(field, filePath));
      final streamed = await request.send().timeout(ApiConfig.timeout);
      return http.Response.fromStream(streamed);
    });
  }

  /// Raw byte download (used to restore a cloud backup).
  Future<Uint8List> downloadBytes(String path, {bool auth = true}) async {
    try {
      final h = await _headers(auth: auth, json: false);
      final res = await http.get(_uri(path), headers: h).timeout(ApiConfig.timeout);
      if (res.statusCode >= 200 && res.statusCode < 300) return res.bodyBytes;
      throw ApiException(res.statusCode, _extractMessage(_tryDecode(res.body)) ?? 'Download failed');
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException(0, 'Connection timed out');
    } catch (e) {
      throw ApiException(0, 'Network error: $e');
    }
  }

  Future<dynamic> _wrap(
    String method,
    String path,
    Future<http.Response> Function() run,
  ) async {
    try {
      final res = await run();
      Log.d('$method $path -> ${res.statusCode}');
      final decoded = res.body.isEmpty ? null : _tryDecode(res.body);
      if (res.statusCode >= 200 && res.statusCode < 300) return decoded;
      throw ApiException(
        res.statusCode,
        _extractMessage(decoded) ?? 'Request failed (${res.statusCode})',
        decoded,
      );
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException(0, 'Connection timed out');
    } catch (e) {
      Log.e('$method $path failed', e);
      throw ApiException(0, 'Network error: $e');
    }
  }

  dynamic _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return body;
    }
  }

  String? _extractMessage(dynamic decoded) {
    if (decoded is Map && decoded['message'] is String) return decoded['message'] as String;
    return null;
  }
}
