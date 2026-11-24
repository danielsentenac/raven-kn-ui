// What the GCN Circulars about a follow-up report, by category: prompt
// emission, afterglow, spectroscopy (each with its plots and pages), the data
// files they link to, and the sky maps shown with the sky view. The pipeline reads
// these from the text by keyword rules; nothing here is verified, so each
// value is shown with its circular and the sentence it comes from.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'circulars.dart';
import 'common.dart';

const reportedCategories = ['prompt', 'afterglow', 'spectroscopy', 'links'];

String reportedTitle(String category) => switch (category) {
      'prompt' => 'Prompt emission',
      'afterglow' => 'Afterglow',
      'spectroscopy' => 'Spectroscopy',
      _ => 'Available data',
    };

/// Kinds of a category in the order shown, with their names.
const _kinds = <String, List<(String, String)>>{
  'prompt': [
    ('burst_class', 'Short or long'),
    ('t90', 'Duration T90'),
    ('fluence', 'Fluence'),
    ('peak_flux', 'Peak flux'),
    ('epeak', 'Peak energy'),
    ('epeak_rest', 'Peak energy, rest frame'),
    ('photon_index', 'Spectral index'),
    ('eiso', 'Isotropic energy'),
    ('liso', 'Isotropic peak luminosity'),
  ],
  'afterglow': [
    ('decay_index', 'Decay index (flux ~ t^index)'),
    ('xray_flux', 'X-ray flux'),
    ('nh', 'Hydrogen column density'),
    ('radio_flux', 'Radio flux density'),
  ],
  'spectroscopy': [
    ('redshift', 'Redshift'),
    ('lines', 'Lines'),
    ('host', 'Host galaxy'),
  ],
};

/// What the circulars linked to the alerts [keys] (`grb:<id>`, `optical:<name>`...)
/// report: `prompt`, `afterglow`, `spectroscopy`, `photometry` and `links`,
/// oldest circular first, each item with `circular` and `subject`.
Map<String, List<Map<String, dynamic>>> reportedOf(Iterable<Map<String, dynamic>> circulars, Set<String> keys) {
  final out = {for (final k in [...reportedCategories, 'photometry']) k: <Map<String, dynamic>>[]};
  final list = circulars.where((c) {
    final links = ((c['links'] as List?) ?? const []).cast<Map>();
    return links.any((l) => keys.contains('${l['type']}:${l['id']}'));
  }).toList()
    ..sort((a, b) => ((a['id'] as num?) ?? 0).compareTo((b['id'] as num?) ?? 0));
  for (final c in list) {
    final src = {'circular': c['id'], 'subject': c['subject'], 'published': c['time']};
    if (c['redshift'] != null) {
      out['spectroscopy']!.add({'kind': 'redshift', 'value': c['redshift'], 'what': c['redshift_kind'], 'text': c['subject'], ...src});
    }
    for (final f in ((c['facts'] as List?) ?? const []).cast<Map>()) {
      final cat = f['category'] as String?;
      if (cat != null && out.containsKey(cat) && cat != 'links') out[cat]!.add({...f.cast<String, dynamic>(), ...src});
    }
    for (final p in ((c['photometry'] as List?) ?? const []).cast<Map>()) {
      out['photometry']!.add({...p.cast<String, dynamic>(), ...src});
    }
    for (final l in ((c['web_links'] as List?) ?? const []).cast<Map>()) {
      final link = l.cast<String, dynamic>();
      if (linkIsGeneral(link)) continue; // the page of a telescope or of a collaboration: not about the event
      out['links']!.add({...link, 'category': linkCategory(link, c), ...src});
    }
  }
  return out;
}

/// A link that is not about the event (as marked by the server; for an older
/// server: not an image, and no number of five digits in its path).
bool linkIsGeneral(Map<String, dynamic> l) {
  if (l['general'] is bool) return l['general'] as bool;
  final path = (l['url'] as String? ?? '').replaceFirst(RegExp(r'^https?://[^/]+'), '');
  return l['kind'] != 'image' && !RegExp(r'\d{5}').hasMatch(path);
}

/// Where a plot or a page of the circular [c] is shown: a sky map with the
/// sky view (`sky`), a spectrum with the spectroscopy, what a gamma-ray
/// instrument (or the X-ray instrument that detected the burst) shows with
/// the prompt emission, the follow-up at other wavelengths with the afterglow.
/// Data files are listed apart, in Available data.
String linkCategory(Map<String, dynamic> l, Map<String, dynamic> c) {
  final bands = ((c['bands'] as List?) ?? const []).cast<String>();
  final subject = (c['subject'] as String? ?? '').toLowerCase();
  final words = '${l['text'] ?? ''} ${l['url'] ?? ''}'.toLowerCase();
  if (l['about'] == 'sky map') return 'sky';
  if (words.contains('spectr') && !bands.contains('gamma')) return 'spectroscopy';
  if (bands.contains('gamma')) return 'prompt';
  if (bands.length == 1 && bands.first == 'xray' && subject.contains('detection of')) return 'prompt';
  if (bands.any((b) => b == 'optical' || b == 'xray' || b == 'radio')) return 'afterglow';
  // a circular without label: the light curve of a burst rather than a follow-up
  return l['about'] == 'light curve' || l['about'] == 'diagram' ? 'prompt' : 'afterglow';
}

String _mantissa(double v) {
  var s = v.toStringAsPrecision(4);
  if (s.contains('e')) s = v.toString();
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s;
}

/// A reported value as it was written: `7.447 (-0.084 +0.121) s`,
/// `(2.05 -0.2 +0.15)e-5 erg/cm^2`, `about 0.2 mJy`, `below -3.1`.
String factValue(Map<String, dynamic> f) {
  final v = (f['value'] as num?)?.toDouble();
  if (v == null) return (f['what'] ?? '').toString();
  final lo = (f['err_minus'] as num?)?.toDouble(), hi = (f['err_plus'] as num?)?.toDouble();
  final a = v.abs();
  final e = (a != 0 && (a < 1e-3 || a >= 1e5)) ? (math.log(a) / math.ln10).floor() : 0;
  final k = math.pow(10.0, -e).toDouble();
  var s = _mantissa(v * k);
  if (lo != null && hi != null && lo == hi) {
    s = '$s ± ${_mantissa(lo * k)}';
  } else if (lo != null || hi != null) {
    s = '$s (${lo != null ? '-${_mantissa(lo * k)}' : ''}${lo != null && hi != null ? ' ' : ''}${hi != null ? '+${_mantissa(hi * k)}' : ''})';
  }
  if (e != 0) s = (lo != null || hi != null) ? '($s)e$e' : '${s}e$e';
  final unit = (f['unit'] ?? '').toString();
  final kind = f['what'] != null && f['kind'] == 'redshift' ? ' (${f['what']})' : '';
  return '${f['limit'] == true ? 'limit ' : ''}${f['approx'] == true ? 'about ' : ''}$s${unit.isEmpty ? '' : ' $unit'}$kind';
}

/// One tab: the facts of a category, or the images and links.
class ReportedTab extends StatelessWidget {
  const ReportedTab(this.keys, this.category, {super.key});
  final Set<String> keys;
  final String category;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final pal = Palette.of(context);
    final rep = reportedOf(state.circulars, keys);
    final items = category == 'links' ? const <Map<String, dynamic>>[] : rep[category]!;
    // the plots and pages of the circulars of this category, shown with its values
    final own = category == 'links'
        ? const <Map<String, dynamic>>[]
        : rep['links']!.where((l) => l['category'] == category && l['kind'] != 'data').toList();
    // Available data: the files only; the plots and the pages are in the tab they are about
    final files = rep['links']!.where((l) => l['kind'] == 'data').toList();
    final phot = category == 'afterglow' ? rep['photometry']! : const <Map<String, dynamic>>[];
    final children = <Widget>[
      Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
              'Reported in GCN Circulars, read from their text by keyword rules: not verified, and not used by the pipeline. '
              'Each value is given with its circular and the sentence it comes from.',
              style: small?.copyWith(color: pal.ink2))),
    ];
    if (items.isEmpty && phot.isEmpty && own.isEmpty && (category != 'links' || files.isEmpty)) {
      children.add(Padding(
          padding: const EdgeInsets.all(16),
          child: Text(state.archive.doc('circulars') == null
              ? 'Circulars not synced yet.'
              : category == 'links'
                  ? 'No circular about these alerts links to a data file.'
                  : 'No circular about these alerts reports this.')));
    } else if (category == 'links') {
      children.add(_card(context, 'Data files', [for (final l in files) _LinkRow(l)]));
    } else {
      final known = {for (final k in _kinds[category]!) k.$1};
      for (final (kind, title) in [
        ..._kinds[category]!,
        for (final k in {for (final f in items) f['kind'] as String}.difference(known)) (k, k)
      ]) {
        final rows = items.where((f) => f['kind'] == kind).toList();
        if (rows.isEmpty) continue;
        children.add(_card(context, title, [for (final f in rows) _FactRow(f)]));
      }
      if (phot.isNotEmpty) {
        children.add(_card(context, 'Optical and infrared magnitudes', [
          for (final p in phot)
            _FactRow({
              ...p,
              'what':
                  '${p['band']} ${p['upper_limit'] == true ? '>' : '='} ${p['mag']}${p['mag_err'] != null ? ' ± ${p['mag_err']}' : ''}${p['system'] != null ? ' ${p['system']}' : ''}',
              'band': p['time'] == null ? 'time not found' : '${fmtTime(DateTime.tryParse(p['time'] as String), seconds: false)} UTC',
            })
        ]));
      }
      children.addAll(reportedLinks(context, own));
    }
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: children);
  }

}

Widget _card(BuildContext context, String title, List<Widget> rows) => Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            ...rows,
          ])));

/// The plots (shown) and the pages (listed) of some links.
List<Widget> reportedLinks(BuildContext context, List<Map<String, dynamic>> items, {String title = 'Plots and images'}) {
  final images = items.where((l) => l['kind'] == 'image').toList();
  final others = items.where((l) => l['kind'] != 'image').toList();
  return [
    if (images.isNotEmpty)
      _card(context, title, [
        Text('Loaded from the sites named in the circulars.', style: Theme.of(context).textTheme.bodySmall),
        for (final l in images) _ImageLink(l),
      ]),
    if (others.isNotEmpty) _card(context, 'Pages about the event', [for (final l in others) _LinkRow(l)]),
  ];
}

/// Under the sky view: the sky maps that the circulars about the alerts
/// [keys] link to (localisations of the bursts, coverage of the searches).
class SkyReported extends StatelessWidget {
  const SkyReported(this.keys, {super.key});
  final Set<String> keys;

  @override
  Widget build(BuildContext context) {
    final maps = reportedOf(AppScope.of(context).circulars, keys)['links']!
        .where((l) => l['category'] == 'sky' && l['kind'] != 'data')
        .toList();
    if (maps.isEmpty) return const SizedBox.shrink();
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: reportedLinks(context, maps, title: 'Sky maps reported in GCN Circulars'));
  }
}

void _openCircular(BuildContext context, Map<String, dynamic> f) {
  final state = AppScope.of(context);
  Navigator.push(
      context, MaterialPageRoute<void>(builder: (_) => AppScope(state: state, child: CircularScreen(f['circular'] as int))));
}

String _source(Map<String, dynamic> f) => 'GCN ${f['circular']}';

class _FactRow extends StatelessWidget {
  const _FactRow(this.f);
  final Map<String, dynamic> f;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final pal = Palette.of(context);
    final where = [
      if (f['instrument'] != null) f['instrument'] as String,
      if (f['band'] != null) f['band'] as String,
      _source(f),
    ].join('  ·  ');
    final plain = f['kind'] == 'host'; // the sentence is the fact
    return InkWell(
        onTap: f['circular'] is int ? () => _openCircular(context, f) : null,
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (!plain) Text(factValue(f), style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(where, style: small?.copyWith(color: pal.ink2)),
                if ((f['text'] as String? ?? '').isNotEmpty) Text('"${f['text']}"', style: small),
              ])),
              Icon(Icons.chevron_right, color: pal.muted),
            ])));
  }
}

void _copy(BuildContext context, String url) {
  Clipboard.setData(ClipboardData(text: url));
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Address copied')));
}

class _LinkRow extends StatelessWidget {
  const _LinkRow(this.l);
  final Map<String, dynamic> l;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final pal = Palette.of(context);
    final url = l['url'] as String;
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((l['text'] as String? ?? '').isEmpty ? (l['kind'] == 'data' ? 'Data' : 'Page') : l['text'] as String,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            SelectableText(url, style: small),
            Text('${l['kind'] == 'data' ? 'data' : 'page'}${l['about'] != null ? ', ${l['about']}' : ''}  ·  ${_source(l)}',
                style: small?.copyWith(color: pal.ink2)),
          ])),
          IconButton(tooltip: 'Copy the address', icon: const Icon(Icons.copy, size: 18), onPressed: () => _copy(context, url)),
        ]));
  }
}

class _ImageLink extends StatelessWidget {
  const _ImageLink(this.l);
  final Map<String, dynamic> l;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final pal = Palette.of(context);
    final url = l['url'] as String;
    final caption = [
      if (l['about'] != null) l['about'] as String,
      _source(l),
      if ((l['subject'] as String? ?? '').isNotEmpty) l['subject'] as String,
    ].join('  ·  ');
    Widget image({BoxFit fit = BoxFit.contain}) => Image.network(url,
        fit: fit,
        loadingBuilder: (c, child, p) =>
            p == null ? child : const SizedBox(height: 120, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
        errorBuilder: (c, e, s) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('Image not loaded (no network, or the site does not answer).', style: small?.copyWith(color: pal.ink2))));
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(caption, style: const TextStyle(fontWeight: FontWeight.w600))),
            IconButton(tooltip: 'Copy the address', icon: const Icon(Icons.copy, size: 18), onPressed: () => _copy(context, url)),
          ]),
          if ((l['text'] as String? ?? '').isNotEmpty) Text(l['text'] as String, style: small),
          const SizedBox(height: 4),
          InkWell(
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                          appBar: AppBar(title: Text(caption)),
                          body: InteractiveViewer(maxScale: 8, child: Center(child: image()))))),
              child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 360), child: image())),
          SelectableText(url, style: small?.copyWith(color: pal.ink2)),
        ]));
  }
}

/// What the alert brokers have at the position of an optical transient
/// ([rec] is the `brokers` record of the server, null when not asked yet).
class BrokersTab extends StatelessWidget {
  const BrokersTab(this.rec, {super.key});
  final Map<String, dynamic>? rec;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final pal = Palette.of(context);
    final brokers = ((rec?['brokers'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
              rec == null
                  ? 'The brokers have not been asked about this transient yet.'
                  : 'The object nearest to the position in each alert broker, within ${fmtNum(rec!['radius_arcsec'] as num?)} arcsec, '
                      'asked ${fmtTime(DateTime.tryParse(rec!['time'] as String? ?? ''), seconds: false)} UTC. '
                      'Classifications and hosts are those of the brokers, from their classifiers and catalogue matches: '
                      'they are not applied to the transient and do not enter the decision.',
              style: small?.copyWith(color: pal.ink2))),
      for (final b in brokers) _BrokerCard(b),
    ]);
  }
}

/// One line of facts of a broker record, in the order shown.
List<(String, String)> brokerFacts(Map<String, dynamic> b) {
  final host = (b['host'] as Map?)?.cast<String, dynamic>();
  final tns = (b['tns'] as Map?)?.cast<String, dynamic>();
  String day(String k) => fmtTime(DateTime.tryParse(b[k] as String), seconds: false);
  return [
    if (b['object'] != null)
      ('Object', '${b['object']}${b['sep_arcsec'] != null ? ', ${fmtNum(b['sep_arcsec'] as num)} arcsec from the position' : ''}'),
    if (((b['others'] as List?) ?? const []).isNotEmpty) ('Others in the radius', (b['others'] as List).join(', ')),
    if (b['n_detections'] != null)
      (
        'Detections',
        '${b['n_detections']}'
            '${b['first_detection'] != null ? ', first ${day('first_detection')} UTC' : ''}'
            '${b['last_detection'] != null ? ', last ${day('last_detection')} UTC' : ''}'
      ),
    if (b['peak'] != null) ('Brightest', b['peak'] as String),
    if (b['classification'] != null)
      ('Classification', '${b['classification']}${b['classification_text'] != null ? ' (${b['classification_text']})' : ''}'),
    if (tns != null) ('TNS', '${tns['name']}${tns['type'] != null ? ', ${tns['type']}' : ''}${tns['z'] != null ? ', z = ${tns['z']}' : ''}'),
    if (host != null)
      (
        'Proposed host',
        [
          '${host['name']}${host['catalogue'] != null ? ' (${host['catalogue']})' : ''}',
          if (host['z'] != null) 'z = ${fmtNum(host['z'] as num, sig: 4)}',
          if (host['z'] == null && host['photo_z'] != null)
            'photometric z = ${fmtNum(host['photo_z'] as num)}${host['photo_z_err'] != null ? ' ± ${fmtNum(host['photo_z_err'] as num)}' : ''}',
          if (host['sep_arcsec'] != null) '${fmtNum(host['sep_arcsec'] as num)} arcsec away',
          if (host['sep_kpc'] != null) '${fmtNum(host['sep_kpc'] as num)} kpc',
          if (host['distance_mpc'] != null) '${fmtNum(host['distance_mpc'] as num)} Mpc',
        ].join(', ')
      ),
  ];
}

class _BrokerCard extends StatelessWidget {
  const _BrokerCard(this.b);
  final Map<String, dynamic> b;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final pal = Palette.of(context);
    final status = switch (b['status']) {
      'match' => 'object found',
      'none' => 'no object at this position',
      'not_configured' => 'not configured',
      _ => 'no answer',
    };
    final url = b['url'] as String?;
    return Card(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(b['label'] as String? ?? b['broker'] as String, style: Theme.of(context).textTheme.titleSmall)),
                Text(status, style: small?.copyWith(fontWeight: FontWeight.w600, color: b['status'] == 'match' ? pal.ink : pal.ink2)),
              ]),
              if (b['stale_since'] != null)
                Text('No answer at the last request: this is its answer of ${fmtTime(DateTime.tryParse(b['stale_since'] as String), seconds: false)} UTC.',
                    style: small?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              for (final (k, v) in brokerFacts(b))
                Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(width: 130, child: Text(k, style: small?.copyWith(color: pal.ink2))),
                      Expanded(child: Text(v)),
                    ])),
              if ((b['description'] as String? ?? '').isNotEmpty) Text(b['description'] as String, style: small),
              if ((b['note'] as String? ?? '').isNotEmpty) Text(b['note'] as String, style: small?.copyWith(color: pal.ink2)),
              if (url != null)
                Row(children: [
                  Expanded(child: SelectableText(url, style: small)),
                  IconButton(tooltip: 'Copy the address', icon: const Icon(Icons.copy, size: 18), onPressed: () => _copy(context, url)),
                ]),
            ])));
  }
}
