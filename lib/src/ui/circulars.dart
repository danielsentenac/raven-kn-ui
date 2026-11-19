/// GCN Circulars: what observers report about an alert (optical search or not,
/// detection or upper limits, redshift), as linked and labelled by the pipeline.
library;

import 'package:flutter/material.dart';

import '../followup.dart';
import 'common.dart';

/// The alerts of [ids] (`grb:<id>`, `gw:<id>`...) with what the circulars say about
/// each one; an alert opens the list of its circulars. Nothing is shown when the
/// server does not read circulars.
class CircularsSection extends StatelessWidget {
  const CircularsSection(this.ids, {super.key});
  final Iterable<String> ids;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final sky = state.archive.doc('sky');
    if (sky == null || state.archive.doc('circulars') == null) return const SizedBox.shrink();
    final events = FollowUps(sky).events;
    final digests = circularDigests(sky);
    final pal = Palette.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final list = ids.where(events.containsKey).toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Card(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('GCN Circulars', style: Theme.of(context).textTheme.titleSmall),
              Text('What observers reported about each alert. The labels come from keywords of the circulars.', style: small),
              const SizedBox(height: 4),
              for (final id in list)
                InkWell(
                    onTap: digests[id] == null
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                                builder: (_) => AppScope(state: state, child: CircularsScreen(id, events[id]!.label)))),
                    child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(children: [
                          Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(
                                '${events[id]!.label}${digests[id]?['name'] != null ? '  =  ${digests[id]!['name']}' : ''}',
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                            if (digests[id] == null)
                              Text('No circular linked to it.', style: small?.copyWith(color: pal.ink2))
                            else
                              for (final l in circularLines(digests[id]!)) Text(l, style: small),
                          ])),
                          if (digests[id] != null) Icon(Icons.chevron_right, color: pal.muted),
                        ]))),
            ])));
  }
}

String _result(String? r) => switch (r) {
      'detection' => 'detection',
      'upper_limit' => 'upper limits',
      'observation' => 'observation, result not labelled',
      _ => '',
    };

String _band(String b) => switch (b) {
      'optical' => 'optical',
      'xray' => 'X-ray',
      'radio' => 'radio',
      'gamma' => 'gamma',
      'gw' => 'GW',
      'nu' => 'neutrino',
      _ => b,
    };

/// The circulars linked to one alert, newest first; one opens its text.
class CircularsScreen extends StatelessWidget {
  const CircularsScreen(this.id, this.label, {super.key});
  final String id, label;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final pal = Palette.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final list = state.circulars.where((c) => circularAlerts(c).contains(id)).toList().reversed.toList();
    return Scaffold(
        appBar: AppBar(title: Text('Circulars: $label')),
        body: list.isEmpty
            ? const Center(child: Text('No circular linked to this alert.'))
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final c = list[i];
                  final bands = ((c['bands'] as List?) ?? const []).cast<String>();
                  final how = ((c['links'] as List?) ?? const [])
                      .cast<Map<String, dynamic>>()
                      .where((l) => '${l['type']}:${l['id']}' == id)
                      .map((l) => l['how'])
                      .firstOrNull;
                  return ListTile(
                      title: Text(c['subject'] as String? ?? ''),
                      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                            'GCN ${c['id']}  ·  ${fmtTime(DateTime.tryParse(c['time'] as String? ?? ''), seconds: false)} UTC'
                            '${(c['submitter'] as String? ?? '').isNotEmpty ? '  ·  ${c['submitter']}' : ''}',
                            style: small),
                        Text(
                            [
                              bands.isEmpty ? 'not labelled' : bands.map(_band).join(', '),
                              if (c['result'] != null) _result(c['result'] as String),
                              if (c['redshift'] != null) 'redshift ${fmtNum(c['redshift'] as num, sig: 4)}',
                              if (how != null) 'linked by the $how',
                            ].join('  ·  '),
                            style: small?.copyWith(color: pal.ink2)),
                      ]),
                      trailing: Icon(Icons.chevron_right, color: pal.muted),
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                              builder: (_) => AppScope(state: state, child: CircularScreen(c['id'] as int)))));
                }));
  }
}

/// The text of one circular.
class CircularScreen extends StatelessWidget {
  const CircularScreen(this.number, {super.key});
  final int number;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final c = state.archive.doc('circular/$number');
    final small = Theme.of(context).textTheme.bodySmall;
    return Scaffold(
        appBar: AppBar(title: Text('GCN Circular $number')),
        body: c == null
            ? const Center(child: Text('The text of this circular is not synced yet.'))
            : ListView(padding: const EdgeInsets.all(16), children: [
                SelectableText(c['subject'] as String? ?? '', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                    '${fmtTime(DateTime.tryParse(c['time'] as String? ?? ''), seconds: false)} UTC'
                    '${(c['submitter'] as String? ?? '').isNotEmpty ? '  ·  ${c['submitter']}' : ''}',
                    style: small),
                if (c['url'] != null) SelectableText(c['url'] as String, style: small),
                const Divider(height: 24),
                SelectableText(c['body'] as String? ?? ''),
              ]));
  }
}
