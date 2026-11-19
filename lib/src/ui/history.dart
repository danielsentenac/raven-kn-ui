/// History of a follow-up as a horizontal sequence: the detections in order of
/// time, each with its instrument, then the steps of the pipeline.
library;

import 'package:flutter/material.dart';

import '../followup.dart';
import 'common.dart';

String typeLabel(String type) => switch (type) { 'optical' => 'Optical', 'gw' => 'GW', 'grb' => 'GRB', 'xray' => 'X-ray', 'nu' => 'Neutrino', 'radio' => 'Radio', _ => type };

IconData typeIcon(String type) => switch (type) {
      'optical' => Icons.visibility,
      'gw' => Icons.waves,
      'grb' => Icons.flash_on,
      'nu' => Icons.grain,
      'xray' => Icons.close,
      'radio' => Icons.settings_input_antenna,
      _ => Icons.circle,
    };

/// Time after the first detection: `+1.7 s`, `+10.9 h`, `+2.1 d`.
String sinceFirst(DateTime? t, DateTime? first) {
  if (t == null || first == null) return '';
  final s = t.difference(first).inMilliseconds / 1000.0;
  if (s.abs() < 0.05) return 'first';
  final a = s.abs(), sign = s < 0 ? '-' : '+';
  if (a < 120) return '$sign${fmtNum(a, sig: 3)} s';
  if (a < 7200) return '$sign${fmtNum(a / 60, sig: 3)} min';
  if (a < 172800) return '$sign${fmtNum(a / 3600, sig: 3)} h';
  return '$sign${fmtNum(a / 86400, sig: 3)} d';
}

class HistoryDiagram extends StatelessWidget {
  const HistoryDiagram(this.followUp, {super.key});
  final Map<String, dynamic> followUp;

  @override
  Widget build(BuildContext context) {
    final pal = Palette.of(context);
    final members = ((followUp['members'] as List?) ?? const []).cast<Map<String, dynamic>>();
    // the first step ("received") is the optical detection itself, already in the sequence
    final steps = ((followUp['steps'] as List?) ?? const []).cast<Map<String, dynamic>>().skip(1).toList();
    DateTime? time(Map<String, dynamic> m) => m['time'] is String ? DateTime.tryParse(m['time'] as String) : null;
    final first = members.map(time).whereType<DateTime>().fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
    final small = Theme.of(context).textTheme.bodySmall;
    final label = Theme.of(context).textTheme.labelSmall?.copyWith(color: pal.ink2);

    Widget box({required Widget head, required String title, required List<String> lines, Color? border}) => Container(
        width: 152,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
            color: pal.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: border ?? pal.grid, width: 1.5)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          head,
          const SizedBox(height: 3),
          Text(title, style: small?.copyWith(fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
          for (final l in lines.where((l) => l.isNotEmpty)) Text(l, style: label, maxLines: 3, overflow: TextOverflow.ellipsis),
        ]));
    Widget arrow() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2), child: Icon(Icons.arrow_right_alt, size: 20, color: pal.muted));

    final cells = <Widget>[];
    for (final m in members) {
      final t = time(m);
      if (cells.isNotEmpty) cells.add(arrow());
      cells.add(box(
          head: Row(children: [
            Icon(typeIcon(m['type'] as String), size: 16, color: pal.ink2),
            const SizedBox(width: 4),
            Expanded(child: Text('${typeLabel(m['type'] as String)} detection', style: label)),
          ]),
          title: '${m['name']}${m['retracted'] == true ? ' (retracted)' : ''}',
          lines: [
            (m['instrument'] as String?) ?? 'instrument not recorded',
            t == null ? 'time unknown' : '${fmtTime(t)} UTC',
            sinceFirst(t, first),
            if (m['circulars'] is Map) circularShort((m['circulars'] as Map).cast<String, dynamic>()),
          ],
          border: pal.series(0)));
    }
    for (final s in steps) {
      final st = StatusStyle.of(s['status'] as String, context);
      cells.add(arrow());
      cells.add(box(
          head: Row(children: [
            Icon(st.icon, size: 16, color: st.color),
            const SizedBox(width: 4),
            Expanded(child: Text('Pipeline · ${st.label}', style: label)),
          ]),
          title: s['label'] as String,
          lines: [(s['detail'] as String?) ?? '']));
    }
    if (steps.isEmpty) {
      cells.add(arrow());
      cells.add(box(
          head: Row(children: [
            Icon(Icons.radio_button_unchecked, size: 16, color: pal.muted),
            const SizedBox(width: 4),
            Expanded(child: Text('Pipeline', style: label)),
          ]),
          title: 'No decision or search',
          lines: const ['They need an optical transient in the follow-up']));
    }
    return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final c in cells) c is Padding ? Center(child: c) : c,
        ])));
  }
}
