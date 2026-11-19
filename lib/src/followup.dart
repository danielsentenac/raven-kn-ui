/// Follow-ups: which alerts belong together.
///
/// The pipeline attaches a GRB and a neutrino to an optical transient, and finds the
/// superevents in the transient's merger-time window. An LVK alert may also
/// carry its own coincidence with a GRB. A follow-up is every
/// alert linked that way, starting from any of them. Alerts with no link form
/// a follow-up of their own.
library;

/// The detection types of an alert, in the order of the selectors.
const alertKinds = ['gw', 'grb', 'xray', 'optical', 'nu', 'radio'];

String alertKindLabel(String kind) => switch (kind) {
      'optical' => 'Optical',
      'grb' => 'GRB',
      'xray' => 'X-ray',
      'nu' => 'Neutrino',
      'radio' => 'Radio',
      _ => 'GW',
    };

/// Detection type of an entry of the server's `grb` list, which holds every
/// high-energy notice: `xray` for an X-ray instrument (Einstein Probe WXT and
/// FXT, Swift-XRT, SVOM-MXT) or an X-ray position whose burst is not in the
/// store, else `grb`.
String highEnergyKind(Map<String, dynamic> g) =>
    g['burst_missing'] == true || RegExp(r'(WXT|FXT|XRT|MXT)', caseSensitive: false).hasMatch('${g['instrument'] ?? ''}')
        ? 'xray'
        : 'grb';

/// What the GCN Circulars say about each alert of the server's sky answer: alert id ->
/// digest (`n`, `bands`, `name`, `optical`, `n_optical`, `first_optical`, `redshift`).
/// An alert without circular, or a server that does not read them, has no entry.
Map<String, Map<String, dynamic>> circularDigests(Map<String, dynamic> sky) {
  final out = <String, Map<String, dynamic>>{};
  for (final (kind, key) in const [('optical', 'name'), ('grb', 'id'), ('nu', 'id'), ('gw', 'superevent_id'), ('radio', 'id')]) {
    for (final a in ((sky[kind] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      if (a['circulars'] is Map) out['$kind:${a[key]}'] = (a['circulars'] as Map).cast<String, dynamic>();
    }
  }
  return out;
}

/// The alerts a circular of the server's list is linked to, by their id here.
Set<String> circularAlerts(Map<String, dynamic> circular) =>
    {for (final l in ((circular['links'] as List?) ?? const []).cast<Map<String, dynamic>>()) '${l['type']}:${l['id']}'};

/// Whether an optical search was reported, in a few words: `optical detection`,
/// `optical upper limits`, `optical observation`, `no optical report`.
String circularOptical(Map<String, dynamic> digest) => switch (digest['optical']) {
      'detection' => 'optical detection',
      'upper_limit' => 'optical upper limits',
      'observation' => 'optical observation',
      _ => 'no optical report',
    };

/// One line: `5 circulars, optical detection, z = 0.42`.
String circularShort(Map<String, dynamic> digest) {
  final n = (digest['n'] as num?)?.toInt() ?? 0;
  final z = digest['redshift'] as num?;
  return '$n circular${n == 1 ? '' : 's'}, ${circularOptical(digest)}${z != null ? ', z = ${_trim(z)}' : ''}';
}

String _trim(num v) => v.toString().replaceFirst(RegExp(r'\.0$'), '');

/// The digest in full: the circulars by band, then the optical search.
List<String> circularLines(Map<String, dynamic> digest) {
  const names = {'optical': 'optical', 'xray': 'X-ray', 'radio': 'radio', 'gamma': 'gamma', 'gw': 'GW', 'nu': 'neutrino'};
  final n = (digest['n'] as num?)?.toInt() ?? 0;
  final bands = ((digest['bands'] as Map?) ?? const {}).cast<String, dynamic>();
  final nOpt = (digest['n_optical'] as num?)?.toInt() ?? 0;
  final first = digest['first_optical'] is String ? DateTime.tryParse(digest['first_optical'] as String)?.toUtc() : null;
  String two(int v) => v.toString().padLeft(2, '0');
  final z = digest['redshift'] as num?;
  return [
    '$n circular${n == 1 ? '' : 's'}'
        '${bands.isEmpty ? '' : ': ${[for (final b in names.keys) if (bands[b] != null) '${names[b]} ${bands[b]}'].join(', ')}'}',
    nOpt == 0
        ? 'No optical search reported.'
        : 'Optical search reported: ${circularOptical(digest).substring(8)} ($nOpt report${nOpt == 1 ? '' : 's'}'
            '${first != null ? ', first ${first.year}-${two(first.month)}-${two(first.day)} ${two(first.hour)}:${two(first.minute)} UTC' : ''})'
            '${z != null ? '; redshift ${_trim(z)}${digest['redshift_circular'] != null ? ' (GCN ${digest['redshift_circular']})' : ''}' : ''}.',
  ];
}

/// One alert of the store, named by its detection type. Ids: `optical:<name>` (an optical
/// transient, the pipeline's `OpticalTransient`), `grb:<id>` (a GRB or an X-ray notice: the
/// id is the server's, the type is in [kind]), `nu:<id>`, `gw:<superevent>`, `radio:<id>`.
class SkyEvent {
  SkyEvent(this.id, this.kind, this.name, this.time);
  final String id;
  final String kind; // one of [alertKinds]
  final String name;
  final DateTime? time;

  String get kindLabel => alertKindLabel(kind);
  String get label => '$kindLabel $name';
}

/// Id of a follow-up member given by the server: the same as here.
String skyIdOf(String key) => key;

/// A follow-up as listed in the selectors: its alerts, and whether it is a candidate.
class FollowUpGroup {
  FollowUpGroup(this.id, this.label, this.candidate, this.ids);
  final String id, label;
  final bool candidate;
  final List<String> ids; // in order of time
}

class FollowUps {
  FollowUps(Map<String, dynamic> sky) {
    void add(SkyEvent e) => events[e.id] = e;
    void link(String a, String b) {
      if (!events.containsKey(a) || !events.containsKey(b)) return;
      _links.putIfAbsent(a, () => {}).add(b);
      _links.putIfAbsent(b, () => {}).add(a);
    }

    DateTime? t(Object? s) => s is String ? DateTime.tryParse(s) : null;
    for (final g in ((sky['grb'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      add(SkyEvent('grb:${g['id']}', highEnergyKind(g), '${g['instrument'] ?? ''} ${g['trigger'] ?? ''}'.trim(), t(g['time'])));
    }
    // radio notices, when the server lists some (same fields as the GRB notices)
    for (final r in ((sky['radio'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      add(SkyEvent('radio:${r['id']}', 'radio', '${r['instrument'] ?? ''} ${r['trigger'] ?? r['id']}'.trim(), t(r['time'])));
    }
    for (final n in ((sky['nu'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      add(SkyEvent('nu:${n['id']}', 'nu', (n['event'] ?? n['id']).toString(), t(n['time'])));
    }
    for (final g in ((sky['gw'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final versions = ((g['versions'] as List?) ?? const []).cast<Map<String, dynamic>>();
      add(SkyEvent('gw:${g['superevent_id']}', 'gw',
          '${g['superevent_id']}${g['retracted'] == true ? ' (retracted)' : ''}',
          versions.isEmpty ? null : t(versions.last['time_created'])));
    }
    final cands = ((sky['optical'] as List?) ?? const []).cast<Map<String, dynamic>>();
    for (final c in cands) {
      add(SkyEvent('optical:${c['name']}', 'optical', c['name'] as String, t(c['time'])));
    }
    for (final c in cands) {
      final id = 'optical:${c['name']}';
      if (c['grb_id'] != null) link(id, 'grb:${c['grb_id']}');
      if (c['nu_id'] != null) link(id, 'nu:${c['nu_id']}');
      for (final s in (c['superevents'] as List?) ?? const []) {
        link(id, 'gw:$s');
      }
    }
    // the GW x GRB coincidence carried by the LVK alert itself
    for (final g in ((sky['gw'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      if (g['grb_id'] != null) link('gw:${g['superevent_id']}', 'grb:${g['grb_id']}');
    }
  }

  final Map<String, SkyEvent> events = {};
  final Map<String, Set<String>> _links = {};

  /// Every alert linked to [start], directly or through another one; [start] included.
  Set<String> related(String start) {
    final seen = <String>{};
    final todo = [start];
    while (todo.isNotEmpty) {
      final id = todo.removeLast();
      if (!events.containsKey(id) || !seen.add(id)) continue;
      todo.addAll(_links[id] ?? const {});
    }
    return seen;
  }

  /// Whether the pipeline attached [a] and [b] to each other directly.
  bool attached(String a, String b) => (_links[a] ?? const {}).contains(b);

  /// The follow-ups, candidates first: from the server's list when it gives one
  /// ([serverList], which says which are candidates), else from the links alone.
  List<FollowUpGroup> groups(List<Map<String, dynamic>> serverList) {
    final out = <FollowUpGroup>[];
    String label(Iterable<String> ids) => ids.map((i) => events[i]!.label).join('  +  ');
    if (serverList.isNotEmpty) {
      for (final f in serverList) {
        final ids = [
          for (final m in ((f['members'] as List?) ?? const []).cast<Map<String, dynamic>>())
            if (events.containsKey(skyIdOf(m['key'] as String))) skyIdOf(m['key'] as String)
        ];
        if (ids.isNotEmpty) out.add(FollowUpGroup(skyIdOf(f['id'] as String), label(ids), f['candidate'] == true, ids));
      }
    } else {
      final seen = <String>{};
      for (final e in all) {
        if (seen.contains(e.id)) continue;
        final ids = related(e.id).toList()
          ..sort((a, b) => (events[a]!.time ?? DateTime.utc(1970)).compareTo(events[b]!.time ?? DateTime.utc(1970)));
        seen.addAll(ids);
        out.add(FollowUpGroup(e.id, label(ids), ids.length > 1, ids));
      }
    }
    final cand = out.where((g) => g.candidate).toList(), rest = out.where((g) => !g.candidate).toList();
    return [...cand, ...rest];
  }

  bool isLinked(String id) => (_links[id] ?? const {}).isNotEmpty;

  /// All alerts, optical transients first, then GW, GRB, X-ray, neutrino and radio, newest first in each kind.
  List<SkyEvent> get all {
    const order = {'optical': 0, 'gw': 1, 'grb': 2, 'xray': 3, 'nu': 4, 'radio': 5};
    return events.values.toList()
      ..sort((a, b) {
        final k = order[a.kind]!.compareTo(order[b.kind]!);
        if (k != 0) return k;
        return (b.time ?? DateTime.utc(1970)).compareTo(a.time ?? DateTime.utc(1970));
      });
  }

  /// Where the view starts: the newest optical transient that has a superevent, else
  /// the newest optical transient, else the newest alert.
  String? get defaultStart {
    final l = all;
    if (l.isEmpty) return null;
    for (final e in l) {
      if (e.kind == 'optical' && related(e.id).any((x) => x.startsWith('gw:'))) return e.id;
    }
    return l.first.id;
  }
}
