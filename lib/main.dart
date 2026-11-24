import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'src/api.dart';
import 'src/archive.dart';
import 'src/state.dart';
import 'src/ui/candidates.dart';
import 'src/ui/common.dart';
import 'src/ui/logbook.dart';
import 'src/ui/sky.dart';
import 'src/ui/system.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  await Directory(dir.path).create(recursive: true);
  final db = p.join(dir.path, 'logbook.sqlite');
  final state = AppState(Archive.open(db));
  if (Platform.isLinux) {
    // the database holds the tokens and the portal password: owner only
    try {
      await Process.run('chmod', ['600', db]);
      await Process.run('chmod', ['700', dir.path]);
    } catch (_) {}
  }
  runApp(LogbookApp(state));
  state.sync(); // at opening; afterwards only on request
}

class LogbookApp extends StatelessWidget {
  const LogbookApp(this.state, {super.key});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2a78d6), brightness: b),
        useMaterial3: true,
        visualDensity: VisualDensity.standard);
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'RAVEN-KN logbook',
        debugShowCheckedModeBanner: false,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        home: const Shell(),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  static const _titles = ['Logbook', 'Candidates', 'Sky', 'System'];
  static const _icons = [Icons.menu_book, Icons.auto_awesome, Icons.public, Icons.monitor_heart];

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final body = switch (tab) {
      0 => const LogbookScreen(),
      1 => const CandidatesScreen(),
      2 => const SkyView(),
      _ => const SystemScreen(),
    };
    final problems = ((state.health?['listeners'] as List?) ?? const []).any((l) => (l as Map)['alive'] != true);
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 760;
      final content = Column(children: [const ConnectionBanner(), const ReadyBanner(), Expanded(child: body)]);
      return Scaffold(
        appBar: AppBar(
          title: Text(_titles[tab]),
          actions: [
            if (state.syncing)
              Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Center(child: Text(state.progress, style: Theme.of(context).textTheme.bodySmall))),
            IconButton(
                tooltip: 'Sync with the server',
                onPressed: state.syncing ? null : state.sync,
                icon: state.syncing
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync)),
            IconButton(
                tooltip: 'Settings',
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => AppScope(state: state, child: const SettingsScreen()))),
                icon: const Icon(Icons.settings)),
          ],
        ),
        body: wide
            ? Row(children: [
                NavigationRail(
                    selectedIndex: tab,
                    onDestinationSelected: (i) => setState(() => tab = i),
                    labelType: NavigationRailLabelType.all,
                    destinations: [
                      for (var i = 0; i < 4; i++)
                        NavigationRailDestination(
                            icon: Badge(isLabelVisible: i == 3 && problems, child: Icon(_icons[i])), label: Text(_titles[i])),
                    ]),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ])
            : content,
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: tab,
                onDestinationSelected: (i) => setState(() => tab = i),
                destinations: [
                  for (var i = 0; i < 4; i++)
                    NavigationDestination(
                        icon: Badge(isLabelVisible: i == 3 && problems, child: Icon(_icons[i])), label: _titles[i]),
                ]),
      );
    });
  }
}

/// What the archive shows and how old it is; what to do when the server is not reached.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final last = state.lastSync;
    final age = last == null ? null : DateTime.now().toUtc().difference(last);
    final when = last == null ? 'never synced' : 'last sync ${fmtTime(last, seconds: false)} UTC, ${fmtAgo(age!)} ago';
    if (state.conn == Conn.ok || (state.conn == Conn.unknown && state.syncing)) {
      return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          color: scheme.surfaceContainerHighest,
          child: Text(state.syncing ? 'Syncing...' : 'Synced with ${Uri.tryParse(state.serverUrl)?.host ?? state.serverUrl}: $when. ${state.connMessage}.',
              style: Theme.of(context).textTheme.bodySmall));
    }
    final (IconData icon, String action, VoidCallback run) = switch (state.conn) {
      // with a stored login a new sync logs in again; without one, the login is set in Settings
      Conn.portalClosed when state.canAutoLogin => (Icons.lock_clock, 'Retry', state.sync),
      Conn.portalClosed => (
          Icons.lock_clock,
          'Settings',
          () => Navigator.push(
              context, MaterialPageRoute<void>(builder: (_) => AppScope(state: state, child: const SettingsScreen())))
        ),
      Conn.notConfigured || Conn.unauthorized => (
          Icons.settings,
          'Settings',
          () => Navigator.push(
              context, MaterialPageRoute<void>(builder: (_) => AppScope(state: state, child: const SettingsScreen())))
        ),
      Conn.noNetwork => (Icons.signal_wifi_off, 'Retry', state.sync),
      _ => (Icons.error_outline, 'Retry', state.sync),
    };
    return Container(
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(children: [
        Icon(icon, size: 20, color: scheme.onSecondaryContainer),
        const SizedBox(width: 10),
        Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(connTitle(state.conn), style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSecondaryContainer)),
          Text('Showing the local copy of ${Uri.tryParse(state.serverUrl)?.host ?? 'no server'}: $when.${state.connMessage.isNotEmpty ? ' ${state.connMessage}.' : ''}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSecondaryContainer)),
        ])),
        TextButton(onPressed: state.syncing ? null : run, child: Text(action)),
      ]),
    );
  }
}
