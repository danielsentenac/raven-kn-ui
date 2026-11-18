import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:raven_kn_logbook/src/api.dart';
import 'package:raven_kn_logbook/src/archive.dart';
import 'package:raven_kn_logbook/src/portal.dart';
import 'package:raven_kn_logbook/src/state.dart';

import 'support.dart';

// A 1024-bit test key (generated for this test; e = 0x11 as the portal's).
const _n = 'bedb6459e0dc8ba3dd3268c8454da4ff4c6c0759d7787e3f082500723041c4a47b0ccc30b7a7a344f9fef6740ae19346bbf3ef72172a0fdf783c8facc7d9e07fa5eb53ce6315e8a07cf5180efc8995663a3d8483ce280805db610ab401cbe28b60c559fb7dc58e8a322a15c135506e2b6f967bb3472c1862c2475a31f335a63f';
const _d = '59d0a7b1d33a9c10e090314f2fac116914e78afd1a1a95c34f2078ae34d3a7d4ee9c9c53293fd45cb1e164eb506a27305872cb08835f168747a407605e0c2d686dca50632f7cb45b1e958adef8c71cf8f9af97bf7cc07aa79c89f6604bc58c68868526de2e287770cebdebe68e0935fe8155496fd39b29cfb9f62a22574d1b71';
const _e = '00000011';

/// What the portal recovers from the encrypted field: the padded block.
List<int> decrypt(String field) {
  final hex = StringBuffer();
  for (var j = field.length - 2; j >= 0; j -= 2) {
    hex.write(field.substring(j, j + 2)); // bytes back in order
  }
  final m = BigInt.parse(hex.toString(), radix: 16).modPow(BigInt.parse(_d, radix: 16), BigInt.parse(_n, radix: 16));
  return [for (var s = m.toRadixString(16).padLeft(256, '0'), i = 0; i < 256; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];
}

void main() {
  test('the password is encrypted as the portal page does it', () {
    for (final pw in ['secret', 'pä55 wörd €', 'x' * 60]) {
      final field = cpEncrypt(_n, _e, 'f5d4d8f49ff1aa94', pw, random: Random(1));
      expect(field.length, 256);
      final b = decrypt(field);
      final text = utf8.encode('f5d4d8f49ff1aa94$pw');
      expect(b.sublist(0, 2), [0, 2]);
      expect(b.last, 0); // the page adds a zero byte after the text
      expect(b.sublist(128 - 1 - text.length, 127), text);
      expect(b[128 - 2 - text.length], 0);
      expect(b.sublist(2, 128 - 2 - text.length).every((x) => x != 0), isTrue);
    }
    expect(cpEncrypt(_n, _e, 't', 'p'), isNot(cpEncrypt(_n, _e, 't', 'p'))); // random padding
    expect(() => cpEncrypt(_n, _e, 't', 'x' * 120), throwsFormatException);
  });

  group('login sequence', () {
    PortalSend portal(List<String> log, {String type = 'SUCCESS', bool already = false, List<String>? types}) {
      var logins = 0;
      return (method, action, body) async {
        log.add('$method $action');
        switch (action) {
          case 'PortalMain':
            return (200, '<html>');
          case 'RSASettings':
            return (200, jsonEncode({'m': _n, 'e': _e, 'loginToken': 'tok', if (already) 'isAuthenticated': true}));
          case 'Login':
            final q = Uri.splitQueryString(body);
            expect(q['realm'], 'passwordRealm');
            expect(q['username'], 'user name');
            expect(utf8.decode(decrypt(q['password']!).sublist(128 - 1 - 6, 127)), 'tokpw1');
            expect(body.contains('pw1'), isFalse);
            final t = types != null ? types[logins++] : type;
            return (200, jsonEncode({'type': t, 'message': t == 'AUTH_FAILURE' ? '<b>Wrong</b> credentials' : ''}));
          default:
            return (200, '{}');
        }
      };
    }

    test('success', () async {
      final log = <String>[];
      final r = await portalLoginWith(portal(log), 'user name', 'pw1');
      expect(r.ok, isTrue);
      expect(log, ['GET PortalMain', 'POST RSASettings', 'POST Login', 'POST GetStateAndView']);
    });
    test('session already open: no password sent', () async {
      final log = <String>[];
      expect((await portalLoginWith(portal(log, already: true), 'user name', 'pw1')).ok, isTrue);
      expect(log, isNot(contains('POST Login')));
    });
    test('refused credentials', () async {
      final r = await portalLoginWith(portal([]), 'user name', 'pw1').then((_) => portalLoginWith(portal([], type: 'AUTH_FAILURE'), 'user name', 'pw1'));
      expect(r.ok, isFalse);
      expect(r.refused, isTrue);
      expect(r.message, contains('Wrong credentials'));
    });
    test('a session failure is retried once with a new key', () async {
      final log = <String>[];
      final r = await portalLoginWith(portal(log, types: ['SESSION_FAILURE', 'SUCCESS']), 'user name', 'pw1');
      expect(r.ok, isTrue);
      expect(log.where((l) => l == 'POST RSASettings').length, 2);
    });
    test('a changed procedure is reported, not guessed', () async {
      final r = await portalLoginWith((m, a, b) async => (200, a == 'PortalMain' ? '<html>' : '<html>new page</html>'), 'u', 'p');
      expect(r.ok, isFalse);
      expect(r.refused, isFalse);
      expect(r.message, contains('may have changed'));
    });
    test('plain http is refused before anything is sent', () async {
      final r = await portalLogin('http://portal.example/connect/PortalMain', '', 'u', 'p');
      expect(r.ok, isFalse);
      expect(r.message, contains('https'));
    });
  });

  group('automatic login at sync', () {
    test('logs in when the server is not reached, then syncs', () async {
      var open = false;
      final calls = <List<String>>[];
      final s = AppState(Archive.memory(),
          clientFactory: () => open ? fixtureServer() : MockClient((_) async => http.Response('<html>login</html>', 200)),
          portalLogin: (url, cert, user, pw) async {
            calls.add([url, cert, user, pw]);
            open = true;
            return const PortalResult(true, 'logged in');
          });
      s.saveSettings(serverUrl: 'http://server:8765', token: 'lvktok', portalUrl: 'https://portal.example/login');
      s.savePortalLogin(user: 'me', password: 'pw', auto: true, certName: 'cert.example');
      await s.sync();
      expect(s.conn, Conn.ok, reason: s.connMessage);
      expect(s.connMessage, contains('after logging in to the portal'));
      expect(calls, [
        ['https://portal.example/login', 'cert.example', 'me', 'pw']
      ]);
      expect(s.archive.count(const LogQuery()), greaterThan(50));
      await s.sync(); // session open: no new login
      expect(calls.length, 1);
    });

    test('a refusal stops further automatic logins', () async {
      var n = 0;
      final s = AppState(Archive.memory(),
          clientFactory: () => MockClient((_) async => http.Response('<html>login</html>', 200)),
          portalLogin: (url, cert, user, pw) async {
            n++;
            return const PortalResult(false, 'the portal refused the login or the password', refused: true);
          });
      s.saveSettings(serverUrl: 'http://server:8765', token: 't', portalUrl: 'https://portal.example/login');
      s.savePortalLogin(user: 'me', password: 'wrong', auto: true);
      await s.sync();
      await s.sync();
      await s.sync();
      expect(n, 1);
      expect(s.conn, Conn.portalClosed);
      expect(s.portalRefused, isTrue);
      expect(s.connMessage, contains('Automatic login is stopped'));
      s.savePortalLogin(user: 'me', password: 'right', auto: true); // saved again: allowed again
      await s.sync();
      expect(n, 2);
    });

    test('no login without stored credentials, or when switched off', () async {
      var n = 0;
      AppState make() => AppState(Archive.memory(),
          clientFactory: () => MockClient((_) async => http.Response('<html>login</html>', 200)),
          portalLogin: (a, b, c, d) async {
            n++;
            return const PortalResult(true, '');
          })
        ..saveSettings(serverUrl: 'http://server:8765', token: 't', portalUrl: 'https://portal.example/login');
      await make().sync();
      await (make()..savePortalLogin(user: 'me', password: 'pw', auto: false)).sync();
      expect(n, 0);
    });
  });
}
