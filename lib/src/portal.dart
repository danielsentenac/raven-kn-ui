/// Login to the Virgo firewall portal (a Check Point captive portal) from the
/// application, as its own page does it:
///
/// 1. `GET  PortalMain`       opens a session (cookie);
/// 2. `POST RSASettings`      gives the public key (`m`, `e`, hex) and a one-time `loginToken`;
/// 3. `POST Login`            `realm=passwordRealm&username=..&password=<encrypted>`;
///    the answer is JSON with `type`: `SUCCESS`, `AUTH_FAILURE`, `SESSION_FAILURE`, `CHALLENGE`...
/// 4. `POST GetStateAndView`  moves the session to its final state, as the page does after a success.
///
/// The password is encrypted as in the page's `cpRSA.encrypt`: RSA on
/// `00 02 <random non-zero bytes> 00 <token + password> 00`, the result written
/// in hex with its bytes in reverse order. Read from the page served on
/// 2026-11-18; a firewall update may change it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Encrypted password field of the Login request.
String cpEncrypt(String modulusHex, String exponentHex, String token, String password, {Random? random}) {
  final n = BigInt.parse(modulusHex, radix: 16);
  final e = BigInt.parse(exponentHex, radix: 16);
  final k = (n.bitLength + 7) >> 3;
  final text = [...utf8.encode(token), ...utf8.encode(password)];
  if (k < text.length + 12) throw const FormatException('password too long for the portal key');
  final rng = random ?? Random.secure();
  final block = List<int>.filled(k, 0);
  block[1] = 2;
  final start = k - 1 - text.length; // the text, followed by one zero byte
  for (var i = 2; i < start - 1; i++) {
    block[i] = 1 + rng.nextInt(255);
  }
  block[start - 1] = 0;
  block.setRange(start, start + text.length, text);
  var m = BigInt.zero;
  for (final b in block) {
    m = (m << 8) | BigInt.from(b);
  }
  var hex = m.modPow(e, n).toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final out = StringBuffer();
  for (var j = hex.length - 2; j >= 0; j -= 2) {
    out.write(hex.substring(j, j + 2));
  }
  return out.toString();
}

class PortalResult {
  const PortalResult(this.ok, this.message, {this.refused = false});
  final bool ok;
  final String message;

  /// The portal refused the login or the password: do not try again with the same ones.
  final bool refused;
}

/// One request to the portal: (method, action such as `Login`, form body) -> (status, body).
typedef PortalSend = Future<(int, String)> Function(String method, String action, String body);

/// The login sequence on a transport (see [PortalSession] for the real one).
Future<PortalResult> portalLoginWith(PortalSend send, String user, String password, {Random? random}) async {
  try {
    final (s0, _) = await send('GET', 'PortalMain', '');
    if (s0 != 200) return PortalResult(false, 'the portal page answered HTTP $s0');
    for (var attempt = 0; attempt < 2; attempt++) {
      final (s1, b1) = await send('POST', 'RSASettings', '');
      final Map<String, dynamic> rsa;
      try {
        rsa = jsonDecode(b1) as Map<String, dynamic>;
      } catch (_) {
        return PortalResult(false, 'the portal did not give its key (HTTP $s1): its login procedure may have changed');
      }
      if (rsa['isAuthenticated'] == true) return const PortalResult(true, 'the portal session was already open');
      final m = rsa['m'], e = rsa['e'];
      if (s1 != 200 || m is! String || e is! String || m.isEmpty || e.isEmpty) {
        return const PortalResult(false, 'the portal did not give its key: its login procedure may have changed');
      }
      final enc = cpEncrypt(m, e, (rsa['loginToken'] as String?) ?? '', password, random: random);
      final (s2, b2) = await send('POST', 'Login',
          'realm=passwordRealm&username=${Uri.encodeQueryComponent(user)}&password=$enc');
      final Map<String, dynamic> ans;
      try {
        ans = jsonDecode(b2) as Map<String, dynamic>;
      } catch (_) {
        return PortalResult(false, 'unreadable answer to the login (HTTP $s2): the login procedure may have changed');
      }
      final type = ans['type']?.toString() ?? '';
      final msg = (ans['message']?.toString() ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim();
      switch (type) {
        case 'SUCCESS':
          try {
            await send('POST', 'GetStateAndView', '');
          } catch (_) {} // the session is open; this step only completes the page's own sequence
          return const PortalResult(true, 'logged in to the Virgo portal');
        case 'SESSION_FAILURE':
          continue; // the page asks for a new key and tries once more
        case 'CHALLENGE':
          return const PortalResult(false, 'the portal asks for a second step, which the application cannot do',
              refused: true);
        case 'AUTH_FAILURE':
          return PortalResult(false, 'the portal refused the login or the password${msg.isEmpty ? '' : ' ($msg)'}',
              refused: true);
        default:
          return PortalResult(false, 'the portal answered "$type"${msg.isEmpty ? '' : ': $msg'}');
      }
    }
    return const PortalResult(false, 'the portal session failed twice');
  } on HandshakeException catch (e) {
    return PortalResult(false, 'the portal certificate was not accepted (${e.message}): check the certificate name in Settings');
  } on TimeoutException {
    return const PortalResult(false, 'the portal did not answer');
  } on Exception catch (e) {
    final s = e.toString();
    return PortalResult(false, 'the portal was not reached (${s.length > 100 ? s.substring(0, 100) : s})');
  }
}

/// HTTPS session with the portal, with its cookies.
///
/// [certName]: the name on the portal's certificate when it differs from the
/// address (the firewall node `portal.example.org` presents the certificate of
/// `cert.example.org`). The connection then goes to the address, and the
/// certificate is checked, fully, against that name. Verification is never
/// switched off.
class PortalSession {
  PortalSession(String portalUrl, {String certName = '', this.timeout = const Duration(seconds: 20)})
      : _page = Uri.parse(portalUrl.trim()),
        _certName = certName.trim() {
    if (_certName.isNotEmpty && _certName != _page.host) {
      final target = _page.host, port = _page.hasPort ? _page.port : 443;
      _client.connectionFactory = (uri, proxyHost, proxyPort) {
        final socket = Socket.connect(target, port, timeout: timeout)
            .then<Socket>((s) => SecureSocket.secure(s, host: _certName));
        return Future.value(ConnectionTask.fromSocket(socket, () {}));
      };
    }
  }

  final Uri _page;
  final String _certName;
  final Duration timeout;
  final HttpClient _client = HttpClient()..findProxy = (_) => 'DIRECT';
  final Map<String, String> _cookies = {};

  Uri _uri(String action) {
    final u = _page.resolve(action);
    return _certName.isNotEmpty && _certName != _page.host ? u.replace(host: _certName) : u;
  }

  Future<(int, String)> send(String method, String action, String body) async {
    final req = await _client.openUrl(method, _uri(action)).timeout(timeout);
    req.followRedirects = false;
    if (_cookies.isNotEmpty) {
      req.headers.set(HttpHeaders.cookieHeader, _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
    }
    if (method == 'POST') {
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/x-www-form-urlencoded');
      req.write(body);
    }
    final res = await req.close().timeout(timeout);
    for (final c in res.cookies) {
      _cookies[c.name] = c.value;
    }
    final text = await res.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(timeout);
    return (res.statusCode, text);
  }

  void close() => _client.close(force: true);
}

/// Logs in to the portal at [portalUrl].
Future<PortalResult> portalLogin(String portalUrl, String certName, String user, String password) async {
  final Uri u;
  try {
    u = Uri.parse(portalUrl.trim());
  } on FormatException {
    return const PortalResult(false, 'the portal address is not a valid URL');
  }
  if (u.scheme != 'https' || u.host.isEmpty) {
    return const PortalResult(false, 'the portal address must start with https:// (the password is not sent otherwise)');
  }
  final session = PortalSession(portalUrl, certName: certName);
  try {
    return await portalLoginWith(session.send, user, password);
  } finally {
    session.close();
  }
}
