import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The answers of `raven-kn serve` on the fixture store (tool/capture_fixtures.py).
final Map<String, dynamic> captured = jsonDecode(File('test/fixtures/api.json').readAsStringSync()) as Map<String, dynamic>;

/// A server giving the captured answers; [requests] counts them.
http.Client fixtureServer({List<String>? requests, String token = 'lvktok'}) => MockClient((req) async {
      const h = {'x-raven-kn': '1', 'content-type': 'application/json'};
      if (req.headers['Authorization'] != 'Bearer $token') {
        return http.Response('{"service":"raven-kn","error":"unauthorized"}', 401, headers: h);
      }
      final path = req.url.path + (req.url.hasQuery ? '?${req.url.query}' : '');
      requests?.add(path);
      final blobs = (captured['blobs'] as Map).cast<String, dynamic>();
      if (blobs.containsKey(path)) {
        return http.Response.bytes(base64Decode(blobs[path] as String), 200,
            headers: {'x-raven-kn': '1', 'content-type': 'application/octet-stream'});
      }
      final json = (captured['json'] as Map).cast<String, dynamic>();
      final key = json.keys.firstWhere((k) => Uri.parse(k).path == req.url.path && (Uri.parse(k).query == req.url.query),
          orElse: () => '');
      if (key.isEmpty) return http.Response('{"service":"raven-kn","error":"not found"}', 404, headers: h);
      return http.Response.bytes(utf8.encode(jsonEncode(json[key])), 200, headers: h);
    });
