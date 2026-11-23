// Renders every screen from the fixture and writes PNG files to build/screenshots/,
// to look at the layout (phone and desktop sizes, light and dark).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raven_kn_logbook/main.dart';
import 'package:raven_kn_logbook/src/archive.dart';
import 'package:raven_kn_logbook/src/state.dart';
import 'package:raven_kn_logbook/src/ui/candidates.dart';
import 'package:raven_kn_logbook/src/ui/circulars.dart';
import 'package:raven_kn_logbook/src/ui/common.dart';
import 'package:raven_kn_logbook/src/ui/logbook.dart';
import 'package:raven_kn_logbook/src/ui/system.dart';

import 'support.dart';

Future<void> loadFonts() async {
  final dir = '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
  Future<ByteData> f(String n) async => ByteData.view((await File('$dir/$n').readAsBytes()).buffer);
  await (FontLoader('Roboto')
        ..addFont(f('Roboto-Regular.ttf'))
        ..addFont(f('Roboto-Medium.ttf'))
        ..addFont(f('Roboto-Bold.ttf')))
      .load();
  await (FontLoader('MaterialIcons')..addFont(f('MaterialIcons-Regular.otf'))).load();
}

void main() {
  late AppState state;
  final key = GlobalKey();

  setUpAll(() async {
    await loadFonts();
    state = AppState(Archive.memory(), clientFactory: () => fixtureServer());
    state.saveSettings(serverUrl: 'http://server:8765', token: 'lvktok', portalUrl: 'https://portal.example/login');
    await state.sync();
    expect(state.conn.name, 'ok', reason: state.connMessage);
  });

  Future<void> shot(WidgetTester t, String name, Widget child, Size size,
      {Brightness b = Brightness.light, Future<void> Function()? act, AppState? st}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const SizedBox()); // a fresh screen: no state kept from the previous one
    await t.pumpWidget(RepaintBoundary(
        key: key,
        child: AppScope(
            state: st ?? state,
            child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: ThemeData(
                    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2a78d6), brightness: b),
                    fontFamily: 'Roboto'),
                home: child))));
    await t.pumpAndSettle();
    if (act != null) {
      await act();
      await t.pumpAndSettle();
    }
    // sky rasters are decoded outside the test clock
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final bytes = await t.runAsync(() async {
      final img = await boundary.toImage();
      return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    });
    final f = File('build/screenshots/$name.png')..createSync(recursive: true);
    f.writeAsBytesSync(bytes!);
  }

  const phone = Size(412, 915), desk = Size(1200, 820);

  testWidgets('logbook', (t) async {
    await shot(t, 'logbook_desktop', const Shell(), desk);
    await shot(t, 'logbook_phone', const Shell(), phone);
    await shot(t, 'logbook_phone_dark', const Shell(), phone, b: Brightness.dark);
    await shot(t, 'logbook_problems', const Shell(), phone, act: () => t.tap(find.text('Problems only')));
    await shot(t, 'entry_detail', const Shell(), phone, act: () async {
      await t.enterText(find.byType(TextField), 'triggered SSS17a');
      await t.pumpAndSettle();
      await t.tap(find.byType(EntryTile).first);
    });
  });

  testWidgets('candidates', (t) async {
    await shot(t, 'candidates_phone', const Shell(), phone, act: () => t.tap(find.text('Candidates').last));
    await shot(t, 'candidates_desktop', const Shell(), const Size(1280, 820), act: () => t.tap(find.text('Candidates').last));
    await shot(t, 'followup_sss17a', const CandidateScreen('SSS17a'), phone);
    await shot(t, 'followup_gw170817_desktop', CandidateScreen('SSS17a', followUp: state.followups.firstWhere((f) => f['optical'] == 'SSS17a')), const Size(1480, 900));
    await shot(t, 'followup_fix_desktop', const CandidateScreen('FIX-KN-1'), desk);
    await shot(t, 'lightcurve_sss17a_desktop', const CandidateScreen('SSS17a'), desk, act: () => t.tap(find.text('Light curve')));
    await shot(t, 'lightcurve_fix_reported', const CandidateScreen('FIX-KN-1'), desk, act: () async {
      await t.tap(find.text('Light curve'));
      await t.pumpAndSettle();
      expect(find.text('Reported in GCN Circulars (3)'), findsOneWidget);
      expect(find.text('r = 20.6 ± 0.1 (AB)  ·  2026-10-21 08:10 UTC (date in the text)  ·  GCN 90008'), findsOneWidget);
      expect(find.textContaining('i > 22.1  ·  2026-10-22 08:20 UTC'), findsOneWidget);
      expect(find.text('reported in GCN, not verified'), findsOneWidget); // the series of the plot
    });
    await shot(t, 'lightcurve_sss17a_phone', const CandidateScreen('SSS17a'), phone, act: () => t.tap(find.text('Light curve')));
    await shot(t, 'search_sss17a_desktop', const CandidateScreen('SSS17a'), const Size(1000, 1900), act: () => t.tap(find.text('GW search')));
    await shot(t, 'search_fix_phone', const CandidateScreen('FIX-KN-1'), const Size(412, 2600), act: () => t.tap(find.text('GW search')));
    await shot(t, 'search_sss17a_dark', const CandidateScreen('SSS17a'), const Size(700, 1500), b: Brightness.dark, act: () => t.tap(find.text('GW search')));
    // starting a search: without the Virgo token, then with it and with two earlier requests
    await shot(t, 'search_start_no_token', const CandidateScreen('SSS17a'), phone, act: () async {
      await t.tap(find.text('GW search'));
      await t.pumpAndSettle();
      expect(find.text('Start a targeted search'), findsOneWidget);
      expect(find.textContaining('needs the Virgo Targeted search token'), findsOneWidget);
      expect(find.text('Start targeted search'), findsNothing);
    });
    final a2 = Archive.memory();
    final s2 = AppState(a2, clientFactory: () => fixtureServer());
    s2.saveSettings(serverUrl: 'http://server:8765', token: 'lvktok', portalUrl: '', virgoSearchToken: 'vts');
    await t.runAsync(s2.sync);
    a2.putDoc('health', {...a2.doc('health')!, 'targeted_search': {'virgo': {'configured': true, 'granted': true}}});
    a2.putDoc('optical/FIX-KN-1', {
      ...a2.doc('optical/FIX-KN-1')!,
      'launches': [
        {'id': 'a', 'status': 'refused', 'data': 'site', 'statistic': 'coherent', 'requested': '2026-11-19T17:00:00.000Z',
          'detail': 'fewer than two detectors with analysable data (H1: not in observing mode (state vector); L1: not in observing mode (state vector))'},
        {'id': 'b', 'status': 'done', 'data': 'replay', 'statistic': 'coherent', 'requested': '2026-11-19T17:20:00.000Z',
          'detail': 'asked for from the application; TEST on replayed O4 data: the window of 6 s is moved from GPS 1478634368 to 1479141000, the latest replay data'},
      ],
    });
    await shot(t, 'search_start', const CandidateScreen('FIX-KN-1'), const Size(900, 1100), st: s2, act: () async {
      await t.tap(find.text('GW search'));
      await t.pumpAndSettle();
      expect(find.text('Start targeted search'), findsOneWidget);
      expect(find.textContaining('Refused  ·  site data, coherent'), findsOneWidget);
      expect(find.textContaining('Done  ·  O4 replay (test), coherent'), findsOneWidget);
      await t.tap(find.text('O4 replay (test)'));
      await t.pumpAndSettle();
      await t.tap(find.text('Start targeted search'));
      await t.pumpAndSettle();
      expect(find.textContaining('A TEST on the O4 data replayed'), findsOneWidget); // the confirmation
      await t.tap(find.text('Cancel'));
    });
    await shot(t, 'sky_fix_zoom', const CandidateScreen('FIX-KN-1'), phone, act: () => t.tap(find.text('Sky').last));
  });

  testWidgets('sky and system', (t) async {
    await shot(t, 'sky_all_desktop', const Shell(), desk, act: () => t.tap(find.text('Sky').last));
    await shot(t, 'sky_all_phone_dark', const Shell(), phone, b: Brightness.dark, act: () => t.tap(find.text('Sky').last));
    await shot(t, 'sky_sss17a_zoom', const CandidateScreen('SSS17a'), desk, act: () => t.tap(find.text('Sky')));
    await shot(t, 'sky_gw170817', const Shell(), desk, act: () async {
      await t.tap(find.text('Sky').last);
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Optical FIX-KN-1').first); // first selector: the candidates
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Optical SSS17a').last);
    });
    await shot(t, 'sky_single_alerts', const Shell(), desk, act: () async {
      await t.tap(find.text('Sky').last);
      await t.pumpAndSettle();
      await t.tap(find.text('Alerts without candidate (2)'));
      await t.pumpAndSettle();
      // all types, all dates: the newest alert is the one on the map
      expect(find.text('All types (2)'), findsOneWidget);
      expect(find.text('All dates'), findsOneWidget);
      expect(find.widgetWithText(InputChip, 'GW S261021fy (retracted)'), findsOneWidget);
      expect(find.byType(InputChip), findsOneWidget);
      // every detection type is in the type selector, with its number of alerts
      await t.tap(find.text('All types (2)'));
      await t.pumpAndSettle();
      for (final l in ['GW (1)', 'GRB (1)', 'X-ray (0)', 'Optical (0)', 'Neutrino (0)', 'Radio (0)']) {
        expect(find.text(l), findsWidgets, reason: l);
      }
      await t.tap(find.text('GRB (1)').last);
      await t.pumpAndSettle();
      // an alert chosen in the list is added to the map, over the one already there
      expect(find.byType(InputChip), findsOneWidget);
      await t.tap(find.byKey(const Key('alert-list')));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Swift-BAT 1519536').last);
      await t.pumpAndSettle();
      expect(find.byType(InputChip), findsNWidgets(2));
      expect(find.text('On the map (2)'), findsOneWidget);
      // one is taken off, then the map is cleared
      await t.tap(find.byTooltip('Remove from the map').first);
      await t.pumpAndSettle();
      expect(find.byType(InputChip), findsOneWidget);
      await t.tap(find.text('Clear map'));
      await t.pumpAndSettle();
      expect(find.byType(InputChip), findsNothing);
      expect(find.textContaining('The map is empty'), findsOneWidget);
      await t.tap(find.text('GRB (1)').first);
      await t.pumpAndSettle();
      await t.tap(find.text('X-ray (0)').last);
      await t.pumpAndSettle();
      expect(find.text('No X-ray alert.'), findsOneWidget);
      await t.tap(find.text('X-ray (0)').first);
      await t.pumpAndSettle();
      await t.tap(find.text('All types (2)').last);
      await t.pumpAndSettle();
      // the whole list at once
      await t.tap(find.byKey(const Key('alert-list')));
      await t.pumpAndSettle();
      await t.tap(find.text('All 2 alerts of this list').last);
      await t.pumpAndSettle();
      expect(find.byType(InputChip), findsNWidgets(2));
    });
    // GCN Circulars: on the map's alerts, in the list of follow-ups, then the circulars of one alert and a text
    await shot(t, 'sky_circulars', const Shell(), const Size(1200, 1500), act: () async {
      await t.tap(find.text('Sky').last);
      await t.pumpAndSettle();
      expect(find.text('GCN Circulars'), findsOneWidget);
      expect(find.text('Neutrino IceCube-261020A  =  IceCube-261020A'), findsOneWidget);
      expect(find.textContaining('Optical search reported: upper limits (1 report'), findsOneWidget);
      await t.tap(find.text('Alerts without candidate (2)'));
      await t.pumpAndSettle();
      expect(find.text('No circular linked to it.'), findsOneWidget); // the newest alert, S261021fy
      await t.tap(find.byKey(const Key('alert-list')));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Swift-BAT 1519536').last);
      await t.pumpAndSettle();
      expect(find.text('GRB Swift-BAT 1519536  =  GRB 261017A'), findsOneWidget);
      expect(find.textContaining('redshift 0.42 (GCN 90005)'), findsOneWidget);
    });
    await shot(t, 'candidates_all_circulars', const Shell(), const Size(1200, 1700), act: () async {
      await t.tap(find.text('Candidates').last);
      await t.pumpAndSettle();
      await t.tap(find.textContaining('All follow-ups'));
      await t.pumpAndSettle();
      expect(find.text('GCN  ·  GRB Swift-BAT 1519536: 5 circulars, optical detection, z = 0.42'), findsOneWidget);
      expect(find.text('GCN  ·  Neutrino IceCube-261020A: 2 circulars, optical upper limits'), findsOneWidget);
      // the redshift of a circular puts this burst beyond the range of a GW search
      expect(
          find.text('· GRB 261017A: redshift 0.42 (GCN 90005), luminosity distance 2.37 Gpc: too far for a GW search (limit 500 Mpc)'),
          findsOneWidget);
    });
    await shot(t, 'circulars_of_alert', const CircularsScreen('grb:1519536', 'GRB Swift-BAT 1519536'), phone, act: () async {
      expect(find.textContaining('GCN 9000'), findsNWidgets(5));
      expect(find.text('GRB 261017A: VLT/X-shooter spectroscopic redshift z = 0.42'), findsOneWidget);
      expect(find.textContaining('linked by the trigger number'), findsOneWidget);
    });
    await shot(t, 'circular_text', const CircularsScreen('grb:1519536', 'GRB Swift-BAT 1519536'), phone, act: () async {
      await t.tap(find.text('GRB 261017A: NOT optical upper limits'));
      await t.pumpAndSettle();
      expect(find.text('GCN Circular 90003'), findsOneWidget);
      expect(find.textContaining('No source is detected at the XRT position'), findsOneWidget);
    });
    await shot(t, 'followup_grb_too_far', FollowUpScreen(state.followups.firstWhere((f) => f['id'] == 'grb:1519536')), phone,
        act: () async {
      expect(find.text('Distance'), findsOneWidget);
      expect(find.textContaining('too far for a GW search'), findsOneWidget);
    });
    await shot(t, 'followup_gw_only', FollowUpScreen(state.followups.firstWhere((f) => f['id'] == 'gw:S261021fy')), phone);
    await shot(t, 'system_phone', const Shell(), const Size(412, 1500), act: () => t.tap(find.text('System').last));
    await shot(t, 'settings', const SettingsScreen(), phone);
  });

  testWidgets('portal closed banner', (t) async {
    final s2 = AppState(state.archive, clientFactory: () => fixtureServer(token: 'x'));
    await t.runAsync(s2.sync);
    expect(s2.conn.name, 'unauthorized');
  });
}
