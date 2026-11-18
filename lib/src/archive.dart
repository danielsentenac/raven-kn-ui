/// Local, permanent copy of everything synced: journal entries, documents, sky maps.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

class LogEntry {
  LogEntry(this.id, this.time, this.kind, this.level, this.source, this.optical, this.superevent,
      this.run, this.summary, this.raw, this.batch);
  final String id;
  final DateTime? time;
  final String kind, level, source, summary;

  /// Name of the optical transient the entry is about, if any.
  final String? optical;
  final String? superevent, run;
  final String raw;
  final int batch;

  Map<String, dynamic> get json => jsonDecode(raw) as Map<String, dynamic>;
  Map<String, dynamic> get data => (json['data'] as Map?)?.cast<String, dynamic>() ?? const {};
  bool get isSystem => systemKinds.contains(kind);
}

/// Entries about the pipeline itself rather than about the sky.
const systemKinds = {
  'listener_start', 'kafka_error', 'message_failed', 'journal_error', 'lookup_failed', 'run_failed', 'note',
};

/// Kinds written by servers older than the rename of the optical transient.
const _oldKinds = {'candidate_new': 'optical_new', 'candidate_update': 'optical_update'};

/// Filter groups of the logbook.
const kindGroups = <String, Set<String>>{
  'Optical': {'optical_new', 'optical_update', 'host_lookup', 'lookup_failed'},
  'Alerts': {'gw_alert', 'gw_retraction', 'grb_notice', 'xray_position', 'nu_notice', 'nu_retraction'},
  'Associations': {'grb_attached', 'grb_detached', 'nu_attached', 'nu_detached', 'coincidence'},
  'Decisions': {'decision', 'search_request'},
  'Search and PE': {
    'run_submitted', 'run_start', 'run_stage', 'run_progress', 'run_end', 'run_failed', 'search_result', 'pe_result',
  },
  'System': {'listener_start', 'kafka_error', 'message_failed', 'journal_error', 'note'},
};

class LogQuery {
  const LogQuery({this.text = '', this.groups = const {}, this.problemsOnly = false, this.optical,
      this.superevent, this.from, this.to});
  final String text;
  final Set<String> groups;
  final bool problemsOnly;
  final String? optical, superevent;
  final DateTime? from, to;

  LogQuery copyWith({String? text, Set<String>? groups, bool? problemsOnly, DateTime? from, DateTime? to,
          bool clearDates = false}) =>
      LogQuery(
          text: text ?? this.text,
          groups: groups ?? this.groups,
          problemsOnly: problemsOnly ?? this.problemsOnly,
          optical: optical,
          superevent: superevent,
          from: clearDates ? null : from ?? this.from,
          to: clearDates ? null : to ?? this.to);
}

class Archive {
  Archive(this.db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS events(
        id TEXT PRIMARY KEY, time TEXT, kind TEXT, level TEXT, source TEXT, candidate TEXT,
        superevent TEXT, run TEXT, summary TEXT, json TEXT, batch INTEGER);
      CREATE INDEX IF NOT EXISTS events_time ON events(time);
      CREATE INDEX IF NOT EXISTS events_cand ON events(candidate);
      CREATE TABLE IF NOT EXISTS docs(key TEXT PRIMARY KEY, json TEXT, fetched TEXT);
      CREATE TABLE IF NOT EXISTS blobs(key TEXT PRIMARY KEY, data BLOB);
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
    ''');
  }

  factory Archive.open(String path) => Archive(sqlite3.open(path));
  factory Archive.memory() => Archive(sqlite3.openInMemory());

  final Database db;

  // ---- settings and counters
  String? meta(String key) {
    final r = db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  void setMeta(String key, String? value) {
    if (value == null) {
      db.execute('DELETE FROM meta WHERE key = ?', [key]);
    } else {
      db.execute('INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)', [key, value]);
    }
  }

  // ---- journal
  /// Adds entries not yet stored; returns how many were new.
  int addEvents(List<dynamic> events, int batch) {
    var n = 0;
    final st = db.prepare('INSERT OR IGNORE INTO events VALUES(?,?,?,?,?,?,?,?,?,?,?)');
    db.execute('BEGIN');
    try {
      for (final e in events.cast<Map<String, dynamic>>()) {
        st.execute([
          e['id'], e['time'] ?? '', _oldKinds[e['kind']] ?? e['kind'] ?? '', e['level'] ?? 'info', e['source'] ?? '',
          e['optical'] ?? e['candidate'], e['superevent'], e['run'], e['summary'] ?? '', jsonEncode(e), batch,
        ]);
        n += db.updatedRows;
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    } finally {
      st.dispose();
    }
    return n;
  }

  (String, List<Object?>) _where(LogQuery q) {
    final w = <String>[], a = <Object?>[];
    if (q.text.trim().isNotEmpty) {
      for (final word in q.text.trim().split(RegExp(r'\s+'))) {
        w.add("(summary LIKE ? ESCAPE '\\' OR candidate LIKE ? ESCAPE '\\' OR superevent LIKE ? ESCAPE '\\' "
            "OR kind LIKE ? ESCAPE '\\')");
        final p = '%${word.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
        a.addAll([p, p, p, p]);
      }
    }
    if (q.groups.isNotEmpty) {
      final kinds = q.groups.expand((g) => kindGroups[g] ?? const <String>{}).toSet();
      w.add('kind IN (${List.filled(kinds.length, '?').join(',')})');
      a.addAll(kinds);
    }
    if (q.problemsOnly) w.add("level IN ('warning', 'error')");
    if (q.optical != null) {
      w.add('candidate = ?'); // the column keeps its first name
      a.add(q.optical);
    }
    if (q.superevent != null) {
      w.add('superevent = ?');
      a.add(q.superevent);
    }
    if (q.from != null) {
      w.add('time >= ?');
      a.add(q.from!.toUtc().toIso8601String());
    }
    if (q.to != null) {
      w.add('time < ?');
      a.add(q.to!.toUtc().toIso8601String());
    }
    return (w.isEmpty ? '' : 'WHERE ${w.join(' AND ')}', a);
  }

  static LogEntry _entry(Row r) => LogEntry(
      r['id'] as String, DateTime.tryParse(r['time'] as String? ?? ''), r['kind'] as String,
      r['level'] as String, r['source'] as String, r['candidate'] as String?, r['superevent'] as String?,
      r['run'] as String?, r['summary'] as String, r['json'] as String, r['batch'] as int? ?? 0);

  /// Entries matching [q], newest first (or oldest first).
  List<LogEntry> events(LogQuery q, {int limit = 200, int offset = 0, bool oldestFirst = false}) {
    final (w, a) = _where(q);
    final dir = oldestFirst ? 'ASC' : 'DESC';
    return db
        .select('SELECT * FROM events $w ORDER BY time $dir, id $dir LIMIT ? OFFSET ?', [...a, limit, offset])
        .map(_entry)
        .toList();
  }

  int count(LogQuery q) {
    final (w, a) = _where(q);
    return db.select('SELECT COUNT(*) AS n FROM events $w', a).first['n'] as int;
  }

  int countBatch(int batch, {bool problems = false}) => db.select(
      "SELECT COUNT(*) AS n FROM events WHERE batch = ?${problems ? " AND level IN ('warning','error')" : ''}",
      [batch]).first['n'] as int;

  Map<String, int> kindsOfBatch(int batch) => {
        for (final r in db.select('SELECT kind, COUNT(*) AS n FROM events WHERE batch = ? GROUP BY kind', [batch]))
          r['kind'] as String: r['n'] as int
      };

  // ---- documents (pages of optical transients, run results, health...)
  void putDoc(String key, Object json) => db.execute('INSERT OR REPLACE INTO docs VALUES(?, ?, ?)',
      [key, jsonEncode(json), DateTime.now().toUtc().toIso8601String()]);

  Map<String, dynamic>? doc(String key) {
    final r = db.select('SELECT json FROM docs WHERE key = ?', [key]);
    return r.isEmpty ? null : jsonDecode(r.first['json'] as String) as Map<String, dynamic>;
  }

  DateTime? docTime(String key) {
    final r = db.select('SELECT fetched FROM docs WHERE key = ?', [key]);
    return r.isEmpty ? null : DateTime.tryParse(r.first['fetched'] as String);
  }

  List<String> docKeys(String prefix) => db
      .select("SELECT key FROM docs WHERE key LIKE ? ESCAPE '\\' ORDER BY key",
          ['${prefix.replaceAll('_', r'\_').replaceAll('%', r'\%')}%'])
      .map((r) => r['key'] as String)
      .toList();

  // ---- sky maps
  bool hasBlob(String key) => db.select('SELECT 1 FROM blobs WHERE key = ?', [key]).isNotEmpty;
  void putBlob(String key, Uint8List data) => db.execute('INSERT OR REPLACE INTO blobs VALUES(?, ?)', [key, data]);
  Uint8List? blob(String key) {
    final r = db.select('SELECT data FROM blobs WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['data'] as Uint8List;
  }

  /// Removes everything copied from a server (entries, pages, maps, sync positions); settings stay.
  void clearData() {
    db.execute('DELETE FROM events; DELETE FROM docs; DELETE FROM blobs;');
    db.execute("DELETE FROM meta WHERE key LIKE 'cursor\\_%' ESCAPE '\\' OR key IN ('batch', 'last_sync', 'last_scope')");
  }

  void close() => db.dispose();
}
