/// Candidates (follow-ups the pipeline labels as such): the list, and one page per follow-up.
library;

import 'package:flutter/material.dart';

import '../archive.dart';
import '../followup.dart';
import 'circulars.dart';
import 'common.dart';
import 'history.dart';
import 'logbook.dart';
import 'plots.dart';
import 'reported.dart';
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
    // those ready for a targeted search first, then newest first as the server gives them
    final list = [
      ...every.where((f) => f['ready'] == true),
      ...every.where((f) => f['ready'] != true && (all || f['candidate'] == true)),
    ];
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
    final pal = Palette.of(context);
    final members = ((f['members'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final reasons = ((f['reasons'] as List?) ?? const []).cast<String>();
    final notes = ((f['notes'] as List?) ?? const []).cast<String>();
    final att = f['attention'] as String?;
    final isCand = f['candidate'] == true;
    final small = Theme.of(context).textTheme.bodySmall;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: () => openFollowUp(context, f),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(members.map((m) => '${typeLabel(m['type'] as String)} ${m['name']}').join('  +  '),
                      style: Theme.of(context).textTheme.titleSmall)),
              if (att != null) StatusChip(att),
            ]),
            if (f['ready'] == true)
              Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(children: [
                    Icon(Icons.campaign, size: 18, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text('Ready for a targeted search: confirmed as a kilonova and within reach. No search started yet.',
                            style: small?.copyWith(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary))),
                  ])),
            const SizedBox(height: 4),
            Text(
                '${isCand ? 'Candidate' : 'Not a candidate'}  ·  started from ${typeLabel(f['origin'] as String)} ${f['origin_name']}'
                '${f['time'] != null ? ', ${fmtTime(DateTime.tryParse(f['time'] as String), seconds: false)} UTC' : ''}',
                style: small?.copyWith(fontWeight: FontWeight.w600, color: isCand ? pal.ink : pal.ink2)),
            for (final r in reasons) Text('· $r', style: small),
            if (!isCand) Text('No link to another detection type, and nothing that marks it as a candidate.', style: small),
            // a GRB whose redshift puts it beyond the range of a GW search
            for (final n in notes) Text('· $n', style: small?.copyWith(fontWeight: FontWeight.w600)),
            // what the GCN Circulars report about its alerts
            for (final m in members)
              if (m['circulars'] is Map)
                Text('GCN  ·  ${typeLabel(m['type'] as String)} ${m['name']}: ${circularShort((m['circulars'] as Map).cast<String, dynamic>())}',
                    style: small?.copyWith(color: pal.ink2)),
            const SizedBox(height: 10),
            HistoryDiagram(f),
          ]),
        ),
      ),
    );
  }
}

/// Opens the page of a follow-up; one that was announced as ready leaves the banner.
void openFollowUp(BuildContext context, Map<String, dynamic> f) {
  final state = AppScope.of(context);
  final optical = f['optical'] as String?;
  if (optical != null && f['ready'] == true) state.markReadySeen(optical);
  Navigator.push(
      context,
      MaterialPageRoute<void>(
          builder: (_) => AppScope(
              state: state,
              child: optical != null && state.archive.doc('optical/$optical') != null
                  ? CandidateScreen(optical, followUp: f)
                  : FollowUpScreen(f))));
}

/// On every main screen: the optical transients that became ready for a targeted
/// search and that nobody has opened yet. The pipeline starts no search by itself.
class ReadyBanner extends StatelessWidget {
  const ReadyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final ready = state.readyUnseen;
    if (ready.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
        color: scheme.primaryContainer,
        child: Column(children: [
          for (final f in ready)
            InkWell(
                onTap: () => openFollowUp(context, f),
                child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(children: [
                      Icon(Icons.campaign, color: scheme.onPrimaryContainer),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Text(
                              '${f['optical']} is ready for a targeted search: confirmed as a kilonova and within reach. '
                              'No search is started automatically.',
                              style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onPrimaryContainer))),
                      Text('Open', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer)),
                      Icon(Icons.chevron_right, color: scheme.onPrimaryContainer),
                    ]))),
        ]));
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
    final keys = {for (final m in members) m['key'] as String};
    return DefaultTabController(
      length: (gw != null ? 3 : 2) + reportedCategories.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(f['title'] as String? ?? '${typeLabel((f['id'] as String).split(':').first)} ${f['name']}'),
          bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            const Tab(text: 'Follow-up'),
            if (gw != null) const Tab(text: 'Log'),
            const Tab(text: 'Sky'),
            for (final c in reportedCategories) Tab(text: reportedTitle(c)),
          ]),
        ),
        body: TabBarView(children: [
          ListView(padding: const EdgeInsets.only(bottom: 24), children: [FollowUpSummary(f)]),
          if (gw != null) LogList(query: LogQuery(superevent: gw['id'] as String)),
          SkyView(startId: f['id'] as String),
          for (final c in reportedCategories) ReportedTab(keys, c),
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
    final members = ((f['members'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final notes = ((f['notes'] as List?) ?? const []).cast<String>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (notes.isNotEmpty)
        _section(context, 'Distance', [
          for (final n in notes) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('· $n')),
          Text('From the redshift announced in a GCN Circular; the optical transients are not changed.',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      _section(context, f['candidate'] == true ? 'Candidate' : 'Follow-up, not a candidate', [
        for (final r in reasons) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('· $r')),
        if (reasons.isEmpty) const Text('No link to another detection type, and nothing that marks it as a candidate.'),
        const SizedBox(height: 10),
        Text('History: detections in order of time, then the pipeline', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 6),
        HistoryDiagram(f),
      ]),
      CircularsSection([for (final m in members) m['key'] as String]),
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
    final fu = followUp ?? state.followups.where((f) => f['optical'] == name).firstOrNull;
    // the circulars about the transient and about the alerts it is followed with (its burst)
    final keys = {'optical:$name', for (final m in ((fu?['members'] as List?) ?? const []).cast<Map>()) m['key'] as String};
    return DefaultTabController(
      length: 6 + reportedCategories.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(followUp?['title'] as String? ?? 'Optical $name'),
          bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            const Tab(text: 'Follow-up'),
            const Tab(text: 'Log'),
            const Tab(text: 'Light curve'),
            const Tab(text: 'GW search'),
            const Tab(text: 'Sky'),
            for (final c in reportedCategories) Tab(text: reportedTitle(c)),
            const Tab(text: 'Brokers'),
          ]),
        ),
        body: TabBarView(children: [
          _FollowUp(doc, fetched, fu),
          LogList(query: LogQuery(optical: name)),
          _LightCurve(doc),
          _Runs(name, runs, (doc['hidden_runs'] as int?) ?? 0, ((doc['launches'] as List?) ?? const []).cast<Map<String, dynamic>>()),
          SkyView(focus: name),
          for (final c in reportedCategories) ReportedTab(keys, c),
          BrokersTab((doc['brokers'] as Map?)?.cast<String, dynamic>()),
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

/// Unit of a time axis for values in days, and what to multiply them by:
/// days when they span three days or more, else hours, minutes or seconds.
(String, double) timeUnit(Iterable<double> days) {
  if (days.isEmpty) return ('days', 1);
  final span = days.reduce((a, b) => a > b ? a : b) - days.reduce((a, b) => a < b ? a : b);
  if (span >= 3) return ('days', 1);
  if (span >= 3 / 24) return ('hours', 24);
  if (span >= 3 / 1440) return ('minutes', 1440);
  return span > 0 ? ('seconds', 86400) : ('days', 1);
}

/// The distance of a decision. Without a redshift or a distance the stored
/// numbers are those of the assumed prior, the same for every transient: they
/// are not shown as an estimate. (Decisions written before the pipeline
/// recorded `distance_informed` are judged on their list of constraints.)
String distanceText(Map<String, dynamic> di, String Function(Map?, String) range) {
  final cons = ((di['constraints'] as List?) ?? const []).map((e) => e.toString());
  final informed = di['distance_informed'] as bool? ??
      cons.any((c) => c.startsWith('redshift') || c.startsWith('distance') || c.startsWith('lc_fit'));
  if (informed) return range(di['luminosity_distance_mpc'] as Map?, 'Mpc');
  final prior = RegExp(r'D_L < ([0-9.]+) Mpc').firstMatch((di['distance_prior'] ?? '').toString())?.group(1);
  final limit = prior == null ? null : double.tryParse(prior);
  return limit == null
      ? 'not constrained (no redshift or distance)'
      : 'not constrained (no redshift or distance; assumed below ${fmtNum(limit)} Mpc)';
}

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
          _fact(context, 'Targeted search',
              d['trigger_targeted_search'] == true ? 'ready: confirmed as a kilonova and within reach (a person starts it)' : 'held'),
          if (win != null)
            _fact(context, 'Merger-time window',
                '${fmtNum((win['duration_h'] as num) * 3600)} s, from ${win['method']} (GPS ${fmtNum(win['gps_start'] as num?, sig: 12)})'),
          if (di != null) _fact(context, 'Distance', distanceText(di, range)),
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
    // magnitudes reported in GCN Circulars: shown apart, not part of the photometry until accepted
    final reported = ((doc['reported_photometry'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final timed = reported.where((p) => p['time'] is String && p['accepted'] != true).toList();
    if (phot.isEmpty && reported.isEmpty) return const Center(child: Text('No photometry.'));
    final det = phot.where((p) => p['upper_limit'] != true).toList();
    // origin of the time axis: the first detection, else the first reported magnitude that has a time
    final DateTime? t0 = phot.isNotEmpty
        ? DateTime.parse((det.isNotEmpty ? det : phot).reduce((a, b) => (a['mjd'] as num) <= (b['mjd'] as num) ? a : b)['time'] as String)
        : (timed.isEmpty ? null : timed.map((p) => DateTime.parse(p['time'] as String)).reduce((a, b) => a.isBefore(b) ? a : b));
    final mjd0 = phot.isEmpty
        ? 0.0
        : (det.isNotEmpty ? det : phot).map((p) => (p['mjd'] as num).toDouble()).reduce((a, b) => a < b ? a : b);
    double days(String iso) => t0 == null ? 0 : DateTime.parse(iso).difference(t0).inMilliseconds / 86400000.0;
    // the unit of the time axis follows what is shown: a burst and its first magnitudes are seconds
    // or minutes apart, a light curve days
    final (unit, k) = timeUnit([
      for (final p in phot) (p['mjd'] as num).toDouble() - mjd0,
      for (final p in timed) days(p['time'] as String),
      for (final m in ((doc['marks'] as List?) ?? const []).cast<Map<String, dynamic>>())
        if (m['time'] != null) days(m['time'] as String),
      for (final key in const ['start', 'end'])
        if ((doc['window'] as Map?)?[key] != null) days((doc['window'] as Map)[key] as String),
    ]);
    String magText(Map<String, dynamic> p) =>
        '${p['band']} ${p['upper_limit'] == true ? '>' : '='} ${fmtNum(p['mag'] as num, sig: 4)}'
        '${p['mag_err'] != null ? ' ± ${fmtNum(p['mag_err'] as num, sig: 2)}' : ''}'
        '${p['system'] != null ? ' (${p['system']})' : ''}';

    final by = <String, List<Pt>>{};
    final slot = <String, int>{};
    for (final p in phot) {
      final (label, s) = filterOf(p['band'] as String? ?? '');
      slot[label] = s;
      by.putIfAbsent(label, () => []).add(Pt(((p['mjd'] as num).toDouble() - mjd0) * k, (p['mag'] as num).toDouble(),
          err: asDouble(p['mag_err']), limit: p['upper_limit'] == true, note: '${p['band']} ${p['survey'] ?? ''}'.trim()));
    }
    final names = by.keys.toList()..sort((a, b) => (slot[a]! < 0 ? 99 : slot[a]!).compareTo(slot[b]! < 0 ? 99 : slot[b]!));
    final series = [
      for (final n in names) Series(n, slot[n]! < 0 ? pal.other : pal.series(slot[n]!), by[n]!),
      if (timed.isNotEmpty)
        Series('reported in GCN, not verified', pal.muted, [
          for (final p in timed)
            Pt(days(p['time'] as String) * k, (p['mag'] as num).toDouble(),
                err: asDouble(p['mag_err']), limit: p['upper_limit'] == true, note: '${magText(p)}, GCN ${p['circular']}')
        ]),
    ];
    final marks = <VMark>[];
    for (final m in ((doc['marks'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      if (m['time'] == null) continue;
      marks.add(VMark(days(m['time'] as String) * k, m['label'] as String, pal.ink2));
    }
    final w = (doc['window'] as Map?)?.cast<String, dynamic>();
    final bands = [
      if (w != null) VBand(days(w['start'] as String) * k, days(w['end'] as String) * k, 'merger-time window (${w['method']})', pal.series(7)),
    ];
    final nLim = phot.where((p) => p['upper_limit'] == true).length;
    final small = Theme.of(context).textTheme.bodySmall;
    return ListView(padding: const EdgeInsets.all(12), children: [
      if (t0 != null && series.isNotEmpty)
        XYPlot(
            title: 'Photometry of ${c['name']}',
            series: series,
            vmarks: marks,
            vbands: bands,
            invertY: true,
            height: 320,
            xLabel: '$unit since ${phot.isEmpty ? 'the first reported magnitude' : 'first detection'} (${fmtTime(t0, seconds: false)} UTC)',
            yLabel: 'magnitude'),
      const SizedBox(height: 8),
      Text(
          phot.isEmpty
              ? 'No photometry in the pipeline for this optical transient.'
              : '${phot.length - nLim} detections${nLim > 0 ? ', $nLim upper limits (open triangles)' : ''}. '
                  'Brighter is up. Tap a point for its values.',
          style: small),
      if (reported.isNotEmpty) ...[
        const SizedBox(height: 14),
        Text('Reported in GCN Circulars (${reported.length})', style: Theme.of(context).textTheme.titleSmall),
        Text(
            'Read from the text of the circulars by a pattern, not verified: these magnitudes are not used by the '
            'pipeline until they are accepted (raven-kn accept-photometry). One without a time cannot be plotted.',
            style: small),
        const SizedBox(height: 4),
        for (final p in reported)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                    '${magText(p)}  ·  '
                    '${p['time'] is String ? '${fmtTime(DateTime.tryParse(p['time'] as String), seconds: false)} UTC (${p['time_from']})' : 'no time found'}'
                    '  ·  GCN ${p['circular']}${p['accepted'] == true ? '  ·  accepted' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('${p['text']}', style: small?.copyWith(color: pal.ink2), maxLines: 3, overflow: TextOverflow.ellipsis),
              ])),
      ],
    ]);
  }
}

class _Runs extends StatefulWidget {
  const _Runs(this.name, this.runs, this.hidden, this.launches);
  final String name;
  final List<Map<String, dynamic>> runs;
  final int hidden;

  /// Searches asked for from the application, with what became of them.
  final List<Map<String, dynamic>> launches;

  @override
  State<_Runs> createState() => _RunsState();
}

class _RunsState extends State<_Runs> {
  String data = 'site', statistic = 'coherent';
  bool sending = false;
  String? message;

  String get name => widget.name;
  List<Map<String, dynamic>> get runs => widget.runs;
  int get hidden => widget.hidden;

  Future<void> _start(BuildContext context) async {
    final state = AppScope.of(context);
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Start a targeted search'),
              content: Text(data == 'replay'
                  ? 'A TEST on the O4 data replayed on the Virgo site: the search of $name is run on the latest replay data, '
                      'which have nothing to do with the sky of this alert.'
                  : 'The search of $name is run on the Virgo site, on the online strain of the detectors around its window. '
                      'It is refused if fewer than two detectors have observing data there.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start')),
              ],
            ));
    if (ok != true || !mounted) return;
    setState(() {
      sending = true;
      message = null;
    });
    final err = await state.requestSearch(name, data: data, statistic: statistic);
    if (!mounted) return;
    setState(() {
      sending = false;
      message = err == null ? 'Asked for. The launcher on the Virgo site takes it within seconds; sync to follow it.' : 'Not started: $err';
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final pal = Palette.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final busy = widget.launches.any((l) => l['status'] == 'requested' || l['status'] == 'running');
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      _section(context, 'Start a targeted search', [
        if (!state.canStartSearch)
          Text(
              switch (state.virgoSearchStatus) {
                'refused' => 'The server refused the Virgo Targeted search token saved in Settings.',
                'not configured' => 'The server has no Virgo Targeted search token: no search can be started from here.',
                _ => 'Starting a search needs the Virgo Targeted search token (Settings).',
              },
              style: small)
        else ...[
          Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'site', label: Text('Site data')),
                  ButtonSegment(value: 'replay', label: Text('O4 replay (test)')),
                ],
                selected: {data},
                onSelectionChanged: (s) => setState(() => data = s.first)),
            SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'coherent', label: Text('Coherent')),
                  ButtonSegment(value: 'network', label: Text('Network')),
                ],
                selected: {statistic},
                onSelectionChanged: (s) => setState(() => statistic = s.first)),
            FilledButton.icon(
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(sending ? 'Asking...' : 'Start targeted search'),
                onPressed: sending || busy ? null : () => _start(context)),
          ]),
          const SizedBox(height: 6),
          Text(
              busy
                  ? 'A search of this optical transient is already waiting or running.'
                  : 'Run on the Virgo site by the launcher, from the frames kept there. Nothing starts a search but this button; '
                      'the search decision does not have to be "ready".',
              style: small),
          if (message != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(message!, style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
        // what was asked for from the application, newest first
        for (final l in widget.launches.reversed)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(
                    StatusStyle.of(switch (l['status']) { 'requested' => 'pending', 'refused' => 'held', final s => '$s' }, context).icon,
                    size: 18,
                    color: StatusStyle.of(switch (l['status']) { 'requested' => 'pending', 'refused' => 'held', final s => '$s' }, context).color),
                const SizedBox(width: 6),
                Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                      '${switch (l['status']) { 'requested' => 'Waiting for the launcher', 'running' => 'Running', 'done' => 'Done', 'refused' => 'Refused', 'failed' => 'Failed', final s => '$s' }}'
                      '  ·  ${l['data'] == 'replay' ? 'O4 replay (test)' : 'site data'}, ${l['statistic']}'
                      '  ·  asked ${fmtTime(DateTime.tryParse(l['requested'] as String? ?? ''), seconds: false)} UTC',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  if ((l['detail'] as String? ?? '').isNotEmpty) Text(l['detail'] as String, style: small?.copyWith(color: pal.ink2)),
                ])),
              ])),
      ]),
      if (runs.isEmpty && hidden == 0)
        const Padding(padding: EdgeInsets.all(16), child: Text('No search has been run for this optical transient.')),
      if (hidden > 0)
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text('$hidden run${hidden == 1 ? '' : 's'} on LVK data not shown: the token saved in Settings does not give access to LVK data.',
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
