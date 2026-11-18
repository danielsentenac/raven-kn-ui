/// Candidates (follow-ups the pipeline labels as such): the list, and one page per follow-up.
library;

import 'package:flutter/material.dart';

import '../archive.dart';
import 'common.dart';
import 'history.dart';
import 'logbook.dart';
import 'plots.dart';
import 'sky.dart';

/// The follow-ups the pipeline labels as candidates (or all follow-ups).
class CandidatesScreen extends StatefulWidget {
  const CandidatesScreen({super.key});
  @override
  State<CandidatesScreen> createState() => _CandidatesScreenState();
}

class _CandidatesScreenState extends State<CandidatesScreen> {
  bool all = false;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final every = state.followups;
    if (every.isEmpty) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(state.lastSync == null ? 'Nothing synced yet.' : 'No alert in the store yet.')));
    }
    final list = every.where((f) => all || f['candidate'] == true).toList();
    final nCand = every.where((f) => f['candidate'] == true).length;
    return ListView(children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(
              'A candidate is a follow-up that links two detection types, or has an optical transient confirmed as a '
              'kilonova, or a GW alert likely to involve a neutron star. '
              'As of the last sync${state.lastSync != null ? ', ${fmtTime(state.lastSync, seconds: false)} UTC' : ''}.',
              style: Theme.of(context).textTheme.bodySmall)),
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: Wrap(spacing: 8, children: [
            ChoiceChip(label: Text('Candidates ($nCand)'), selected: !all, onSelected: (_) => setState(() => all = false)),
            ChoiceChip(label: Text('All follow-ups (${every.length})'), selected: all, onSelected: (_) => setState(() => all = true)),
          ])),
      if (list.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No follow-up is a candidate yet.')),
      for (final f in list) _FollowUpTile(f),
    ]);
  }
}

class _FollowUpTile extends StatelessWidget {
  const _FollowUpTile(this.f);
  final Map<String, dynamic> f;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final pal = Palette.of(context);
    final members = ((f['members'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final reasons = ((f['reasons'] as List?) ?? const []).cast<String>();
    final att = f['attention'] as String?;
    final isCand = f['candidate'] == true;
    final small = Theme.of(context).textTheme.bodySmall;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
                builder: (_) => AppScope(
                    state: state,
                    child: f['optical'] != null && state.archive.doc('optical/${f['optical']}') != null
                        ? CandidateScreen(f['optical'] as String, followUp: f)
                        : FollowUpScreen(f)))),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(members.map((m) => '${typeLabel(m['type'] as String)} ${m['name']}').join('  +  '),
                      style: Theme.of(context).textTheme.titleSmall)),
              if (att != null) StatusChip(att),
            ]),
            const SizedBox(height: 4),
            Text(
                '${isCand ? 'Candidate' : 'Not a candidate'}  ·  started from ${typeLabel(f['origin'] as String)} ${f['origin_name']}'
                '${f['time'] != null ? ', ${fmtTime(DateTime.tryParse(f['time'] as String), seconds: false)} UTC' : ''}',
                style: small?.copyWith(fontWeight: FontWeight.w600, color: isCand ? pal.ink : pal.ink2)),
            for (final r in reasons) Text('· $r', style: small),
            if (!isCand) Text('No link to another detection type, and nothing that marks it as a candidate.', style: small),
            const SizedBox(height: 10),
            HistoryDiagram(f),
          ]),
        ),
      ),
    );
  }
}

/// A follow-up without an optical transient: its alerts, its log and its sky view.
class FollowUpScreen extends StatelessWidget {
  const FollowUpScreen(this.f, {super.key});
  final Map<String, dynamic> f;

  @override
  Widget build(BuildContext context) {
    final members = ((f['members'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final gw = members.where((m) => m['type'] == 'gw').firstOrNull;
    return DefaultTabController(
      length: gw != null ? 3 : 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(f['title'] as String? ?? '${typeLabel((f['id'] as String).split(':').first)} ${f['name']}'),
          bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            const Tab(text: 'Follow-up'),
            if (gw != null) const Tab(text: 'Log'),
            const Tab(text: 'Sky'),
          ]),
        ),
        body: TabBarView(children: [
          ListView(padding: const EdgeInsets.only(bottom: 24), children: [FollowUpSummary(f)]),
          if (gw != null) LogList(query: LogQuery(superevent: gw['id'] as String)),
          SkyView(startId: f['id'] as String),
        ]),
      ),
    );
  }
}

/// The alerts of a follow-up, by detection type, and why it is (or is not) a candidate.
class FollowUpSummary extends StatelessWidget {
  const FollowUpSummary(this.f, {super.key});
  final Map<String, dynamic> f;

  @override
  Widget build(BuildContext context) {
    final reasons = ((f['reasons'] as List?) ?? const []).cast<String>();
    return _section(context, f['candidate'] == true ? 'Candidate' : 'Follow-up, not a candidate', [
      for (final r in reasons) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('· $r')),
      if (reasons.isEmpty) const Text('No link to another detection type, and nothing that marks it as a candidate.'),
      const SizedBox(height: 10),
      Text('History: detections in order of time, then the pipeline', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 6),
      HistoryDiagram(f),
    ]);
  }
}

class CandidateScreen extends StatelessWidget {
  const CandidateScreen(this.name, {super.key, this.followUp});

  /// Name of the optical transient the page follows.
  final String name;

  /// The follow-up it belongs to, when opened from the list of candidates.
  final Map<String, dynamic>? followUp;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final doc = state.archive.doc('optical/$name');
    final fetched = state.archive.docTime('optical/$name');
    if (doc == null) {
      return Scaffold(appBar: AppBar(title: Text(name)), body: const Center(child: Text('Not synced yet.')));
    }
    final runs = ((doc['runs'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text(followUp?['title'] as String? ?? 'Optical $name'),
          bottom: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            Tab(text: 'Follow-up'),
            Tab(text: 'Log'),
            Tab(text: 'Light curve'),
            Tab(text: 'GW search'),
            Tab(text: 'Sky'),
          ]),
        ),
        body: TabBarView(children: [
          _FollowUp(doc, fetched, followUp ?? state.followups.where((f) => f['optical'] == name).firstOrNull),
          LogList(query: LogQuery(optical: name)),
          _LightCurve(doc),
          _Runs(name, runs, (doc['hidden_runs'] as int?) ?? 0),
          SkyView(focus: name),
        ]),
      ),
    );
  }
}

Widget _section(BuildContext c, String title, List<Widget> children) => Card(
    margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(c).textTheme.titleSmall),
          const SizedBox(height: 6),
          ...children,
        ])));

Widget _fact(BuildContext c, String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 150, child: Text(k, style: Theme.of(c).textTheme.bodySmall?.copyWith(color: Palette.of(c).ink2))),
      Expanded(child: Text(v)),
    ]));

class _FollowUp extends StatelessWidget {
  const _FollowUp(this.doc, this.fetched, this.followUp);
  final Map<String, dynamic> doc;
  final DateTime? fetched;
  final Map<String, dynamic>? followUp;

  @override
  Widget build(BuildContext context) {
    final steps = ((doc['steps'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final c = (doc['optical'] as Map).cast<String, dynamic>();
    final d = (doc['decision'] as Map?)?.cast<String, dynamic>();
    final age = fetched == null ? null : DateTime.now().toUtc().difference(fetched!);
    final old = age != null && age > const Duration(minutes: 30);
    final co = ((doc['coincidences'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final di = (d?['distance_inclination'] as Map?)?.cast<String, dynamic>();
    final det = (d?['detectability'] as Map?)?.cast<String, dynamic>();
    final win = (d?['t0_window'] as Map?)?.cast<String, dynamic>();
    final ev = (d?['kilonova_evidence'] as Map?)?.cast<String, dynamic>();
    String range(Map? m, String unit) =>
        m == null ? 'unknown' : '${fmtNum(m['median'] as num?)} $unit (${fmtNum(m['lower'] as num?)} to ${fmtNum(m['upper'] as num?)})';
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(
              fetched == null
                  ? ''
                  : 'State read from the server ${fmtAgo(age!)} ago (${fmtTime(fetched, seconds: false)} UTC)'
                      '${old ? '. Steps shown as running are the last known state.' : ''}',
              style: Theme.of(context).textTheme.bodySmall)),
      if (followUp != null) FollowUpSummary(followUp!),
      _section(context, 'Steps', [
        for (var i = 0; i < steps.length; i++)
          _StepRow(steps[i], last: i == steps.length - 1, lastKnown: old && steps[i]['status'] == 'running'),
      ]),
      _section(context, 'Optical transient', [
        _fact(context, 'Position', 'RA ${fmtNum(c['ra'] as num?, sig: 7)}, Dec ${fmtNum(c['dec'] as num?, sig: 7)}'),
        _fact(context, 'Origin', (c['source'] ?? 'unknown').toString()),
        if (c['redshift'] != null)
          _fact(context, 'Redshift', '${fmtNum((c['redshift'] as Map)['z'] as num?, sig: 4)} (${(c['redshift'] as Map)['source']})'),
        if (c['classification'] != null) _fact(context, 'Classification', c['classification'].toString()),
        if (c['kn_score'] != null) _fact(context, 'Classifier score', fmtNum(c['kn_score'] as num?)),
        if (c['grb'] != null)
          _fact(context, 'GRB', '${(c['grb'] as Map)['instrument']} ${(c['grb'] as Map)['graceid'] ?? ''}'),
        if (c['neutrino'] != null)
          _fact(context, 'Neutrino', '${(c['neutrino'] as Map)['event_name'] ?? ''} (${(c['neutrino'] as Map)['instrument']})'),
        if ((c['notes'] as String? ?? '').isNotEmpty) _fact(context, 'Notes', c['notes'] as String),
      ]),
      if (d != null)
        _section(context, 'Decision', [
          _fact(context, 'Targeted search', d['trigger_targeted_search'] == true ? 'triggered' : 'held'),
          if (win != null)
            _fact(context, 'Merger-time window',
                '${fmtNum((win['duration_h'] as num) * 3600)} s, from ${win['method']} (GPS ${fmtNum(win['gps_start'] as num?, sig: 12)})'),
          if (di != null) _fact(context, 'Distance', range(di['luminosity_distance_mpc'] as Map?, 'Mpc')),
          if (di != null) _fact(context, 'Viewing angle', range(di['viewing_angle_deg'] as Map?, 'deg')),
          if (det != null)
            _fact(context, 'Expected network SNR',
                '${fmtNum(det['snr_median'] as num?)}  (P(detect) ${fmtNum(det['p_detect'] as num?)})'),
          if (ev != null)
            _fact(context, 'Kilonova evidence',
                '${ev['confirmed'] == true ? 'confirmed by ${(ev['by'] as List).join(', ')}' : 'not confirmed'}: ${(ev['reasons'] as List).join('; ')}'),
          if (det != null && (det['reasons'] as List?) != null)
            _fact(context, 'Detectability', (det['reasons'] as List).join('; ')),
        ]),
      for (final r in co)
        _section(context, 'Coincidence with ${r['superevent_id']}${r['retracted'] == true ? ' (retracted)' : ''}', [
          _fact(context, 'Joint FAR',
              '${fmtNum((r['spatiotemporal_distance_coinc_far'] ?? r['spatiotemporal_coinc_far'] ?? r['temporal_coinc_far']) as num?)} Hz'),
          _fact(context, 'Time only', '${fmtNum(r['temporal_coinc_far'] as num?)} Hz'),
          if (r['spatiotemporal_coinc_far'] != null) _fact(context, 'Time and sky', '${fmtNum(r['spatiotemporal_coinc_far'] as num?)} Hz'),
          _fact(context, 'GW FAR', '${fmtNum(r['far_gw'] as num?)} Hz (${r['alert_type']})'),
          if (r['skymap_overlap'] != null) _fact(context, 'Sky overlap', fmtNum(r['skymap_overlap'] as num?)),
          if (r['distance_overlap'] != null) _fact(context, 'Distance overlap', fmtNum(r['distance_overlap'] as num?)),
          _fact(context, 'Window', '${fmtNum(r['window_s'] as num?)} s'),
          if (r['alert_in_store'] != true && r['retracted'] != true)
            _fact(context, 'Note', 'the alert is no longer in the store (older than 14 days)'),
        ]),
    ]);
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow(this.s, {required this.last, required this.lastKnown});
  final Map<String, dynamic> s;
  final bool last, lastKnown;

  @override
  Widget build(BuildContext context) {
    final st = StatusStyle.of(s['status'] as String, context);
    final pal = Palette.of(context);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Column(children: [
          Icon(st.icon, color: st.color, size: 22),
          if (!last) Expanded(child: Container(width: 2, color: pal.grid)),
        ]),
        const SizedBox(width: 10),
        Expanded(
            child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(s['label'] as String, style: const TextStyle(fontWeight: FontWeight.w600))),
              Text(lastKnown ? 'Last known: ${st.label.toLowerCase()}' : st.label, style: Theme.of(context).textTheme.labelMedium),
            ]),
            if ((s['detail'] as String? ?? '').isNotEmpty)
              Text(s['detail'] as String, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: pal.ink2)),
          ]),
        )),
      ]),
    );
  }
}

/// Filter of a band name (`ps1::i`, `2massks`, `sdssu`): (label, colour slot or -1).
(String, int) filterOf(String band) {
  var b = band.toLowerCase();
  b = b.split('::').last.replaceFirst(RegExp(r'^(2mass|sdss|ztf|lsst|atlas)'), '');
  const order = ['g', 'r', 'i', 'z', 'y', 'j', 'h', 'k'];
  if (b == 'ks') b = 'k';
  final i = order.indexOf(b);
  if (i < 0) return ('other', -1);
  return (i >= 5 ? b.toUpperCase() : b, i);
}

class _LightCurve extends StatelessWidget {
  const _LightCurve(this.doc);
  final Map<String, dynamic> doc;

  @override
  Widget build(BuildContext context) {
    final pal = Palette.of(context);
    final c = (doc['optical'] as Map).cast<String, dynamic>();
    final phot = ((c['photometry'] as List?) ?? const []).cast<Map<String, dynamic>>();
    if (phot.isEmpty) return const Center(child: Text('No photometry.'));
    final det = phot.where((p) => p['upper_limit'] != true).toList();
    final mjd0 = ((det.isNotEmpty ? det : phot).map((p) => (p['mjd'] as num).toDouble()).reduce((a, b) => a < b ? a : b));
    final t0 = DateTime.parse(((det.isNotEmpty ? det : phot).firstWhere((p) => (p['mjd'] as num).toDouble() == mjd0))['time'] as String);
    double days(String iso) => DateTime.parse(iso).difference(t0).inMilliseconds / 86400000.0;

    final by = <String, List<Pt>>{};
    final slot = <String, int>{};
    for (final p in phot) {
      final (label, s) = filterOf(p['band'] as String? ?? '');
      slot[label] = s;
      by.putIfAbsent(label, () => []).add(Pt((p['mjd'] as num).toDouble() - mjd0, (p['mag'] as num).toDouble(),
          err: asDouble(p['mag_err']), limit: p['upper_limit'] == true, note: '${p['band']} ${p['survey'] ?? ''}'.trim()));
    }
    final names = by.keys.toList()..sort((a, b) => (slot[a]! < 0 ? 99 : slot[a]!).compareTo(slot[b]! < 0 ? 99 : slot[b]!));
    final series = [for (final n in names) Series(n, slot[n]! < 0 ? pal.other : pal.series(slot[n]!), by[n]!)];
    final marks = <VMark>[];
    for (final m in ((doc['marks'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      if (m['time'] == null) continue;
      marks.add(VMark(days(m['time'] as String), m['label'] as String, pal.ink2));
    }
    final w = (doc['window'] as Map?)?.cast<String, dynamic>();
    final bands = [
      if (w != null) VBand(days(w['start'] as String), days(w['end'] as String), 'merger-time window (${w['method']})', pal.series(7)),
    ];
    final nLim = phot.where((p) => p['upper_limit'] == true).length;
    return ListView(padding: const EdgeInsets.all(12), children: [
      XYPlot(
          title: 'Photometry of ${c['name']}',
          series: series,
          vmarks: marks,
          vbands: bands,
          invertY: true,
          height: 320,
          xLabel: 'days since first detection (${fmtTime(t0, seconds: false)} UTC)',
          yLabel: 'magnitude'),
      const SizedBox(height: 8),
      Text(
          '${phot.length - nLim} detections${nLim > 0 ? ', $nLim upper limits (open triangles)' : ''}. '
          'Brighter is up. Tap a point for its values.',
          style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

class _Runs extends StatelessWidget {
  const _Runs(this.name, this.runs, this.hidden);
  final String name;
  final List<Map<String, dynamic>> runs;
  final int hidden;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (runs.isEmpty && hidden == 0) return const Center(child: Text('No search has been run for this optical transient.'));
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      if (hidden > 0)
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text('$hidden run${hidden == 1 ? '' : 's'} on LVK data not shown: the access token does not allow them.',
                style: Theme.of(context).textTheme.bodySmall)),
      for (final r in runs.reversed) _RunCard(r, state.archive.doc('run/$name/${r['run']}')),
    ]);
  }
}

class _RunCard extends StatelessWidget {
  const _RunCard(this.st, this.detail);
  final Map<String, dynamic> st;
  final Map<String, dynamic>? detail;

  @override
  Widget build(BuildContext context) {
    final pal = Palette.of(context);
    final results = ((detail?['results'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final snr = (detail?['snr'] as Map?)?.cast<String, dynamic>();
    final pe = ((detail?['pe'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final children = <Widget>[
      Row(children: [
        Expanded(child: Text(st['run'] as String, style: Theme.of(context).textTheme.titleSmall)),
        StatusChip(st['status'] as String),
      ]),
      const SizedBox(height: 4),
      if ((st['detail'] as String? ?? '').isNotEmpty) Text(st['detail'] as String),
      _fact(context, 'Data', '${st['data_source'] ?? 'unknown'} (${st['visibility'] == 'lvk' ? 'LVK, not public' : 'public'})'),
      if (st['submitted'] != null) _fact(context, 'Submitted', '${fmtTime(DateTime.tryParse(st['submitted'] as String))} UTC'),
      if (st['started'] != null) _fact(context, 'Started', '${fmtTime(DateTime.tryParse(st['started'] as String))} UTC on ${st['host']}'),
      if (st['ended'] != null) _fact(context, 'Ended', '${fmtTime(DateTime.tryParse(st['ended'] as String))} UTC'),
      if (st['subsegments_total'] != null)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Sub-segments: ${st['subsegments_done']} of ${st['subsegments_total']}', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 3),
              LinearProgressIndicator(value: (st['subsegments_done'] as num) / (st['subsegments_total'] as num)),
            ])),
      if (st['error'] != null)
        Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.cancel, color: Palette.critical, size: 18),
              const SizedBox(width: 6),
              Expanded(child: SelectableText(st['error'] as String)),
            ])),
      if (st['note'] != null) _fact(context, 'Note', st['note'] as String),
    ];
    for (final r in results) {
      final lo = (r['loudest'] as Map?)?.cast<String, dynamic>() ?? const {};
      final ifo = (lo['loudest_rho_ifo'] as Map?)?.cast<String, dynamic>() ?? const {};
      children.addAll([
        const Divider(),
        _fact(context, 'Loudest GW trigger',
            'reweighted SNR ${fmtNum(lo['loudest_rho_net'] as num?, sig: 4)} at GPS ${fmtNum(lo['loudest_gps'] as num?, sig: 13)}'),
        if (ifo.isNotEmpty) _fact(context, 'Per detector', ifo.entries.map((e) => '${e.key} ${fmtNum(e.value as num?, sig: 3)}').join(', ')),
        _fact(context, 'Chirp mass', '${fmtNum(lo['loudest_mchirp'] as num?, sig: 5)} solar masses'),
        _fact(context, 'p-value', '${fmtNum(r['p_value'] as num?)} (${r['bank_size']} templates)'),
      ]);
      // background of the sub-segment holding the loudest trigger
      final subs = ((r['subsegments'] as List?) ?? const []).cast<Map<String, dynamic>>();
      if (subs.isNotEmpty) {
        final best = subs.reduce((a, b) => ((a['loudest_rho_net'] as num?) ?? 0) >= ((b['loudest_rho_net'] as num?) ?? 0) ? a : b);
        final off = ((best['offsource'] as List?) ?? const []).map((x) => (x as num).toDouble()).toList();
        final bg = ((best['background'] as List?) ?? const []).map((x) => (x as num).toDouble()).toList();
        final vals = off.isNotEmpty ? off : bg;
        final loud = asDouble(best['loudest_rho_net']);
        if (vals.isNotEmpty && loud != null) {
          final maxBg = vals.reduce((a, b) => a > b ? a : b);
          children.addAll([
            const SizedBox(height: 10),
            XYPlot(
                title: off.isNotEmpty ? 'Loudest of each of ${off.length} off-source trials' : 'Background from ${bg.length} time slides',
                series: [histogram('trials', pal.series(0), vals, bins: 20)],
                vmarks: [VMark(loud, 'on-source ${fmtNum(loud, sig: 4)}', pal.ink, dashed: false)],
                height: 200,
                xLabel: 'reweighted SNR',
                yLabel: 'trials'),
            Text(
                loud > maxBg
                    ? 'The on-source trigger is louder than every trial (loudest trial ${fmtNum(maxBg, sig: 4)}).'
                    : '${vals.where((v) => v >= loud).length} of ${vals.length} trials are at least as loud as the on-source trigger.',
                style: Theme.of(context).textTheme.bodySmall),
          ]);
        }
      }
    }
    if (snr != null) children.addAll(_snrPlots(context, snr, pal));
    if (pe.isNotEmpty) children.addAll(_pePlots(context, pe, pal, st));
    return Card(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children)));
  }

  List<Widget> _snrPlots(BuildContext context, Map<String, dynamic> snr, Palette pal) {
    final peak = (snr['peak'] as Map).cast<String, dynamic>();
    final tp = (peak['gps'] as num).toDouble();
    final ifos = ((snr['ifos'] as List?) ?? const []).cast<String>();
    List<Series> build(Map<String, dynamic> block, double scale) {
      final t = (block['t'] as List).map((x) => ((x as num).toDouble() - tp) * scale).toList();
      List<Pt> pts(String k) {
        final v = (block[k] as List?) ?? const [];
        return [for (var i = 0; i < v.length && i < t.length; i++) Pt(t[i], (v[i] as num).toDouble())];
      }

      return [
        Series('coherent', pal.series(0), pts('coherent'), style: SeriesStyle.line),
        for (var i = 0; i < ifos.length; i++) Series(ifos[i], pal.series(i + 1), pts(ifos[i]), style: SeriesStyle.line),
        Series('null', pal.other, pts('null'), style: SeriesStyle.line),
      ];
    }

    final gates = <VBand>[];
    ((snr['gates'] as Map?) ?? const {}).forEach((ifo, list) {
      for (final g in (list as List)) {
        final x = (g as num).toDouble() - tp;
        gates.add(VBand(x - 0.25, x + 0.25, 'gate in $ifo', pal.series(7)));
      }
    });
    return [
      const Divider(),
      XYPlot(
          title: 'SNR of the loudest template over the window',
          series: build((snr['window'] as Map).cast<String, dynamic>(), 1),
          vbands: gates,
          height: 240,
          xLabel: 'seconds from the peak (GPS ${fmtNum(tp, sig: 13)})',
          yLabel: 'SNR'),
      const SizedBox(height: 12),
      XYPlot(
          title: 'Around the peak',
          series: build((snr['zoom'] as Map).cast<String, dynamic>(), 1000),
          height: 240,
          xLabel: 'milliseconds from the peak',
          yLabel: 'SNR'),
      Text(
          'Peak: coherent ${fmtNum(peak['coherent'] as num?, sig: 4)}, '
          '${ifos.map((i) => '$i ${fmtNum(peak[i] as num?, sig: 3)}').join(', ')}, null ${fmtNum(peak['null'] as num?, sig: 3)}.',
          style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  List<Widget> _pePlots(BuildContext context, List<Map<String, dynamic>> pe, Palette pal, Map<String, dynamic> st) {
    final out = <Widget>[const Divider(), Text('Parameter estimation', style: Theme.of(context).textTheme.titleSmall)];
    final warn = (st['pe'] as Map?) ?? const {};
    // common axes, so that the two posteriors can be compared one above the other
    List<double> samples(Map<String, dynamic> p, String key) =>
        (((p['samples'] as Map?)?[key] as List?) ?? const []).map((x) => (x as num).toDouble()).toList();
    for (final key in ['luminosity_distance', 'viewing_angle_deg']) {
      final all = [for (final p in pe) ...samples(p, key)];
      if (all.isEmpty) continue;
      final lo = all.reduce((a, b) => a < b ? a : b), hi = all.reduce((a, b) => a > b ? a : b);
      for (final p in pe) {
        final s = (p['summary'] as Map).cast<String, dynamic>();
        final em = s['em_priors'] == true;
        final v = samples(p, key);
        if (v.isEmpty) continue;
        out.addAll([
          const SizedBox(height: 10),
          XYPlot(
              title: '${key == 'luminosity_distance' ? 'Distance' : 'Viewing angle'}, ${em ? 'with the EM priors' : 'GW only'}',
              series: [histogram(em ? 'EM priors' : 'GW only', pal.series(em ? 0 : 1), v, bins: 30, lo: lo, hi: hi)],
              xMin: lo,
              xMax: hi,
              height: 150,
              xLabel: key == 'luminosity_distance' ? 'luminosity distance (Mpc)' : 'viewing angle (deg)',
              yLabel: 'samples'),
        ]);
      }
    }
    for (final p in pe) {
      final s = (p['summary'] as Map).cast<String, dynamic>();
      final which = s['em_priors'] == true ? 'em' : 'gw';
      final d = ((s['posterior'] as Map?)?['luminosity_distance'] as Map?);
      final ws = (((warn[which] as Map?)?['warnings'] as List?) ?? const []).cast<String>();
      out.addAll([
        const SizedBox(height: 8),
        Text(which == 'em' ? 'With the EM priors' : 'GW only', style: const TextStyle(fontWeight: FontWeight.w600)),
        if (d != null) _fact(context, 'Distance', '${fmtNum(d['median'] as num?)} Mpc (${fmtNum(d['lower'] as num?)} to ${fmtNum(d['upper'] as num?)})'),
        _fact(context, 'log Bayes factor', fmtNum(s['log_bayes_factor'] as num?, sig: 4)),
        _fact(context, 'Max-likelihood SNR', fmtNum((s['maximum_likelihood'] as Map?)?['snr'] as num?, sig: 4)),
        for (final w in ws)
          Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.warning_amber_rounded, color: Palette.serious, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(w)),
              ])),
      ]);
    }
    return out;
  }
}
