/// State of the pipeline as last read, outages, settings and export.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../archive.dart';
import '../state.dart';
import 'common.dart';
import 'logbook.dart';

String connTitle(Conn c) => switch (c) {
      Conn.ok => 'Connected to the server',
      Conn.noNetwork => 'No network connection',
      Conn.portalClosed => 'Virgo portal session closed or expired',
      Conn.unauthorized => 'LVK Targeted search token refused',
      Conn.serverError => 'The server answered with an error',
      Conn.notConfigured => 'Server not set',
      Conn.unknown => 'Not synced in this session',
    };

class SystemScreen extends StatelessWidget {
  const SystemScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final pal = Palette.of(context);
    final h = state.health;
    final read = state.archive.docTime('health');
    final listeners = ((h?['listeners'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final sync = (h?['runs_sync'] as Map?)?.cast<String, dynamic>();
    final store = (h?['store'] as Map?)?.cast<String, dynamic>();
    Widget card(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              ...children,
            ])));
    Widget line(IconData icon, Color color, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ]));

    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      card('Link to the server', [
        line(state.conn == Conn.ok ? Icons.check_circle : Icons.info_outline,
            state.conn == Conn.ok ? Palette.good : (state.conn == Conn.unknown ? pal.muted : Palette.serious), connTitle(state.conn)),
        if (state.connMessage.isNotEmpty) Text(state.connMessage, style: Theme.of(context).textTheme.bodySmall),
        Text(
            state.lastSync == null
                ? 'Never synced.'
                : 'Last sync ${fmtTime(state.lastSync, seconds: false)} UTC (${fmtAgo(DateTime.now().toUtc().difference(state.lastSync!))} ago). '
                    'Access: ${state.lvk ? 'public and LVK runs' : 'public runs only'}.',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          FilledButton.icon(onPressed: state.syncing ? null : state.sync, icon: const Icon(Icons.sync, size: 18), label: const Text('Sync')),
          OutlinedButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => AppScope(state: state, child: const SettingsScreen()))),
              icon: const Icon(Icons.settings, size: 18),
              label: const Text('Settings')),
        ]),
      ]),
      if (h != null)
        card('Listeners, as read ${fmtTime(read, seconds: false)} UTC', [
          if (listeners.isEmpty) const Text('No listener has written a heartbeat in this store.'),
          for (final l in listeners) ...[
            line(l['alive'] == true ? Icons.check_circle : Icons.cancel, l['alive'] == true ? Palette.good : Palette.critical,
                '${l['source']} on ${l['host']}: ${l['alive'] == true ? 'running' : 'no heartbeat for ${fmtAgo(Duration(seconds: ((l['age_s'] as num?) ?? 0).round()))}'}'),
            Padding(
                padding: const EdgeInsets.only(left: 26, bottom: 6),
                child: Text(
                    'Started ${fmtTime(DateTime.tryParse(l['started'] as String? ?? ''), seconds: false)} UTC, restart number ${l['restarts']}. '
                    '${l['messages']} messages since (${l['skipped']} mock or test, ${l['failed']} failed), ${l['kafka_errors']} Kafka errors.'
                    '${_lastMessages(l)}'
                    '${l['last_error'] != null ? '\nLast error: ${(l['last_error'] as Map)['text']}' : ''}',
                    style: Theme.of(context).textTheme.bodySmall)),
          ],
        ]),
      if (h != null)
        card('Search and PE runs', [
          if (sync == null)
            const Text('Runs are written directly in the store (no copy from a cluster).')
          else
            line(
                ((sync['age_s'] as num?) ?? 0) < 3600 ? Icons.check_circle : Icons.warning_amber_rounded,
                ((sync['age_s'] as num?) ?? 0) < 3600 ? Palette.good : Palette.serious,
                'Last copy from the cluster ${fmtTime(DateTime.tryParse(sync['time'] as String? ?? ''), seconds: false)} UTC, '
                '${fmtAgo(Duration(seconds: ((sync['age_s'] as num?) ?? 0).round()))} before the server was read.'),
          if (store != null)
            Text(
                'Store: ${store['optical'] ?? store['candidates']} optical transients, ${store['gw']} GW alerts, ${store['grb']} GRB notices, '
                '${store['nu']} neutrino alerts, ${store['coinc']} coincidences, ${store['runs']} runs.',
                style: Theme.of(context).textTheme.bodySmall),
        ]),
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 0), child: Text('Outages and errors', style: Theme.of(context).textTheme.titleSmall)),
      LogList(query: const LogQuery(problemsOnly: true), shrink: true, key: ValueKey('problems${state.batch}')),
    ]);
  }

  static String _lastMessages(Map<String, dynamic> l) {
    final m = (l['last_message'] as Map?) ?? const {};
    if (m.isEmpty) return '';
    return '\nLast message: ${m.entries.map((e) => '${(e.key as String).split('.').last} ${fmtTime(DateTime.tryParse(e.value as String), seconds: false)}').join('; ')} UTC.';
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  TextEditingController? _url, _token, _virgo, _portal, _user, _pass, _cert;
  bool? _auto;
  bool _csv = false;
  DateTimeRange? _range;
  String? _optical;

  @override
  void dispose() {
    _url?.dispose();
    _token?.dispose();
    _virgo?.dispose();
    _portal?.dispose();
    _user?.dispose();
    _pass?.dispose();
    _cert?.dispose();
    super.dispose();
  }

  Future<void> _export(AppState state) async {
    final messenger = ScaffoldMessenger.of(context);
    final q = LogQuery(
        optical: _optical,
        from: _range == null ? null : DateTime.utc(_range!.start.year, _range!.start.month, _range!.start.day),
        to: _range == null ? null : DateTime.utc(_range!.end.year, _range!.end.month, _range!.end.day).add(const Duration(days: 1)));
    final n = state.archive.count(q);
    final text = exportEntries(state.archive, q, csv: _csv);
    final name = 'raven-kn-logbook${_optical != null ? '-$_optical' : ''}.${_csv ? 'csv' : 'json'}';
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final f = File(p.join((await getTemporaryDirectory()).path, name));
        await f.writeAsString(text);
        await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: name));
      } else {
        final loc = await getSaveLocation(suggestedName: name);
        if (loc == null) return;
        await File(loc.path).writeAsString(text);
        messenger.showSnackBar(SnackBar(content: Text('$n entries written to ${loc.path}')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    _url ??= TextEditingController(text: state.serverUrl);
    _token ??= TextEditingController(text: state.token);
    _virgo ??= TextEditingController(text: state.virgoSearchToken);
    _portal ??= TextEditingController(text: state.portalUrl);
    _user ??= TextEditingController(text: state.portalUser);
    _pass ??= TextEditingController(text: state.portalPassword);
    _cert ??= TextEditingController(text: state.portalCertName);
    _auto ??= state.portalAuto;
    final names = state.opticals.map((c) => c['name'] as String).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Server', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(controller: _url, decoration: const InputDecoration(labelText: 'Address of raven-kn serve', hintText: 'http://host.example.org:8765', border: OutlineInputBorder()), keyboardType: TextInputType.url, autocorrect: false),
        const SizedBox(height: 12),
        TextField(controller: _token, decoration: const InputDecoration(labelText: 'LVK Targeted search token', border: OutlineInputBorder()), obscureText: true, autocorrect: false, enableSuggestions: false),
        Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text('Reads the logbook, with the results obtained on LVK data. Kept for searches on LVK data outside the Virgo site.',
                style: Theme.of(context).textTheme.bodySmall)),
        const SizedBox(height: 12),
        TextField(controller: _virgo, decoration: const InputDecoration(labelText: 'Virgo Targeted search token', border: OutlineInputBorder()), obscureText: true, autocorrect: false, enableSuggestions: false),
        Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
                'To start a targeted search on the Virgo site. '
                '${switch (state.virgoSearchStatus) {
                  'granted' => 'Accepted by the server at the last sync.',
                  'refused' => 'Refused by the server at the last sync.',
                  'not configured' => 'The server has no such token: no search can be started from here.',
                  _ => state.virgoSearchToken.isEmpty ? 'Not set.' : 'Not checked yet: the server did not say.',
                }}',
                style: Theme.of(context).textTheme.bodySmall)),
        const SizedBox(height: 12),
        TextField(controller: _portal, decoration: const InputDecoration(labelText: 'Address of the Virgo portal (for the automatic login)', hintText: 'https://portal.example.org/login', border: OutlineInputBorder()), keyboardType: TextInputType.url, autocorrect: false),
        const SizedBox(height: 20),
        Text('Virgo portal login', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(controller: _user, decoration: const InputDecoration(labelText: 'Portal login', border: OutlineInputBorder()), autocorrect: false, enableSuggestions: false),
        const SizedBox(height: 12),
        TextField(controller: _pass, decoration: const InputDecoration(labelText: 'Portal password', border: OutlineInputBorder()), obscureText: true, autocorrect: false, enableSuggestions: false),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Log in automatically'),
            subtitle: const Text('When the server is not reached, at opening and at each sync'),
            value: _auto!,
            onChanged: (v) => setState(() => _auto = v)),
        TextField(controller: _cert, decoration: const InputDecoration(labelText: 'Name on the portal certificate, if not the address', hintText: 'portal.example.org', border: OutlineInputBorder()), autocorrect: false),
        if (state.portalRefused)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.warning_amber_rounded, color: Palette.serious, size: 18),
                const SizedBox(width: 6),
                const Expanded(child: Text('The portal refused this login. Automatic login is stopped until you save it again.')),
              ])),
        const SizedBox(height: 6),
        Text('The tokens, the portal login and its password are kept on this device, in the application\'s private storage, not encrypted. '
            'The password is sent only to the portal address above, over a verified HTTPS connection.',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
                onPressed: () async {
                  final nav = Navigator.of(context);
                  if (state.wouldReplaceData(_url!.text)) {
                    final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                              title: const Text('Another server'),
                              content: Text('The local copy holds the logbook of\n${state.serverUrl}\n\n'
                                  'It will be removed and replaced by the logbook of the new server. Export it first if you want to keep it.'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Replace')),
                              ],
                            ));
                    if (ok != true) return;
                  }
                  state.saveSettings(serverUrl: _url!.text, token: _token!.text, portalUrl: _portal!.text, virgoSearchToken: _virgo!.text);
                  state.savePortalLogin(user: _user!.text, password: _pass!.text, auto: _auto!, certName: _cert!.text);
                  nav.pop();
                  state.sync();
                },
                child: const Text('Save and sync'))),
        const Divider(height: 40),
        Text('Export the logbook', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          DropdownButton<String?>(
              value: _optical,
              items: [const DropdownMenuItem(value: null, child: Text('All entries')), for (final n in names) DropdownMenuItem(value: n, child: Text(n))],
              onChanged: (v) => setState(() => _optical = v)),
          ActionChip(
              avatar: const Icon(Icons.date_range, size: 18),
              label: Text(_range == null ? 'All dates' : '${fmtDay(_range!.start)} to ${fmtDay(_range!.end)}'),
              onPressed: () async {
                final r = await showDateRangePicker(context: context, firstDate: DateTime.utc(2015), lastDate: DateTime.now().add(const Duration(days: 1)), initialDateRange: _range);
                if (r != null) setState(() => _range = r);
              }),
          if (_range != null) IconButton(icon: const Icon(Icons.clear, size: 18), tooltip: 'All dates', onPressed: () => setState(() => _range = null)),
          SegmentedButton<bool>(
              segments: const [ButtonSegment(value: false, label: Text('JSON')), ButtonSegment(value: true, label: Text('CSV'))],
              selected: {_csv},
              onSelectionChanged: (s) => setState(() => _csv = s.first)),
          FilledButton.tonalIcon(onPressed: () => _export(state), icon: const Icon(Icons.download, size: 18), label: const Text('Export')),
        ]),
        const SizedBox(height: 6),
        Text('JSON keeps every value of each entry; CSV keeps the time, kind, names and summary.', style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
