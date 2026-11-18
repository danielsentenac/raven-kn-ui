// Checks the first two steps of the portal login (page and key) without any
// credentials:  dart run tool/portal_probe.dart <portal URL> [certificate name]
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:raven_kn_logbook/src/portal.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('usage: dart run tool/portal_probe.dart <portal URL> [certificate name]');
    return;
  }
  final url = args[0];
  final cert = args.length > 1 ? args[1] : '';
  final s = PortalSession(url, certName: cert);
  try {
    final (a, page) = await s.send('GET', 'PortalMain', '');
    print('PortalMain: HTTP $a, ${page.length} characters, Check Point page: ${page.contains('cpRSA')}');
    final (b, body) = await s.send('POST', 'RSASettings', '');
    final j = jsonDecode(body) as Map<String, dynamic>;
    print('RSASettings: HTTP $b, key of ${(j['m'] as String).length * 4} bits, exponent ${j['e']}, '
        'token: ${j['loginToken'] != null}, already authenticated: ${j['isAuthenticated'] == true}');
  } catch (e) {
    print('failed: $e');
  } finally {
    s.close();
  }
}
