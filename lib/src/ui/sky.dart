/// Sky view: the GW localisation (any stored version) with the GRB, neutrino
/// and optical-transient positions over it, all-sky or zoomed on one object.
library;

import 'dart:async';
import 'dart:io' show gzip;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../followup.dart';
import '../healpix.dart';
import 'common.dart';

const _skyOrder = 7; // reduced maps: nside 128
const _scale = 250; // byte = ceil(credible level x 250)

/// Credible-level byte of each raster pixel (255 outside the map or the sky).
Uint8List rasterLevels(Uint8List map, SkyProjection proj, int w, int h) {
  final out = Uint8List(w * h)..fillRange(0, w * h, 255);
  if (map.length != 12 * (1 << (2 * _skyOrder))) return out;
  for (var j = 0; j < h; j++) {
    final y = 1 - 2 * (j + 0.5) / h;
    for (var i = 0; i < w; i++) {
      final p = proj.inverse(2 * (i + 0.5) / w - 1, y);
      if (p == null) continue;
      out[j * w + i] = map[ang2pixNest(_skyOrder, p.$1, p.$2)];
    }
  }
  return out;
}

/// RGBA raster: sequential blue inside the 99 % region, contour lines at 50 % and 90 %.
Uint8List rasterRgba(Uint8List lv, int w, int h, Palette pal) {
  final px = Uint8List(w * h * 4);
  const t50 = _scale ~/ 2, t90 = _scale * 9 ~/ 10;
  final ink = pal.ink;
  void put(int k, Color c, double a) {
    px[4 * k] = (c.r * 255 * a).round();
    px[4 * k + 1] = (c.g * 255 * a).round();
    px[4 * k + 2] = (c.b * 255 * a).round();
    px[4 * k + 3] = (255 * a).round();
  }

  for (var j = 0; j < h; j++) {
    for (var i = 0; i < w; i++) {
      final k = j * w + i;
      final b = lv[k];
      var edge = false;
      for (final t in const [t50, t90]) {
        final inside = b <= t;
        if (i + 1 < w && (lv[k + 1] <= t) != inside) edge = true;
        if (j + 1 < h && (lv[k + w] <= t) != inside) edge = true;
      }
      if (edge) {
        put(k, ink, 1);
      } else if (b <= _scale * 99 ~/ 100) {
        put(k, pal.sequential(b / _scale), 0.92);
      }
    }
  }
  return px;
}

Future<ui.Image> _toImage(Uint8List rgba, int w, int h) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

class SkyObject {
  SkyObject(this.kind, this.label, this.ra, this.dec, this.errDeg, this.info, this.event);
  final String kind; // optical | grb | xray | nu | radio

  /// The alert it belongs to (see [FollowUps]).
  final String event;
  final String label;
  final double ra, dec;
  final double? errDeg;
  final String info;
}

class SkyView extends StatefulWidget {
  const SkyView({super.key, this.focus, this.startId});

  /// Optical transient to centre the zoomed view on (its follow-up is shown, without the selector).
  final String? focus;

  /// Alert whose follow-up is shown, without the selector (`gw:<id>`, `grb:<id>`...).
  final String? startId;
  @override
  State<SkyView> createState() => _SkyViewState();
}

class _SkyViewState extends State<SkyView> {
  /// The follow-up shown (first selector), and the alert chosen in it (second selector).
  String? group;
  String? alert;

  /// Single alerts instead of candidates: the alerts that belong to no candidate, listed
  /// newest first for a detection type ([type], or `all`) and a range of dates ([dates],
  /// UTC days). Each alert chosen in that list is added to the map ([shown]), over those
  /// already there, whatever their type; they leave it one by one or all at once.
  bool singles = false;
  String type = 'all';
  DateTimeRange? dates;
  final Set<String> shown = {};
  String? last; // the alert added last: the one the list displays
  bool _seeded = false;
  String? sid;
  int? version;
  String kind = 'gw';
  bool zoom = false;
  double radius = 15;
  String? target;
  bool showGw = true, showGrb = true, showXray = true, showNu = true, showCand = true, showRadio = true;
  SkyObject? picked;
  ui.Image? _image;
  String _imageKey = '';
  bool _init = false;

  List<SkyObject> _objects(Map<String, dynamic> sky) {
    final out = <SkyObject>[];
    for (final c in ((sky['optical'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      if (c['ra'] == null) continue;
      out.add(SkyObject('optical', c['name'] as String, (c['ra'] as num).toDouble(), (c['dec'] as num).toDouble(),
          null, 'Optical transient ${c['name']}: RA ${fmtNum(c['ra'] as num, sig: 7)}, Dec ${fmtNum(c['dec'] as num, sig: 7)}', 'optical:${c['name']}'));
    }
    for (final g in ((sky['grb'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final name = '${g['instrument']} ${g['trigger'] ?? ''}'.trim();
      if (g['burst_missing'] != true) {
        out.add(SkyObject(highEnergyKind(g), name, (g['ra'] as num).toDouble(), (g['dec'] as num).toDouble(), asDouble(g['err_deg']),
            '$name${g['time'] != null ? ', ${fmtTime(DateTime.tryParse(g['time'] as String))} UTC' : ''}: '
            'RA ${fmtNum(g['ra'] as num, sig: 6)}, Dec ${fmtNum(g['dec'] as num, sig: 6)}, radius ${fmtNum(g['err_deg'] as num?)} deg', 'grb:${g['id']}'));
      }
      final x = (g['xray'] as Map?)?.cast<String, dynamic>();
      if (x != null) {
        out.add(SkyObject('xray', '${x['instrument']}', (x['ra'] as num).toDouble(), (x['dec'] as num).toDouble(),
            asDouble(x['err_deg']),
            '${x['instrument']} position${g['burst_missing'] == true ? ' (its burst is not in the store)' : ' of $name'}: RA ${fmtNum(x['ra'] as num, sig: 8)}, Dec ${fmtNum(x['dec'] as num, sig: 8)}, '
            'radius ${fmtNum(((x['err_deg'] as num?) ?? 0) * 3600)} arcsec', 'grb:${g['id']}'));
      }
    }
    for (final n in ((sky['nu'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final name = (n['event'] ?? n['id']).toString();
      out.add(SkyObject('nu', name, (n['ra'] as num).toDouble(), (n['dec'] as num).toDouble(), asDouble(n['err_deg']),
          'Neutrino $name${n['time'] != null ? ', ${fmtTime(DateTime.tryParse(n['time'] as String))} UTC' : ''}: '
          'RA ${fmtNum(n['ra'] as num, sig: 6)}, Dec ${fmtNum(n['dec'] as num, sig: 6)}, 90 % radius ${fmtNum(n['err_deg'] as num?)} deg', 'nu:${n['id']}'));
    }
    for (final r in ((sky['radio'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      if (r['ra'] == null || r['dec'] == null) continue;
      final name = '${r['instrument'] ?? ''} ${r['trigger'] ?? r['id']}'.trim();
      out.add(SkyObject('radio', name, (r['ra'] as num).toDouble(), (r['dec'] as num).toDouble(), asDouble(r['err_deg']),
          'Radio $name${r['time'] != null ? ', ${fmtTime(DateTime.tryParse(r['time'] as String))} UTC' : ''}: '
          'RA ${fmtNum(r['ra'] as num, sig: 6)}, Dec ${fmtNum(r['dec'] as num, sig: 6)}, radius ${fmtNum(r['err_deg'] as num?)} deg', 'radio:${r['id']}'));
    }
    return out;
  }

  static String _day(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final pal = Palette.of(context);
    final sky = state.archive.doc('sky');
    if (sky == null) return const Center(child: Text('No sky data synced yet.'));
    final follow = FollowUps(sky);
    final groups = follow.groups(state.followups);
    if (groups.isEmpty) return const Center(child: Text('No alert synced yet.'));
    if (!_init) {
      _init = true;
      final want = widget.focus != null ? 'optical:${widget.focus}' : widget.startId;
      if (want != null) {
        group = groups.where((g) => g.ids.contains(want)).firstOrNull?.id;
        if (widget.focus != null) {
          zoom = true;
          target = want;
        }
      }
    }
    final fixed = widget.focus != null || widget.startId != null;
    // candidates on one side; on the other, the alerts that belong to no candidate
    final candidates = groups.where((g) => g.candidate).toList();
    final single = [for (final g in groups.where((g) => !g.candidate)) ...g.ids];
    final bool alone = !fixed && (singles || candidates.isEmpty) && single.isNotEmpty;
    // the alerts in the chosen dates (UTC days; an alert without a time only when no date is set)...
    int dayOf(DateTime t) => DateTime.utc(t.toUtc().year, t.toUtc().month, t.toUtc().day).millisecondsSinceEpoch;
    bool inDates(String i) {
      if (dates == null) return true;
      final t = follow.events[i]!.time;
      if (t == null) return false;
      final d = dayOf(t);
      return d >= DateTime.utc(dates!.start.year, dates!.start.month, dates!.start.day).millisecondsSinceEpoch &&
          d <= DateTime.utc(dates!.end.year, dates!.end.month, dates!.end.day).millisecondsSinceEpoch;
    }

    final dated = single.where(inDates).toList()
      ..sort((x, y) => (follow.events[y]!.time ?? DateTime.utc(1970)).compareTo(follow.events[x]!.time ?? DateTime.utc(1970)));
    // ...and among them those of the chosen type, newest first
    final listed = type == 'all' ? dated : dated.where((i) => follow.events[i]!.kind == type).toList();
    if (alone) {
      shown.removeWhere((i) => !single.contains(i));
      if (!_seeded) {
        _seeded = true; // at first the newest alert; afterwards only what the user puts on the map
        if (listed.isNotEmpty) shown.add(last = listed.first);
      }
    }
    final chosen = alone ? shown : const <String>{};
    // default candidate: the first that has a GW alert, else the first follow-up
    final pool = fixed || candidates.isEmpty ? groups : candidates;
    final current = pool.where((g) => g.id == group).firstOrNull ??
        pool.where((g) => g.ids.any((i) => i.startsWith('gw:'))).firstOrNull ??
        pool.first;
    group = current.id;
    final related = alone ? chosen : current.ids.toSet();
    // only this follow-up: its superevents, and its objects
    final gw = ((sky['gw'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .where((g) => related.contains('gw:${g['superevent_id']}') && (g['versions'] as List).isNotEmpty)
        .toList();
    final objects = _objects(sky).where((o) => related.contains(o.event)).toList();
    if (!gw.any((g) => g['superevent_id'] == sid)) {
      final live = gw.where((g) => g['retracted'] != true).toList();
      sid = live.isNotEmpty ? live.last['superevent_id'] as String : (gw.isNotEmpty ? gw.last['superevent_id'] as String : null);
      version = null;
    }
    final se = gw.where((g) => g['superevent_id'] == sid).firstOrNull;
    final versions = ((se?['versions'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final ver = versions.where((v) => v['version'] == version).firstOrNull ?? (versions.isNotEmpty ? versions.last : null);
    final maps = ((ver?['maps'] as Map?) ?? const {}).cast<String, dynamic>();
    final k = maps.containsKey(kind) ? kind : (maps.keys.isNotEmpty ? maps.keys.first : null);
    final info = k == null ? null : (maps[k] as Map).cast<String, dynamic>();

    // zoom centre: the chosen object, else the optical transient of the follow-up, else its first object
    final tgt = objects.where((o) => '${o.kind}:${o.label}' == target || o.event == target).firstOrNull ??
        objects.where((o) => o.kind == 'optical').firstOrNull ??
        (objects.isNotEmpty ? objects.first : null);
    final SkyProjection proj = zoom && tgt != null ? ZoomView(tgt.ra, tgt.dec, radius) : Mollweide();

    // raster of the selected map version (cached; redrawn when a control changes)
    final blobKey = k == null || ver == null ? null : 'map/$sid/${ver['version']}/$k';
    final key = '$blobKey|$zoom|${tgt?.label}|$radius|${pal.dark}|$showGw';
    if (key != _imageKey) {
      _imageKey = key;
      _image = null;
      final blob = showGw && blobKey != null ? state.archive.blob(blobKey) : null;
      if (blob != null) {
        final w = zoom ? 420 : 720, h = zoom ? 420 : 360;
        try {
          final lv = rasterLevels(Uint8List.fromList(gzip.decode(blob)), proj, w, h);
          _toImage(rasterRgba(lv, w, h, pal), w, h).then((img) {
            if (mounted && _imageKey == key) setState(() => _image = img);
          });
        } catch (_) {}
      }
    }

    // which superevent the shaded map belongs to, and the optical transients it coincides with
    String? gwLabel, gwTitle;
    (double, double)? gwPos;
    final coincident = <String>[];
    if (showGw && info != null && ver != null && sid != null) {
      final type = (ver['alert_type'] as String? ?? '').toLowerCase();
      final gps = asDouble(ver['gpstime']);
      // GPS to UTC with the 18 leap seconds in force since 2017
      final t = gps == null ? null : DateTime.utc(1980, 1, 6).add(Duration(milliseconds: ((gps - 18) * 1000).round()));
      gwLabel = '$sid${se?['retracted'] == true ? ' (retracted)' : ''}';
      gwTitle = 'GW map: $sid, version ${ver['version']} ($type)'
          '${t != null ? ', merger ${fmtTime(t)} UTC' : ''}'
          '${se?['retracted'] == true ? ', retracted' : ''}';
      final ra = asDouble(info['max_ra']), dec = asDouble(info['max_dec']);
      if (ra != null && dec != null) gwPos = (ra, dec);
      for (final id in related) {
        if (id.startsWith('optical:') && follow.attached(id, 'gw:$sid')) coincident.add(id.substring(8));
      }
    }

    final visible = objects
        .where((o) => switch (o.kind) { 'optical' => showCand, 'nu' => showNu, 'xray' => showXray, 'radio' => showRadio, _ => showGrb })
        .toList();

    return ListView(padding: const EdgeInsets.all(12), children: [
      if (!fixed && candidates.isNotEmpty && single.isNotEmpty)
        Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text('Candidates (${candidates.length})')),
                  ButtonSegment(value: true, label: Text('Alerts without candidate (${single.length})')),
                ],
                selected: {alone},
                onSelectionChanged: (v) => setState(() {
                      singles = v.first;
                      alert = null;
                      target = null;
                      picked = null;
                    }))),
      if (alone) ...[
        // type and dates: what the list below holds
        Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const SizedBox(width: 68, child: Text('Type')),
          DropdownButton<String>(
              value: type,
              items: [
                DropdownMenuItem(value: 'all', child: Text('All types (${dated.length})')),
                for (final t in alertKinds)
                  DropdownMenuItem(
                      value: t,
                      child: Text('${alertKindLabel(t)} (${dated.where((i) => follow.events[i]!.kind == t).length})'))
              ],
              onChanged: (v) => setState(() {
                    type = v ?? 'all';
                    target = null;
                    picked = null;
                  })),
          OutlinedButton.icon(
              icon: const Icon(Icons.date_range, size: 18),
              label: Text(dates == null
                  ? 'All dates'
                  : (_day(dates!.start) == _day(dates!.end) ? _day(dates!.start) : '${_day(dates!.start)} to ${_day(dates!.end)}')),
              onPressed: () async {
                final times = [for (final i in single) follow.events[i]!.time].whereType<DateTime>().toList()..sort();
                final now = DateTime.now();
                final first = times.isEmpty ? DateTime(2015) : DateTime(times.first.toUtc().year, times.first.toUtc().month, times.first.toUtc().day);
                final lastAlert = times.isEmpty ? now : DateTime(times.last.toUtc().year, times.last.toUtc().month, times.last.toUtc().day);
                final r = await showDateRangePicker(
                    context: context,
                    firstDate: first,
                    lastDate: lastAlert.isAfter(now) ? lastAlert : now,
                    initialDateRange: dates,
                    helpText: 'Alerts of these days (UTC)');
                if (r != null && mounted) {
                  setState(() {
                    dates = r;
                    target = null;
                    picked = null;
                  });
                }
              }),
          if (dates != null)
            IconButton(
                tooltip: 'All dates',
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () => setState(() {
                      dates = null;
                      target = null;
                      picked = null;
                    })),
        ]),
        // the alerts of that type in those dates, newest first: each one chosen is added to the map
        Row(children: [
          const SizedBox(width: 78, child: Text('Alert')),
          Expanded(
              child: listed.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                          'No ${type == 'all' ? '' : '${alertKindLabel(type)} '}alert${dates == null ? '' : ' in these dates'}.',
                          style: Theme.of(context).textTheme.bodySmall))
                  : DropdownButton<String>(
                      key: const Key('alert-list'),
                      isExpanded: true,
                      value: shown.contains(last) && listed.contains(last) ? last : null,
                      hint: const Text('Add an alert to the map'),
                      items: [
                        DropdownMenuItem(value: '*', child: Text('All ${listed.length} alert${listed.length == 1 ? '' : 's'} of this list')),
                        for (final id in listed)
                          DropdownMenuItem(
                              value: id,
                              child: Row(children: [
                                // ticked: already on the map
                                Icon(Icons.check, size: 16, color: shown.contains(id) ? pal.ink2 : Colors.transparent),
                                const SizedBox(width: 6),
                                Expanded(
                                    child: Text(
                                        '${follow.events[id]!.time != null ? '${fmtTime(follow.events[id]!.time, seconds: false)} UTC' : 'time unknown'}'
                                        '  ·  ${type == 'all' ? follow.events[id]!.label : follow.events[id]!.name}',
                                        overflow: TextOverflow.ellipsis)),
                              ]))
                      ],
                      onChanged: (v) => setState(() {
                            picked = null;
                            if (v == null) return;
                            if (v == '*') {
                              shown.addAll(listed);
                              last = null;
                              return;
                            }
                            shown.add(last = v); // over those already on the map
                            if (v.startsWith('gw:')) {
                              sid = v.substring(3); // its map is the one shaded
                              version = null;
                            } else {
                              target = v; // and the zoomed view centres on it
                            }
                          }))),
        ]),
        // what is on the map, newest first: each can be taken off, or all at once
        Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 6),
            child: shown.isEmpty
                ? Text('The map is empty: choose an alert in the list to add it.', style: Theme.of(context).textTheme.bodySmall)
                : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 104),
                            child: SingleChildScrollView(
                                child: Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                              Text('On the map (${shown.length})', style: Theme.of(context).textTheme.bodySmall),
                              for (final id in shown.toList()
                                ..sort((x, y) =>
                                    (follow.events[y]!.time ?? DateTime.utc(1970)).compareTo(follow.events[x]!.time ?? DateTime.utc(1970))))
                                InputChip(
                                    label: Text(follow.events[id]!.label),
                                    visualDensity: VisualDensity.compact,
                                    deleteButtonTooltipMessage: 'Remove from the map',
                                    onPressed: () => setState(() {
                                          // the zoomed view centres on it; a GW alert's map becomes the one shaded
                                          if (id.startsWith('gw:')) {
                                            sid = id.substring(3);
                                            version = null;
                                          } else {
                                            target = id;
                                          }
                                        }),
                                    onDeleted: () => setState(() {
                                          shown.remove(id);
                                          picked = null;
                                        })),
                            ])))),
                    TextButton.icon(
                        icon: const Icon(Icons.layers_clear, size: 18),
                        label: const Text('Clear map'),
                        onPressed: () => setState(() {
                              shown.clear();
                              last = null;
                              target = null;
                              picked = null;
                            })),
                  ])),
      ],
      if (!fixed && !alone)
        Row(children: [
          const SizedBox(width: 78, child: Text('Candidate')),
          Expanded(
              child: DropdownButton<String>(
                  isExpanded: true,
                  value: current.id,
                  items: [
                    for (final g in pool)
                      DropdownMenuItem(value: g.id, child: Text(g.label, overflow: TextOverflow.ellipsis))
                  ],
                  onChanged: (v) => setState(() {
                        group = v;
                        alert = null;
                        target = null;
                        picked = null;
                      }))),
        ]),
      // the alerts of this follow-up only
      if (!alone)
        Row(children: [
        const SizedBox(width: 78, child: Text('Alert')),
        Expanded(
            child: DropdownButton<String?>(
                isExpanded: true,
                value: current.ids.contains(alert) ? alert : null,
                items: [
                  DropdownMenuItem(value: null, child: Text('All ${current.ids.length} alert${current.ids.length == 1 ? '' : 's'} of this follow-up')),
                  for (final id in current.ids)
                    DropdownMenuItem(
                        value: id,
                        child: Text(
                            '${follow.events[id]!.label}'
                            '${follow.events[id]!.time != null ? '  ·  ${fmtTime(follow.events[id]!.time, seconds: false)} UTC' : ''}',
                            overflow: TextOverflow.ellipsis))
                ],
                onChanged: (v) => setState(() {
                      alert = v;
                      if (v == null) {
                        picked = null;
                      } else if (v.startsWith('gw:')) {
                        sid = v.substring(3); // its map is the one shaded
                        version = null;
                        picked = null;
                      } else {
                        target = v; // centre of the zoomed view
                        picked = objects.where((o) => o.event == v).firstOrNull;
                      }
                    }))),
      ]),
      Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (alone && gw.length > 1)
          DropdownButton<String>(
              value: sid,
              items: [
                for (final g in gw)
                  DropdownMenuItem(value: g['superevent_id'] as String, child: Text('map of ${g['superevent_id']}'))
              ],
              onChanged: (v) => setState(() {
                    sid = v;
                    version = null;
                  })),
        if (versions.isNotEmpty)
          DropdownButton<int>(
              value: ver?['version'] as int?,
              items: [
                for (final v in versions)
                  DropdownMenuItem(value: v['version'] as int, child: Text('v${v['version']} ${(v['alert_type'] as String? ?? '').toLowerCase()}'))
              ],
              onChanged: (v) => setState(() => version = v)),
        if (maps.length > 1)
          SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'gw', label: Text('GW')), ButtonSegment(value: 'combined', label: Text('GW x GRB'))],
              selected: {k ?? 'gw'},
              onSelectionChanged: (s) => setState(() => kind = s.first)),
        SegmentedButton<bool>(
            segments: const [ButtonSegment(value: false, label: Text('All sky')), ButtonSegment(value: true, label: Text('Zoom'))],
            selected: {zoom},
            onSelectionChanged: (s) => setState(() => zoom = s.first)),
      ]),
      if (zoom)
        Row(children: [
          const Text('Radius'),
          Expanded(
              child: Slider(
                  min: -1.3,
                  max: 1.78,
                  value: (math.log(radius) / math.ln10).clamp(-1.3, 1.78),
                  onChanged: (v) => setState(() => radius = math.pow(10, v).toDouble()))),
          SizedBox(width: 70, child: Text(radius < 1 ? '${fmtNum(radius * 60, sig: 2)} arcmin' : '${fmtNum(radius, sig: 2)} deg')),
        ]),
      Wrap(spacing: 6, children: [
        FilterChip(label: const Text('GW map'), selected: showGw, onSelected: (v) => setState(() => showGw = v)),
        FilterChip(label: const Text('GRB'), selected: showGrb, onSelected: (v) => setState(() => showGrb = v)),
        FilterChip(label: const Text('X-ray'), selected: showXray, onSelected: (v) => setState(() => showXray = v)),
        FilterChip(label: const Text('Optical'), selected: showCand, onSelected: (v) => setState(() => showCand = v)),
        FilterChip(label: const Text('Neutrinos'), selected: showNu, onSelected: (v) => setState(() => showNu = v)),
        FilterChip(label: const Text('Radio'), selected: showRadio, onSelected: (v) => setState(() => showRadio = v)),
      ]),
      const SizedBox(height: 8),
      if (gwTitle != null)
        Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(gwTitle, style: Theme.of(context).textTheme.titleSmall),
              Text(
                  coincident.isEmpty
                      ? 'No optical transient has this superevent in its merger-time window.'
                      : 'In the merger-time window of: ${coincident.join(', ')}.',
                  style: Theme.of(context).textTheme.bodySmall),
              if (se?['external_coinc'] != null)
                Text(
                    'LVK reports a coincidence with a ${(se!['external_coinc'] as Map)['observatory'] ?? ''} GRB'
                    '${(se['external_coinc'] as Map)['raven_joint_far'] != null ? ' (joint FAR ${fmtNum((se['external_coinc'] as Map)['raven_joint_far'] as num?)} Hz)' : ''}: '
                    '${se['grb_id'] != null ? '${follow.events['grb:${se['grb_id']}']?.name ?? se['grb_id']}, matched by ${se['grb_match']}' : 'its notice is not in the store'}.',
                    style: Theme.of(context).textTheme.bodySmall),
            ])),
      LayoutBuilder(builder: (ctx, box) {
        final w = math.min(box.maxWidth, zoom ? 520.0 : 900.0);
        final h = w / proj.aspect;
        return Center(
          child: GestureDetector(
            onTapDown: (d) {
              SkyObject? best;
              var bd = 28.0;
              for (final o in visible) {
                final p = proj.forward(o.ra, o.dec);
                if (p == null) continue;
                final q = Offset((p.$1 + 1) / 2 * w, (1 - p.$2) / 2 * h);
                final dist = (q - d.localPosition).distance;
                if (dist < bd) {
                  bd = dist;
                  best = o;
                }
              }
              setState(() => picked = best);
            },
            child: CustomPaint(
                size: Size(w, h),
                painter: _SkyPainter(proj, _image, visible, pal, zoom ? radius : null, picked, widget.focus, Theme.of(context).textTheme.bodySmall?.fontFamily,
                    gwLabel: _image != null ? gwLabel : null, gwPos: gwPos, coincident: coincident)),
          ),
        );
      }),
      const SizedBox(height: 8),
      Wrap(spacing: 14, runSpacing: 4, children: [
        if (showGw && info != null) ...[
          _Key(painter: (c, o) => c.drawRect(Rect.fromCenter(center: o, width: 14, height: 10), Paint()..color = pal.sequential(0.2)), label: 'GW probability (darker: more probable)'),
          _Key(painter: (c, o) => c.drawLine(o - const Offset(7, 0), o + const Offset(7, 0), Paint()..color = pal.ink..strokeWidth = 1.5), label: '50 % and 90 % contours'),
        ],
        // only the kinds present in this follow-up
        for (final (kind, label) in const [('optical', 'optical transient'), ('grb', 'GRB'), ('xray', 'X-ray'), ('nu', 'neutrino (90 %)'), ('radio', 'radio')])
          if (visible.any((o) => o.kind == kind)) _Key(painter: (c, o) => _mark(c, o, kind, pal), label: label),
      ]),
      const SizedBox(height: 8),
      if (picked != null) Text(picked!.info) else Text('Tap an object for its values.', style: Theme.of(context).textTheme.bodySmall),
      if (info != null && ver != null)
        Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                '$sid, version ${ver['version']} (${(ver['alert_type'] as String? ?? '').toLowerCase()}'
                '${ver['time_created'] != null ? ', ${ver['time_created']}' : ''}): '
                '90 % area ${fmtNum(info['area90_deg2'] as num?)} deg², 50 % area ${fmtNum(info['area50_deg2'] as num?)} deg², '
                'FAR ${fmtNum(ver['far'] as num?)} Hz. Map shown at 0.46° per pixel.'
                '${se?['retracted'] == true ? ' This superevent was retracted.' : ''}',
                style: Theme.of(context).textTheme.bodySmall)),
      if (gw.isEmpty)
        Text(alone ? 'No GW alert is on the map: no localisation to show.' : 'This follow-up has no GW alert: no map to show.', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

Color _kindColor(String kind, Palette pal) =>
    switch (kind) { 'grb' || 'xray' => pal.series(1), 'nu' => pal.series(2), 'radio' => pal.series(3), _ => pal.ink };

void _mark(Canvas c, Offset o, String kind, Palette pal) {
  final col = _kindColor(kind, pal);
  final stroke = Paint()
    ..color = col
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;
  final halo = Paint()
    ..color = pal.surface
    ..style = PaintingStyle.stroke
    ..strokeWidth = 4.5;
  void both(void Function(Paint p) draw) {
    draw(halo);
    draw(stroke);
  }

  switch (kind) {
    case 'optical':
      final path = Path()
        ..moveTo(o.dx, o.dy - 6)
        ..lineTo(o.dx + 6, o.dy)
        ..lineTo(o.dx, o.dy + 6)
        ..lineTo(o.dx - 6, o.dy)
        ..close();
      both((p) => c.drawPath(path, p));
    case 'xray':
      both((p) {
        c.drawLine(o - const Offset(5, 5), o + const Offset(5, 5), p);
        c.drawLine(o - const Offset(5, -5), o + const Offset(5, -5), p);
      });
    case 'nu':
      both((p) => c.drawRect(Rect.fromCenter(center: o, width: 10, height: 10), p));
    case 'radio':
      final tri = Path()
        ..moveTo(o.dx, o.dy - 6)
        ..lineTo(o.dx + 6, o.dy + 5)
        ..lineTo(o.dx - 6, o.dy + 5)
        ..close();
      both((p) => c.drawPath(tri, p));
    default:
      both((p) => c.drawCircle(o, 5, p));
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.painter, required this.label});
  final void Function(Canvas, Offset) painter;
  final String label;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        CustomPaint(size: const Size(18, 16), painter: _KeyPainter(painter)),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Palette.of(context).ink2)),
      ]);
}

class _KeyPainter extends CustomPainter {
  _KeyPainter(this.draw);
  final void Function(Canvas, Offset) draw;
  @override
  void paint(Canvas canvas, Size size) => draw(canvas, size.center(Offset.zero));
  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class _SkyPainter extends CustomPainter {
  _SkyPainter(this.proj, this.image, this.objects, this.pal, this.radius, this.picked, this.focus, this.font,
      {this.gwLabel, this.gwPos, this.coincident = const []});
  final String? font;

  /// Name of the superevent whose map is shaded, written on the map at its most probable position.
  final String? gwLabel;
  final (double, double)? gwPos;

  /// Candidates in coincidence with that superevent (their labels say so).
  final List<String> coincident;
  final SkyProjection proj;
  final ui.Image? image;
  final List<SkyObject> objects;
  final Palette pal;
  final double? radius;
  final SkyObject? picked;
  final String? focus;

  @override
  void paint(Canvas canvas, Size size) {
    Offset? at(double ra, double dec) {
      final p = proj.forward(ra, dec);
      return p == null ? null : Offset((p.$1 + 1) / 2 * size.width, (1 - p.$2) / 2 * size.height);
    }

    final outline = Path()..addOval(Offset.zero & size);
    canvas.drawPath(outline, Paint()..color = pal.dark ? const Color(0xff222220) : const Color(0xfff4f3ef));
    canvas.save();
    canvas.clipPath(outline);
    if (image != null) {
      canvas.drawImageRect(image!, Rect.fromLTWH(0, 0, image!.width.toDouble(), image!.height.toDouble()), Offset.zero & size,
          Paint()..filterQuality = FilterQuality.medium);
    }
    final grid = Paint()
      ..color = pal.grid
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    void poly(List<Offset?> pts, Paint p) {
      final path = Path();
      Offset? prev;
      for (final o in pts) {
        if (o == null || (prev != null && (o - prev).distance > size.width * 0.25)) {
          prev = o;
          if (o != null) path.moveTo(o.dx, o.dy);
          continue;
        }
        prev == null ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
        prev = o;
      }
      canvas.drawPath(path, p);
    }

    if (radius == null) {
      for (var ra = 0; ra < 360; ra += 30) {
        poly([for (var d = -90.0; d <= 90; d += 3) at(ra.toDouble(), d)], grid);
      }
      for (var d = -60; d <= 60; d += 30) {
        poly([for (var ra = 0.5; ra < 360; ra += 3) at((ra + 180) % 360, d.toDouble())], grid);
      }
    } else {
      for (final f in const [0.5, 1.0]) {
        canvas.drawCircle(size.center(Offset.zero), f * size.width / 2 - (f == 1 ? 0.5 : 0), grid);
      }
    }
    // error regions
    for (final o in objects) {
      final e = o.errDeg;
      if (e == null || e <= 0) continue;
      final ring = [for (var a = 0.0; a <= 360; a += 5) () { final q = offsetBy(o.ra, o.dec, e, a); return at(q.$1, q.$2); }()];
      final col = _kindColor(o.kind, pal);
      poly(ring, Paint()..color = pal.surface..style = PaintingStyle.stroke..strokeWidth = 4);
      poly(ring, Paint()..color = col..style = PaintingStyle.stroke..strokeWidth = 2);
    }
    canvas.restore();
    canvas.drawPath(outline, Paint()..color = pal.muted..style = PaintingStyle.stroke);

    // markers and labels
    TextPainter tp(String s, {bool bold = false}) => TextPainter(
        text: TextSpan(text: s, style: TextStyle(color: pal.ink, fontSize: 11, fontWeight: bold ? FontWeight.w600 : null, fontFamily: font)),
        textDirection: TextDirection.ltr)
      ..layout();
    final used = <Rect>[];
    if (gwLabel != null) {
      final t = tp(gwLabel!, bold: true);
      final q = gwPos == null ? null : at(gwPos!.$1, gwPos!.$2);
      final onMap = q != null && (Offset.zero & size).deflate(4).contains(q);
      // near its most probable point; in a corner when that point is outside the view
      // beside the map, joined to it by a line, so that it hides neither the map nor the objects on it
      final above = onMap && q.dy > 60;
      final r = onMap
          ? Rect.fromLTWH((q.dx - t.width / 2).clamp(2, size.width - t.width - 2),
              above ? q.dy - 44 - t.height : q.dy + 44, t.width, t.height)
          : Rect.fromLTWH(size.width - t.width - 6, 4, t.width, t.height);
      used.add(r.inflate(2));
      if (onMap) {
        canvas.drawLine(Offset(r.center.dx, above ? r.bottom + 3 : r.top - 3), Offset(q.dx, above ? q.dy - 12 : q.dy + 12),
            Paint()..color = pal.sequential(0.2)..strokeWidth = 1.5);
      }
      canvas.drawRRect(RRect.fromRectAndRadius(r.inflate(3), const Radius.circular(3)), Paint()..color = pal.surface.withValues(alpha: 0.88));
      canvas.drawRRect(RRect.fromRectAndRadius(r.inflate(3), const Radius.circular(3)),
          Paint()..color = pal.sequential(0.2)..style = PaintingStyle.stroke..strokeWidth = 1.5);
      t.paint(canvas, r.topLeft);
    }
    for (final o in objects) {
      final q = at(o.ra, o.dec);
      if (q == null || !(Offset.zero & size).inflate(2).contains(q)) continue;
      _mark(canvas, q, o.kind, pal);
      final sel = identical(o, picked) || (picked != null && o.label == picked!.label && o.kind == picked!.kind);
      if (o.kind == 'optical' || sel || objects.length <= 8) {
        final co = o.kind == 'optical' && coincident.contains(o.label);
        final t = tp(co ? '${o.label} (in its window)' : o.label, bold: sel || o.label == focus || co);
        var r = Rect.fromLTWH((q.dx + 9).clamp(0, size.width - t.width), q.dy - t.height / 2, t.width, t.height);
        if (used.any((u) => u.overlaps(r))) r = r.shift(Offset(0, t.height + 2));
        if (used.any((u) => u.overlaps(r))) continue;
        used.add(r);
        canvas.drawRect(r.inflate(1.5), Paint()..color = pal.surface.withValues(alpha: 0.8));
        t.paint(canvas, r.topLeft);
      }
    }
    if (radius == null) {
      for (final ra in const [0, 90, 180, 270]) {
        final q = at(ra.toDouble() + (ra == 0 ? 0.01 : 0), 0);
        if (q != null) {
          final t = TextPainter(text: TextSpan(text: '$ra°', style: TextStyle(color: pal.muted, fontSize: 10, fontFamily: font)), textDirection: TextDirection.ltr)..layout();
          t.paint(canvas, Offset((q.dx + 3).clamp(0, size.width - t.width), q.dy + 2));
        }
      }
    } else {
      String lab(double r) => r < 1 ? '${fmtNum(r * 60, sig: 2)}′' : '${fmtNum(r, sig: 2)}°';
      final c = size.center(Offset.zero);
      for (final f in const [0.5, 1.0]) {
        final t = TextPainter(text: TextSpan(text: lab(radius! * f), style: TextStyle(color: pal.muted, fontSize: 10, fontFamily: font)), textDirection: TextDirection.ltr)..layout();
        t.paint(canvas, Offset(c.dx + 3, c.dy - f * size.height / 2 + 3));
      }
      final ne = TextPainter(text: TextSpan(text: 'N up, E left', style: TextStyle(color: pal.muted, fontSize: 10, fontFamily: font)), textDirection: TextDirection.ltr)..layout();
      ne.paint(canvas, Offset(2, size.height - ne.height - 2));
    }
  }

  @override
  bool shouldRepaint(covariant _SkyPainter old) => true;
}
