import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:raven_kn_logbook/src/api.dart';
import 'package:raven_kn_logbook/src/archive.dart';
import 'package:raven_kn_logbook/src/followup.dart';
import 'package:raven_kn_logbook/src/healpix.dart';
import 'package:raven_kn_logbook/src/state.dart';
import 'package:raven_kn_logbook/src/ui/candidates.dart' show distanceText, filterOf, timeUnit;
import 'package:raven_kn_logbook/src/ui/history.dart' show sinceFirst;
import 'package:raven_kn_logbook/src/ui/logbook.dart' show exportEntries;
import 'package:raven_kn_logbook/src/ui/plots.dart';
import 'package:raven_kn_logbook/src/ui/reported.dart';

import 'support.dart';

void main() {
  test('the unit of a light-curve time axis follows its span', () {
    expect(timeUnit([0, 12.5]), ('days', 1));
    expect(timeUnit([0, 0.5, 2.9]), ('hours', 24));
    expect(timeUnit([-0.001, 0.03]), ('minutes', 1440));
    expect(timeUnit([0, 1.2e-4]), ('seconds', 86400)); // a magnitude 10 s before its burst
    expect(timeUnit([0.4]), ('days', 1));
    expect(timeUnit([]), ('days', 1));
  });

  test('what a broker has at the position of a transient', () {
    expect(
        brokerFacts({
          'object': 'ZTF21abasjty', 'sep_arcsec': 0.0127, 'others': ['ZTF2'], 'n_detections': 16,
          'first_detection': '2025-11-11T11:51:25.004Z', 'last_detection': '2025-12-21T12:51:13.999Z',
          'classification': 'SN', 'classification_text': 'supernova',
          'tns': {'name': 'AT 2017gfo', 'type': null, 'z': null},
          'host': {'name': 'NGC 4993', 'catalogue': 'NED', 'z': 0.0098, 'photo_z': 0.2, 'sep_arcsec': 10.3, 'sep_kpc': 2.1, 'distance_mpc': 41.0},
        }),
        [
          ('Object', 'ZTF21abasjty, 0.0127 arcsec from the position'),
          ('Others in the radius', 'ZTF2'),
          ('Detections', '16, first 2025-11-11 11:51 UTC, last 2025-12-21 12:51 UTC'),
          ('Classification', 'SN (supernova)'),
          ('TNS', 'AT 2017gfo'),
          ('Proposed host', 'NGC 4993 (NED), z = 0.0098, 10.3 arcsec away, 2.1 kpc, 41 Mpc'),
        ]);
    expect(brokerFacts({'status': 'none', 'host': {'name': 'G1', 'photo_z': 0.157, 'photo_z_err': 0.136}}),
        [('Proposed host', 'G1, photometric z = 0.157 ± 0.136')]);
    expect(brokerFacts({'status': 'error', 'note': 'x'}), isEmpty);
  });

  test('values reported in circulars are shown as written', () {
    expect(factValue({'value': 7.447, 'err_minus': 0.084, 'err_plus': 0.121, 'unit': 's'}), '7.447 (-0.084 +0.121) s');
    expect(factValue({'value': 2.05e-5, 'err_minus': 2.0e-6, 'err_plus': 1.5e-6, 'unit': 'erg/cm^2'}), '(2.05 (-0.2 +0.15))e-5 erg/cm^2');
    expect(factValue({'value': 9.49e52, 'err_minus': 1.65e52, 'err_plus': 1.65e52, 'unit': 'erg'}), '(9.49 ± 1.65)e52 erg');
    expect(factValue({'value': 0.2, 'unit': 'mJy', 'approx': true}), 'about 0.2 mJy');
    expect(factValue({'value': -3.1, 'unit': '', 'limit': true}), 'limit -3.1');
    expect(factValue({'value': null, 'what': 'likely long'}), 'likely long');
    expect(factValue({'kind': 'redshift', 'value': 3.58, 'what': 'spectroscopic'}), '3.58 (spectroscopic)');
  });

  test('what the circulars report about the alerts of a follow-up', () {
    final circulars = [
      {
        'id': 2, 'subject': 'B', 'redshift': 0.4, 'redshift_kind': 'spectroscopic',
        'links': [{'type': 'grb', 'id': '7'}],
        'facts': [{'category': 'afterglow', 'kind': 'decay_index', 'value': -0.8}],
        'photometry': [{'band': 'r', 'mag': 20.1}],
      },
      {
        'id': 1, 'subject': 'A',
        'links': [{'type': 'grb', 'id': '7'}],
        'facts': [{'category': 'prompt', 'kind': 't90', 'value': 2.0}],
        'web_links': [{'url': 'https://example.org/a.png', 'kind': 'image'}],
      },
      {
        'id': 3, 'subject': 'other burst',
        'links': [{'type': 'grb', 'id': '8'}],
        'facts': [{'category': 'prompt', 'kind': 't90', 'value': 99.0}],
      },
      {'id': 4, 'subject': 'older server: no facts', 'links': [{'type': 'grb', 'id': '7'}]},
    ];
    final r = reportedOf(circulars, {'grb:7', 'optical:X'});
    expect(r['prompt']!.map((f) => (f['value'], f['circular'], f['subject'])), [(2.0, 1, 'A')]);
    expect(r['afterglow']!.single['circular'], 2);
    expect(r['spectroscopy']!.single['kind'], 'redshift');
    expect(r['photometry']!.single['mag'], 20.1);
    expect(r['links']!.single['url'], 'https://example.org/a.png');
    expect(reportedOf(circulars, {'grb:nothing'}).values.every((v) => v.isEmpty), isTrue);
    // GCN 46283: the plot of the burst goes with the prompt emission, the page of the telescope is left out
    final hx = reportedOf([
      {
        'id': 46283, 'subject': 'GRB 261113B: Insight-HXMT/HE detection', 'bands': ['gamma'],
        'links': [{'type': 'grb', 'id': '7'}],
        'web_links': [
          {'url': 'https://www.bursthub.cn/gcn/2026/hxmtgrb261113B.png', 'kind': 'image', 'about': 'light curve'},
          {'url': 'http://hxmten.ihep.ac.cn/', 'kind': 'page', 'about': null},
          {'url': 'https://heasarc.gsfc.nasa.gov/x/glg_skymap_all_bn261111477.png', 'kind': 'image', 'about': 'sky map'},
        ],
      },
      {
        'id': 46261, 'subject': 'GRB 261113A: VLT/X-shooter spectroscopic redshift', 'bands': ['optical'],
        'links': [{'type': 'grb', 'id': '7'}],
        'web_links': [
          {'url': 'https://example.org/GRB261113A/spectrum.png', 'kind': 'image', 'about': null},
          {'url': 'https://example.org/GRB261113A/lc.png', 'kind': 'image', 'about': 'light curve', 'general': false},
          {'url': 'https://example.org/GRB261113A/', 'kind': 'page', 'general': true},
        ],
      },
    ], {'grb:7'})['links']!;
    expect(hx.map((l) => l['category']), ['spectroscopy', 'afterglow', 'prompt', 'sky']);
  });

  test('a distance that is only the prior is not shown as an estimate', () {
    String range(Map? m, String unit) => '${m?['median']} $unit';
    final prior = {
      'luminosity_distance_mpc': {'median': 1194, 'lower': 554, 'upper': 1475},
      'constraints': ['prompt GRB theta<~30.0 deg'],
      'distance_prior': 'uniform in volume, D_L < 1500.0 Mpc',
    };
    expect(distanceText(prior, range), 'not constrained (no redshift or distance; assumed below 1500 Mpc)');
    expect(distanceText({...prior, 'distance_informed': false}, range), contains('not constrained'));
    expect(
        distanceText({
          ...prior,
          'constraints': ['redshift(spectroscopic) z=0.01', 'prompt GRB theta<~30.0 deg']
        }, range),
        '1194 Mpc');
    expect(distanceText({...prior, 'distance_informed': true}, range), '1194 Mpc');
  });

  test('ang2pixNest agrees with healpy', () {
    final ref = (jsonDecode(File('test/fixtures/healpix.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();
    expect(ref.length, greaterThan(1000));
    for (final r in ref) {
      // an exact pixel corner belongs to either neighbour, depending on rounding
      if (r['dec'] == 0) continue;
      expect(ang2pixNest(r['order'] as int, (r['ra'] as num).toDouble(), (r['dec'] as num).toDouble()), r['pix'],
          reason: 'order ${r['order']} ra ${r['ra']} dec ${r['dec']}');
    }
  });

  test('projections invert', () {
    for (final SkyProjection p in [Mollweide(), ZoomView(197.45, -23.38, 10), ZoomView(10, 80, 30)]) {
      for (final (ra, dec) in p is Mollweide ? [(10.0, 20.0), (200.0, -60.0), (350.0, 85.0)] : [(p is ZoomView ? p.ra0 + 3 : 0.0, (p as ZoomView).dec0 - 4)]) {
        final f = p.forward(ra, dec)!;
        final b = p.inverse(f.$1, f.$2)!;
        expect(separationDeg(ra, dec, b.$1, b.$2), lessThan(1e-6));
      }
    }
    expect(Mollweide().inverse(0.99, 0.9), isNull); // outside the ellipse
    final east = Mollweide().forward(190, 0)!, west = Mollweide().forward(170, 0)!;
    expect(east.$1, lessThan(west.$1)); // RA increases to the left
    final (ra, dec) = offsetBy(0, 0, 10, 90);
    expect(ra, closeTo(10, 1e-9));
    expect(dec, closeTo(0, 1e-9));
  });

  group('what a failed request means', () {
    Future<Conn> conn(MockClientHandler h, {bool network = true}) async {
      final api = Api('http://server:8765', 't', client: MockClient(h), timeout: const Duration(milliseconds: 200))
        ..hasNetwork = () async => network;
      try {
        await api.getJson('/api/health');
        return Conn.ok;
      } on ApiException catch (e) {
        return e.conn;
      }
    }

    const ours = {'x-raven-kn': '1'};
    test('our server', () async => expect(await conn((_) async => http.Response('{"service":"raven-kn"}', 200, headers: ours)), Conn.ok));
    test('token refused', () async => expect(await conn((_) async => http.Response('{}', 401, headers: ours)), Conn.unauthorized));
    test('portal login page', () async => expect(await conn((_) async => http.Response('<html>login</html>', 200)), Conn.portalClosed));
    test('portal redirect', () async =>
        expect(await conn((_) async => http.Response('', 302, headers: {'location': 'https://portal/login'})), Conn.portalClosed));
    test('portal 401 is not a token problem', () async => expect(await conn((_) async => http.Response('denied', 401)), Conn.portalClosed));
    test('unreachable with network', () async => expect(await conn((_) => throw const SocketException('refused')), Conn.portalClosed));
    test('no answer', () async => expect(await conn((_) => Completer<http.Response>().future), Conn.portalClosed));
    test('no network', () async => expect(await conn((_) => throw const SocketException('down'), network: false), Conn.noNetwork));
    test('server error', () async => expect(await conn((_) async => http.Response('{"error":"x"}', 500, headers: ours)), Conn.serverError));
    test('no address', () async {
      try {
        await Api('', 't').getJson('/api/health');
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.conn, Conn.notConfigured);
      }
    });
  });

  group('sync into the archive', () {
    AppState make({http.Client Function()? client}) {
      final s = AppState(Archive.memory(), clientFactory: client ?? () => fixtureServer());
      s.saveSettings(serverUrl: 'http://server:8765', token: 'lvktok', portalUrl: 'https://portal.example/login');
      return s;
    }

    test('first sync stores everything; the second brings nothing new', () async {
      final requests = <String>[];
      final s = make(client: () => fixtureServer(requests: requests));
      expect(s.conn, Conn.unknown);
      await s.sync();
      expect(s.conn, Conn.ok, reason: s.connMessage);
      final n = s.archive.count(const LogQuery());
      expect(n, ((captured['json'] as Map)['/api/events?limit=2000&cursor='] as Map)['events'].length);
      expect(s.batch, 1);
      expect(s.opticals.map((c) => c['name']), containsAll(['SSS17a', 'FIX-KN-1']));
      expect(s.archive.doc('optical/SSS17a')!['steps'], isNotEmpty);
      expect(s.archive.doc('run/SSS17a/SSS17a_GRB_window_coherent')!['snr'], isNotNull);
      expect(s.archive.blob('map/S261020fx/2/gw'), isNotNull);
      expect(s.archive.blob('map/GW170817/1/gw'), isNotNull);
      expect(gzip.decode(s.archive.blob('map/S261020fx/1/gw')!).length, 12 * 128 * 128);
      // no Virgo targeted-search token here: nothing to say about it
      expect(s.virgoSearchToken, '');
      expect(s.virgoSearchStatus, isNull);
      // GCN Circulars: the list, and the text of each one
      expect(s.circulars.map((c) => c['id']), [90001, 90002, 90003, 90004, 90005, 90006, 90007, 90008]);
      expect(s.circulars.first.containsKey('body'), isFalse);
      expect(s.archive.doc('circular/90005')!['body'], contains('X-shooter'));
      expect(requests.where((r) => r.startsWith('/api/circulars/')).length, 8);

      requests.clear();
      await s.sync();
      expect(s.conn, Conn.ok);
      expect(s.archive.count(const LogQuery()), n);
      expect(s.batch, 1);
      expect(s.connMessage, 'Up to date');
      // nothing changed: no candidate page, no run, no map fetched again
      expect(requests.where((r) => r.startsWith('/api/optical/') || r.startsWith('/api/runs/') || r.contains('/map/')), isEmpty);
    });

    test('a closed portal leaves the archive readable', () async {
      var open = true;
      final s = make(client: () => open ? fixtureServer() : MockClient((_) async => http.Response('<html>Virgo login</html>', 200)));
      await s.sync();
      final n = s.archive.count(const LogQuery());
      final when = s.lastSync;
      open = false;
      await s.sync();
      expect(s.conn, Conn.portalClosed);
      expect(s.lastSync, when);
      expect(s.archive.count(const LogQuery()), n);
      expect(s.archive.doc('optical/SSS17a'), isNotNull);
    });

    test('the portal address is empty until it is set', () {
      final s = AppState(Archive.memory());
      expect(s.portalUrl, '');
      expect(s.portalCertName, '');
      s.savePortalLogin(user: 'me', password: 'pw', auto: true);
      expect(s.canAutoLogin, isFalse); // no portal address: no automatic login
      s.saveSettings(serverUrl: 'http://server:8765', token: 't', portalUrl: 'https://other.example/login');
      expect(s.portalUrl, 'https://other.example/login');
    });

    test('another server address replaces the local copy; the same one keeps it', () async {
      final s = make();
      await s.sync();
      expect(s.archive.count(const LogQuery()), greaterThan(50));
      expect(s.wouldReplaceData('http://server:8765/'), isFalse); // the same server
      s.saveSettings(serverUrl: 'http://server:8765/', token: 'lvktok', portalUrl: '');
      expect(s.archive.count(const LogQuery()), greaterThan(50));
      expect(s.wouldReplaceData('http://other.example:8765'), isTrue);
      s.saveSettings(serverUrl: 'http://other.example:8765', token: 'lvktok', portalUrl: '');
      expect(s.archive.count(const LogQuery()), 0);
      expect(s.archive.doc('sky'), isNull);
      expect(s.archive.blob('map/GW170817/1/gw'), isNull);
      expect(s.lastSync, isNull);
      expect(s.token, 'lvktok'); // settings are kept
      await s.sync(); // and the new server is read from its beginning
      expect(s.archive.count(const LogQuery()), greaterThan(50));
      expect(s.batch, 1);
    });

    test('the Virgo targeted-search token is sent beside the reading token, and its answer kept', () async {
      String? sent;
      Map<String, dynamic> virgo = {'configured': true, 'granted': true};
      final s = make(client: () => MockClient((req) async {
            sent = req.headers['X-Raven-KN-Virgo-Search'];
            expect(req.headers['Authorization'], 'Bearer lvktok');
            if (req.url.path != '/api/health') return http.Response('{"service":"raven-kn","error":"not found"}', 404, headers: {'x-raven-kn': '1'});
            return http.Response(jsonEncode({'service': 'raven-kn', 'lvk': true, 'targeted_search': {'virgo': virgo}}), 200, headers: {'x-raven-kn': '1'});
          }));
      s.saveSettings(serverUrl: 'http://server:8765', token: 'lvktok', portalUrl: '', virgoSearchToken: ' vts ');
      expect(s.virgoSearchToken, 'vts');
      await s.sync();
      expect(sent, 'vts');
      expect(s.virgoSearchStatus, 'granted');
      virgo = {'configured': true, 'granted': false};
      await s.sync();
      expect(s.virgoSearchStatus, 'refused');
      virgo = {'configured': false, 'granted': false};
      await s.sync();
      expect(s.virgoSearchStatus, 'not configured');
      // another save without the token keeps it; an empty one removes it
      s.saveSettings(serverUrl: 'http://server:8765', token: 'lvktok', portalUrl: '');
      expect(s.virgoSearchToken, 'vts');
      s.saveSettings(serverUrl: 'http://server:8765', token: 'lvktok', portalUrl: '', virgoSearchToken: '');
      expect(s.virgoSearchToken, '');
      expect(s.virgoSearchStatus, isNull);
    });

    test('a targeted search is asked for with both tokens; a refusal gives its reason', () async {
      final posts = <(String, String, String?)>[];
      var answer = http.Response('{"launch":{"id":"X","status":"requested"}}', 200, headers: {'x-raven-kn': '1'});
      final fixture = fixtureServer();
      final s = make(client: () => MockClient((req) async {
            if (req.method == 'POST') {
              posts.add((req.url.path, req.body, req.headers['X-Raven-KN-Virgo-Search']));
              expect(req.headers['Authorization'], 'Bearer lvktok');
              return answer;
            }
            return fixture.get(req.url, headers: req.headers);
          }));
      s.saveSettings(serverUrl: 'http://server:8765', token: 'lvktok', portalUrl: '', virgoSearchToken: 'vts');
      await s.sync();
      expect(s.conn, Conn.ok, reason: s.connMessage);
      expect(s.canStartSearch, isFalse); // the captured server does not know that token
      expect(await s.requestSearch('FIX-KN-1', data: 'replay', statistic: 'coherent'), isNull);
      expect(posts.single, ('/api/optical/FIX-KN-1/search', '{"data":"replay","statistic":"coherent"}', 'vts'));
      expect(s.archive.doc('optical/FIX-KN-1')!['stale'], isNull, reason: '${s.conn} ${s.connMessage}'); // read again by the sync that followed
      answer = http.Response('{"service":"raven-kn","error":"a search of FIX-KN-1 is already waiting or running"}', 400, headers: {'x-raven-kn': '1'});
      expect(await s.requestSearch('FIX-KN-1', data: 'site', statistic: 'network'), 'a search of FIX-KN-1 is already waiting or running');
      answer = http.Response('{"service":"raven-kn","error":"the Virgo targeted-search token is required to start a search"}', 403, headers: {'x-raven-kn': '1'});
      expect(await s.requestSearch('FIX-KN-1', data: 'site', statistic: 'network'), contains('token is required'));
    });

    test('a refused token is reported as such', () async {
      final s = make(client: () => fixtureServer(token: 'another'));
      await s.sync();
      expect(s.conn, Conn.unauthorized);
      expect(s.archive.count(const LogQuery()), 0);
    });

    test('queries, filters and export', () async {
      final s = make();
      await s.sync();
      final a = s.archive;
      expect(a.count(const LogQuery(optical: 'SSS17a')), greaterThan(20));
      expect(a.events(const LogQuery(groups: {'Decisions'})).every((e) => kindGroups['Decisions']!.contains(e.kind)), isTrue);
      final problems = a.events(const LogQuery(problemsOnly: true));
      expect(problems.map((e) => e.kind), containsAll(['run_failed', 'gw_retraction', 'listener_start', 'message_failed']));
      expect(a.events(const LogQuery(text: 'S261021fy retracted')).single.kind, 'gw_retraction');
      expect(a.count(const LogQuery(text: '100%_nothing')), 0); // LIKE wildcards are escaped
      final y2017 = LogQuery(from: DateTime.utc(2017), to: DateTime.utc(2018));
      expect(a.events(y2017).every((e) => e.time!.year == 2017), isTrue);
      final newest = a.events(const LogQuery(), limit: 5), oldest = a.events(const LogQuery(), limit: 5, oldestFirst: true);
      expect(newest.first.time!.isAfter(oldest.first.time!), isTrue);
      expect(oldest.first.kind, 'grb_notice');
      // the decision entry carries the values of that moment
      final d = a.events(const LogQuery(optical: 'FIX-KN-1', groups: {'Decisions'}), oldestFirst: true).first;
      expect(d.data['trigger'], false);
      expect((d.data['kilonova_evidence'] as Map)['confirmed'], false);
      final csv = exportEntries(a, const LogQuery(optical: 'FIX-KN-1'), csv: true).trim().split('\n');
      expect(csv.first, 'time,level,kind,source,optical,superevent,run,summary');
      expect(csv.length - 1, a.count(const LogQuery(optical: 'FIX-KN-1')));
      final json = jsonDecode(exportEntries(a, y2017, csv: false)) as List;
      expect(json.length, a.count(y2017));
      expect((json.first as Map)['data'], isA<Map>());
    });
  });

  test('every detection type has its kind: GRB, X-ray, radio', () {
    final f = FollowUps({
      'optical': [], 'nu': [], 'gw': [],
      'grb': [
        {'id': '1', 'instrument': 'Fermi-GBM', 'trigger': '1', 'time': '2026-11-13T10:05:22Z', 'ra': 1.0, 'dec': 2.0},
        {'id': 'WXT_1', 'instrument': 'WXT', 'trigger': null, 'time': '2026-11-14T19:40:35Z', 'ra': 1.0, 'dec': 2.0},
        {'id': 'sb1', 'instrument': 'SVOM-ECLAIRs', 'trigger': 'sb1', 'time': '2026-11-13T14:30:59Z', 'ra': 1.0, 'dec': 2.0,
          'xray': {'instrument': 'SVOM-MXT', 'ra': 1.0, 'dec': 2.0}},
        {'id': 'x9', 'instrument': 'Swift-XRT', 'trigger': 'x9', 'time': null, 'ra': 1.0, 'dec': 2.0, 'burst_missing': true},
      ],
      'radio': [
        {'id': 'r1', 'instrument': 'CHIME', 'trigger': 'r1', 'time': '2026-11-15T00:00:00Z', 'ra': 1.0, 'dec': 2.0},
      ],
    });
    expect({for (final e in f.events.values) e.id: e.kind},
        {'grb:1': 'grb', 'grb:WXT_1': 'xray', 'grb:sb1': 'grb', 'grb:x9': 'xray', 'radio:r1': 'radio'});
    expect(f.events['grb:WXT_1']!.label, 'X-ray WXT');
    expect(f.events.values.map((e) => e.kind).toSet().difference(alertKinds.toSet()), isEmpty);
  });

  test('a follow-up holds only the alerts the pipeline attached together', () {
    final f = FollowUps(((captured['json'] as Map)['/api/sky'] as Map).cast<String, dynamic>());
    // from the candidate, the neutrino or the superevent: the same follow-up
    const fix = {'optical:FIX-KN-1', 'nu:IceCube-261020A', 'gw:S261020fx'};
    for (final start in fix) {
      expect(f.related(start), fix, reason: start);
    }
    // GW170817: the candidate, its GRB and the superevent, and nothing from 2026
    expect(f.related('grb:524666471'), {'optical:SSS17a', 'grb:524666471', 'gw:GW170817'});
    expect(f.attached('gw:GW170817', 'grb:524666471'), isTrue); // LVK's own GW x GRB coincidence
    expect(f.attached('optical:SSS17a', 'grb:524666471'), isTrue);
    expect(f.attached('nu:IceCube-261020A', 'gw:S261020fx'), isFalse); // linked through the candidate only
    // alerts attached to nothing stay alone
    expect(f.related('grb:1519536'), {'grb:1519536'});
    expect(f.related('gw:S261021fy'), {'gw:S261021fy'});
    expect(f.isLinked('gw:S261021fy'), isFalse);
    expect(f.related('gw:unknown'), isEmpty);
    expect(f.defaultStart, 'optical:FIX-KN-1');
    // the selectors: candidates first, each with its own alerts only
    final server = (((captured['json'] as Map)['/api/followups'] as Map)['followups'] as List).cast<Map<String, dynamic>>();
    final g = f.groups(server);
    expect(g.where((x) => x.candidate).map((x) => x.ids.toSet()), [
      {'optical:FIX-KN-1', 'nu:IceCube-261020A', 'gw:S261020fx'},
      {'optical:SSS17a', 'grb:524666471', 'gw:GW170817'}
    ]);
    expect(g.where((x) => !x.candidate).map((x) => x.ids), unorderedEquals([['gw:S261021fy'], ['grb:1519536']]));
    expect(g.first.candidate, isTrue);
    expect(g.firstWhere((x) => x.ids.contains('gw:GW170817')).label, 'GW GW170817  +  GRB Fermi-GBM 524666471  +  Optical SSS17a');
    expect(f.groups(const []).map((x) => x.ids.toSet()).toSet().length, 4); // without the server's list: from the links
    expect(f.all.map((e) => e.kind).toSet(), {'optical', 'gw', 'grb', 'nu'});
  });

  test('what the circulars say about each alert', () {
    final sky = ((captured['json'] as Map)['/api/sky'] as Map).cast<String, dynamic>();
    final d = circularDigests(sky);
    expect(d.keys.toSet(), {'grb:1519536', 'nu:IceCube-261020A', 'gw:S261020fx', 'optical:FIX-KN-1'});
    expect(circularShort(d['grb:1519536']!), '5 circulars, optical detection, z = 0.42');
    expect(circularLines(d['grb:1519536']!), [
      '5 circulars: optical 3, X-ray 1, gamma 1',
      'Optical search reported: detection (3 reports, first 2026-10-17 21:40 UTC); redshift 0.42 (GCN 90005).'
    ]);
    expect(circularShort(d['nu:IceCube-261020A']!), '2 circulars, optical upper limits');
    expect(circularLines({'n': 1, 'bands': {'gamma': 1}, 'n_optical': 0}), ['1 circular: gamma 1', 'No optical search reported.']);
    expect(circularShort({'n': 1, 'optical': null}), '1 circular, no optical report');
    expect(circularAlerts({'links': [{'type': 'gw', 'id': 'S1', 'how': 'superevent name'}, {'type': 'optical', 'id': 'KN'}]}),
        {'gw:S1', 'optical:KN'});
    expect(circularDigests({'grb': [{'id': '1'}]}), isEmpty); // a server that does not read circulars
  });

  test('the GRB of an LVK GW x GRB coincidence joins the follow-up of its superevent', () {
    final f = FollowUps({
      'optical': [
        {'name': 'KN1', 'ra': 1.0, 'dec': 2.0, 'grb_id': null, 'nu_id': null, 'superevents': ['S1']}
      ],
      'grb': [
        {'id': '42', 'instrument': 'Fermi-GBM', 'trigger': '42', 'ra': 3.0, 'dec': 4.0},
        {'id': '43', 'instrument': 'Swift-BAT', 'trigger': '43', 'ra': 5.0, 'dec': 6.0}
      ],
      'nu': <Map<String, dynamic>>[],
      'gw': [
        {'superevent_id': 'S1', 'versions': <Map<String, dynamic>>[], 'grb_id': '42', 'grb_match': 'notice number'},
        {'superevent_id': 'S2', 'versions': <Map<String, dynamic>>[], 'grb_id': 'missing'}
      ],
    });
    expect(f.related('grb:42'), {'grb:42', 'gw:S1', 'optical:KN1'});
    expect(f.attached('gw:S1', 'grb:42'), isTrue);
    expect(f.related('grb:43'), {'grb:43'});
    expect(f.related('gw:S2'), {'gw:S2'}); // a notice that is not stored links nothing
  });

  test('time after the first detection', () {
    final t0 = DateTime.utc(2017, 8, 17, 12, 41, 4, 430);
    expect(sinceFirst(t0, t0), 'first');
    expect(sinceFirst(t0.add(const Duration(milliseconds: 1740)), t0), '+1.74 s');
    expect(sinceFirst(DateTime.utc(2017, 8, 17, 23, 33, 17), t0), '+10.9 h');
    expect(sinceFirst(t0.add(const Duration(days: 3)), t0), '+3 d');
    expect(sinceFirst(null, t0), '');
  });

  test('plot helpers', () {
    expect(niceTicks(0, 10, 5), [0, 2, 4, 6, 8, 10]);
    expect(niceTicks(16.2, 21.7, 5).first, 17);
    final h = histogram('h', const Color(0xff000000), [1, 1, 2, 9], bins: 4, lo: 0, hi: 10);
    expect(h.points.map((p) => p.y), [3, 0, 0, 1]);
    expect(filterOf('ps1::i'), ('i', 2));
    expect(filterOf('2massks'), ('K', 7));
    expect(filterOf('sdssu'), ('other', -1));
  });
}
