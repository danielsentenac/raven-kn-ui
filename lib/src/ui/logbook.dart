/// The logbook: every journal entry, filtered and searched, from the local archive.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../archive.dart';
import 'candidates.dart';
import 'common.dart';

class LogbookScreen extends StatefulWidget {
  const LogbookScreen({super.key});
  @override
  State<LogbookScreen> createState() => _LogbookScreenState();
}

class _LogbookScreenState extends State<LogbookScreen> {
  LogQuery q = const LogQuery();
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _pickDates() async {
    final now = DateTime.now().toUtc();
    final r = await showDateRangePicker(
        context: context,
        firstDate: DateTime.utc(2015),
        lastDate: now.add(const Duration(days: 1)),
        initialDateRange: q.from != null && q.to != null
            ? DateTimeRange(start: q.from!, end: q.to!.subtract(const Duration(days: 1)))
            : null);
    if (r != null) {
      setState(() => q = q.copyWith(
          from: DateTime.utc(r.start.year, r.start.month, r.start.day),
          to: DateTime.utc(r.end.year, r.end.month, r.end.day).add(const Duration(days: 1))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final news = state.batch > 0 ? state.archive.kindsOfBatch(state.batch) : const <String, int>{};
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: TextField(
          controller: _search,
          decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search: optical transient, superevent, text',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Clear the search',
                      onPressed: () => setState(() {
                            _search.clear();
                            q = q.copyWith(text: '');
                          }))),
          onChanged: (v) => setState(() => q = q.copyWith(text: v)),
        ),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          FilterChip(
              label: const Text('Problems only'),
              selected: q.problemsOnly,
              onSelected: (v) => setState(() => q = q.copyWith(problemsOnly: v))),
          const SizedBox(width: 6),
          for (final g in kindGroups.keys) ...[
            FilterChip(
                label: Text(g),
                selected: q.groups.contains(g),
                onSelected: (v) => setState(() => q = q.copyWith(groups: v ? {...q.groups, g} : q.groups.difference({g})))),
            const SizedBox(width: 6),
          ],
          ActionChip(
              avatar: const Icon(Icons.date_range, size: 18),
              label: Text(q.from == null ? 'All dates' : '${fmtDay(q.from!)} to ${fmtDay(q.to!.subtract(const Duration(days: 1)))}'),
              onPressed: _pickDates),
          if (q.from != null)
            IconButton(
                icon: const Icon(Icons.clear, size: 18),
                tooltip: 'All dates',
                onPressed: () => setState(() => q = q.copyWith(clearDates: true))),
        ]),
      ),
      if (news.isNotEmpty && q.text.isEmpty && q.groups.isEmpty && !q.problemsOnly && q.from == null)
        _NewsCard(news: news, problems: state.archive.countBatch(state.batch, problems: true), when: state.lastSync),
      Expanded(child: LogList(query: q, key: ValueKey('${q.text}|${q.groups}|${q.problemsOnly}|${q.from}|${q.to}|${state.batch}'))),
    ]);
  }
}

class _NewsCard extends StatelessWidget {
  const _NewsCard({required this.news, required this.problems, required this.when});
  final Map<String, int> news;
  final int problems;
  final DateTime? when;

  @override
  Widget build(BuildContext context) {
    final total = news.values.fold(0, (a, b) => a + b);
    String n(String kind, String one, String many) {
      final c = news[kind] ?? 0;
      return c == 0 ? '' : '$c ${c == 1 ? one : many}';
    }

    final parts = [
      n('optical_new', 'new optical transient', 'new optical transients'),
      n('decision', 'decision', 'decisions'),
      n('coincidence', 'coincidence', 'coincidences'),
      n('gw_alert', 'GW alert', 'GW alerts'),
      n('search_result', 'search result', 'search results'),
      n('pe_result', 'PE result', 'PE results'),
      if (problems > 0) '$problems warning${problems == 1 ? '' : 's'} or error${problems == 1 ? '' : 's'}',
    ].where((s) => s.isNotEmpty).join(', ');
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.fiber_new),
        title: Text('$total entr${total == 1 ? 'y' : 'ies'} arrived with the last sync'
            '${when != null ? ' (${fmtTime(when, seconds: false)} UTC)' : ''}'),
        subtitle: parts.isEmpty ? null : Text(parts),
      ),
    );
  }
}

/// Entries matching [query], newest first, loaded page by page.
class LogList extends StatefulWidget {
  const LogList({super.key, required this.query, this.shrink = false, this.oldestFirst = false});
  final LogQuery query;
  final bool shrink;
  final bool oldestFirst;
  @override
  State<LogList> createState() => _LogListState();
}

class _LogListState extends State<LogList> {
  static const _page = 200;
  int _shown = _page;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final total = state.archive.count(widget.query);
    final entries = state.archive.events(widget.query, limit: _shown, oldestFirst: widget.oldestFirst);
    if (entries.isEmpty) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(state.lastSync == null
                  ? 'Nothing synced yet. Set the server and the portal login in Settings, then press Sync.'
                  : 'No entry matches these filters.')));
    }
    final rows = <Widget>[];
    String? day;
    for (final e in entries) {
      final d = e.time == null ? 'time unknown' : fmtDay(e.time!);
      if (d != day) {
        day = d;
        rows.add(Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Text(d, style: Theme.of(context).textTheme.labelLarge)));
      }
      rows.add(EntryTile(e, isNew: e.batch == state.batch && state.batch > 1));
    }
    if (total > entries.length) {
      rows.add(Padding(
          padding: const EdgeInsets.all(12),
          child: OutlinedButton(
              onPressed: () => setState(() => _shown += _page),
              child: Text('Show more (${total - entries.length} older entries)'))));
    } else {
      rows.add(Padding(
          padding: const EdgeInsets.all(12),
          child: Center(child: Text('$total entr${total == 1 ? 'y' : 'ies'}', style: Theme.of(context).textTheme.bodySmall))));
    }
    return widget.shrink
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows)
        : ListView(children: rows);
  }
}

class EntryTile extends StatelessWidget {
  const EntryTile(this.e, {super.key, this.isNew = false});
  final LogEntry e;
  final bool isNew;

  @override
  Widget build(BuildContext context) {
    final pal = Palette.of(context);
    final lc = levelColor(e.level);
    final t = e.time?.toUtc();
    return InkWell(
      onTap: () => showEntry(context, e),
      child: Container(
        decoration: BoxDecoration(border: Border(left: BorderSide(color: lc ?? Colors.transparent, width: 4))),
        padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 44,
              child: Text(t == null ? '' : '${two(t.hour)}:${two(t.minute)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: pal.ink2))),
          Icon(kindIcon(e.kind), size: 18, color: lc ?? pal.ink2),
          const SizedBox(width: 8),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.summary, maxLines: 3, overflow: TextOverflow.ellipsis),
            if (e.level != 'info' || isNew || e.isSystem)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                    [
                      if (e.level == 'error') 'Error',
                      if (e.level == 'warning') 'Warning',
                      if (e.isSystem) 'pipeline',
                      if (isNew) 'new',
                    ].join(' · '),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: pal.ink2)),
              ),
          ])),
        ]),
      ),
    );
  }
}

void showEntry(BuildContext context, LogEntry e) {
  final state = AppScope.of(context);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
        Text(e.summary, style: Theme.of(ctx).textTheme.titleMedium),
        const SizedBox(height: 8),
        _kv(ctx, 'Time', '${fmtTime(e.time)} UTC'),
        _kv(ctx, 'Kind', e.kind),
        _kv(ctx, 'Level', e.level),
        _kv(ctx, 'Written by', e.source),
        if (e.optical != null) _kv(ctx, 'Optical transient', e.optical!),
        if (e.superevent != null) _kv(ctx, 'Superevent', e.superevent!),
        if (e.run != null) _kv(ctx, 'Run', e.run!),
        if (e.optical != null && state.archive.doc('optical/${e.optical}') != null)
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text('Open ${e.optical}'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(context,
                        MaterialPageRoute<void>(builder: (_) => AppScope(state: state, child: CandidateScreen(e.optical!))));
                  })),
        const Divider(),
        Text('Values at that time', style: Theme.of(ctx).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (e.data.isEmpty) const Text('None recorded') else JsonView(e.data),
      ]),
    ),
  );
}

Widget _kv(BuildContext c, String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 130, child: Text(k, style: Theme.of(c).textTheme.bodySmall?.copyWith(color: Palette.of(c).ink2))),
      Expanded(child: SelectableText(v)),
    ]));

/// A JSON value as an indented key / value list.
class JsonView extends StatelessWidget {
  const JsonView(this.value, {super.key, this.depth = 0});
  final Object? value;
  final int depth;

  static String scalar(Object? v) {
    if (v == null) return 'none';
    if (v is double) return fmtNum(v, sig: v.abs() >= 1e8 ? 13 : 6);
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    final v = value;
    final small = Theme.of(context).textTheme.bodySmall;
    if (v is Map) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final k in v.keys)
          if (v[k] is Map || (v[k] is List && (v[k] as List).any((x) => x is Map || x is List)))
            Padding(
                padding: EdgeInsets.only(left: 12.0 * depth, top: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('$k', style: small?.copyWith(fontWeight: FontWeight.w600)),
                  JsonView(v[k], depth: 1),
                ]))
          else
            Padding(
                padding: EdgeInsets.only(left: 12.0 * depth, top: 2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 150, child: Text('$k', style: small?.copyWith(color: Palette.of(context).ink2))),
                  Expanded(child: SelectableText(v[k] is List ? _list(v[k] as List) : scalar(v[k]), style: small)),
                ])),
      ]);
    }
    if (v is List) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final x in v.take(20)) Padding(padding: const EdgeInsets.only(top: 2), child: JsonView(x, depth: depth)),
        if (v.length > 20) Text('... ${v.length - 20} more', style: small),
      ]);
    }
    return SelectableText(scalar(v), style: small);
  }

  static String _list(List l) {
    if (l.length > 12) return '${l.take(12).map(scalar).join(', ')}, ... (${l.length} values)';
    return l.isEmpty ? 'none' : l.map(scalar).join(', ');
  }
}

/// Entries of [q] as JSON (the raw journal lines) or CSV.
String exportEntries(Archive archive, LogQuery q, {required bool csv}) {
  final all = archive.events(q, limit: 1 << 30, oldestFirst: true);
  if (!csv) return const JsonEncoder.withIndent(' ').convert([for (final e in all) e.json]);
  String cell(String? s) => '"${(s ?? '').replaceAll('"', '""')}"';
  final b = StringBuffer('time,level,kind,source,optical,superevent,run,summary\n');
  for (final e in all) {
    b.writeln([e.time?.toUtc().toIso8601String(), e.level, e.kind, e.source, e.optical, e.superevent, e.run, e.summary]
        .map(cell)
        .join(','));
  }
  return b.toString();
}
