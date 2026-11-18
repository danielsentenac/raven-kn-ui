/// Client of `raven-kn serve`, and what a failed request means.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// State of the link to the server.
enum Conn {
  unknown,
  ok,

  /// The device has no network at all.
  noNetwork,

  /// The network works but the answer is not the server's: timeout, redirect or
  /// a login page. The Virgo portal session is closed or expired.
  portalClosed,

  /// The server answered and refused the token.
  unauthorized,

  /// The server answered with an error.
  serverError,

  /// No server address configured yet.
  notConfigured,
}

class ApiException implements Exception {
  ApiException(this.conn, this.message, {this.notFound = false});
  final Conn conn;
  final String message;
  final bool notFound;
  @override
  String toString() => message;
}

class Api {
  Api(String base, this.token, {http.Client? client, this.timeout = const Duration(seconds: 20)})
      : base = base.trim().replaceAll(RegExp(r'/+$'), ''),
        _client = client ?? http.Client();

  final String base;
  final String token;
  final Duration timeout;
  final http.Client _client;

  /// Set by tests: whether the device has a network interface.
  Future<bool> Function() hasNetwork = _hasNetwork;

  static Future<bool> _hasNetwork() async {
    try {
      final l = await NetworkInterface.list(includeLoopback: false);
      return l.isNotEmpty;
    } catch (_) {
      return true;
    }
  }

  Future<http.Response> _get(String path) async {
    if (base.isEmpty) throw ApiException(Conn.notConfigured, 'No server address set');
    final Uri uri;
    try {
      uri = Uri.parse('$base$path');
      if (!uri.hasScheme || uri.host.isEmpty) throw const FormatException();
    } on FormatException {
      throw ApiException(Conn.notConfigured, 'The server address is not a valid URL');
    }
    final req = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Accept'] = 'application/json';
    final http.Response r;
    try {
      r = await http.Response.fromStream(await _client.send(req).timeout(timeout));
    } on HandshakeException catch (e) {
      throw ApiException(Conn.serverError, 'TLS error: ${e.message}');
    } on Exception catch (e) {
      // socket error, timeout, connection refused or reset
      if (!await hasNetwork()) throw ApiException(Conn.noNetwork, 'No network connection');
      final what = e is TimeoutException ? 'no answer in ${timeout.inSeconds} s' : _short(e);
      throw ApiException(Conn.portalClosed, 'Server not reached ($what)');
    }
    if (r.headers['x-raven-kn'] == null) {
      // not our server: the portal answered in its place
      final what = r.statusCode >= 300 && r.statusCode < 400
          ? 'redirected to ${r.headers['location'] ?? 'another page'}'
          : 'HTTP ${r.statusCode} from another service';
      throw ApiException(Conn.portalClosed, 'The answer does not come from the server ($what)');
    }
    if (r.statusCode == 401) throw ApiException(Conn.unauthorized, 'The server refused the access token');
    if (r.statusCode == 404) throw ApiException(Conn.ok, 'Not found: $path', notFound: true);
    if (r.statusCode != 200) {
      var msg = 'HTTP ${r.statusCode}';
      try {
        msg = (jsonDecode(r.body) as Map)['error']?.toString() ?? msg;
      } catch (_) {}
      throw ApiException(Conn.serverError, 'Server error: $msg');
    }
    return r;
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 120 ? '${s.substring(0, 120)}...' : s;
  }

  Future<Map<String, dynamic>> getJson(String path) async {
    final r = await _get(path);
    try {
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(Conn.serverError, 'Unreadable answer for $path');
    }
  }

  Future<Uint8List> getBytes(String path) async => (await _get(path)).bodyBytes;

  void close() => _client.close();
}
