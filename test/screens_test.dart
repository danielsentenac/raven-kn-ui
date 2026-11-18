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
      {Brightness b = Brightness.light, Future<void> Function()? act}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const SizedBox()); // a fresh screen: no state kept from the previous one
    await t.pumpWidget(RepaintBoundary(
        key: key,
        child: AppScope(
            state: state,
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
    await shot(t, 'lightcurve_sss17a_phone', const CandidateScreen('SSS17a'), phone, act: () => t.tap(find.text('Light curve')));
    await shot(t, 'search_sss17a_desktop', const CandidateScreen('SSS17a'), const Size(1000, 1900), act: () => t.tap(find.text('GW search')));
    await shot(t, 'search_fix_phone', const CandidateScreen('FIX-KN-1'), const Size(412, 2600), act: () => t.tap(find.text('GW search')));
    await shot(t, 'search_sss17a_dark', const CandidateScreen('SSS17a'), const Size(700, 1500), b: Brightness.dark, act: () => t.tap(find.text('GW search')));
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
      expect(find.textContaining('1 alert shown: GW S261021fy'), findsOneWidget); // the newest GW alert alone
      await t.tap(find.text('GRB (1)'));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Swift-BAT 1519536').first); // ticked as well: both drawn together
      await t.pumpAndSettle();
      expect(find.textContaining('2 alerts shown'), findsOneWidget);
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
