/// Application state: settings, link to the server, and the sync that fills the archive.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'archive.dart';
import 'portal.dart';

class AppState extends ChangeNotifier {
  AppState(this.archive, {this.clientFactory, PortalLoginFn? portalLogin}) : _portalLogin = portalLogin ?? portalLoginDefault {
    final b = int.tryParse(archive.meta('batch') ?? '') ?? 0;
    batch = b;
    lastSync = DateTime.tryParse(archive.meta('last_sync') ?? '');
    conn = serverUrl.isEmpty ? Conn.notConfigured : Conn.unknown;
  }

  final Archive archive;
  final http.Client Function()? clientFactory;
  final PortalLoginFn _portalLogin;

  Conn conn = Conn.unknown;
  String connMessage = '';
  bool syncing = false;
  String progress = '';
  DateTime? lastSync;

  /// Number of the last sync; entries carry the number of the sync that brought them.
  int batch = 0;

  String get serverUrl => archive.meta('server_url') ?? '';
  String get token => archive.meta('token') ?? '';
  /// Login page of the firewall portal, set in Settings; empty when not set.
  String get portalUrl => archive.meta('portal_url') ?? '';

  /// Name on the portal's certificate, when it is not the name in its address.
  String get portalCertName => archive.meta('portal_cert_name') ?? '';

  String get portalUser => archive.meta('portal_user') ?? '';
  String get portalPassword => archive.meta('portal_password') ?? '';
  bool get portalAuto => archive.meta('portal_auto') != '0';

  /// The portal refused these credentials: no automatic login until they are saved again
  /// (repeated refusals could lock the account).
  bool get portalRefused => archive.meta('portal_refused') == '1';

  bool get canAutoLogin => portalAuto && portalUrl.isNotEmpty && portalUser.isNotEmpty && portalPassword.isNotEmpty && !portalRefused;

  void savePortalLogin({required String user, required String password, required bool auto, String? certName}) {
    archive.setMeta('portal_user', user.trim());
    archive.setMeta('portal_password', password);
    archive.setMeta('portal_auto', auto ? '1' : '0');
    if (certName != null) archive.setMeta('portal_cert_name', certName.trim());
    archive.setMeta('portal_refused', null);
    notifyListeners();
  }

  /// Whether saving [newUrl] would replace the local copy: it holds data from another server.
  bool wouldReplaceData(String newUrl) =>
      _norm(newUrl) != _norm(serverUrl) && (archive.count(const LogQuery()) > 0 || archive.doc('sky') != null);

  static String _norm(String url) => url.trim().replaceAll(RegExp(r'/+$'), '').toLowerCase();

  /// Saves the settings. A local copy belongs to one server: with another
  /// server address, the copy of the previous one is removed, so that the
  /// data of two stores are never mixed.
  void saveSettings({required String serverUrl, required String token, required String portalUrl}) {
    if (wouldReplaceData(serverUrl)) {
      archive.clearData();
      batch = 0;
      lastSync = null;
    }
    archive.setMeta('server_url', serverUrl.trim());
    archive.setMeta('token', token.trim());
    archive.setMeta('portal_url', portalUrl.trim());
    conn = serverUrl.trim().isEmpty ? Conn.notConfigured : Conn.unknown;
    connMessage = '';
    notifyListeners();
  }

  Map<String, dynamic>? get health => archive.doc('health');
  bool get lvk => health?['lvk'] == true;

  /// The optical transients, with their steps.
  List<Map<String, dynamic>> get opticals =>
      ((archive.doc('optical')?['optical'] as List?) ?? const []).cast<Map<String, dynamic>>();

  /// Alerts grouped by the links the pipeline made; a group may be a candidate.
  List<Map<String, dynamic>> get followups =>
      ((archive.doc('followups')?['followups'] as List?) ?? const []).cast<Map<String, dynamic>>();

  /// Entries brought by the last sync.
  int get newCount => batch == 0 ? 0 : archive.countBatch(batch);

  void _step(String what) {
    progress = what;
    notifyListeners();
  }

  /// Brings everything new from the server into the archive. Never throws:
  /// the outcome is in [conn] and [connMessage]. When the server is not
  /// reached and a portal login is stored, logs in to the portal and tries once more.
  Future<void> sync() async {
    if (syncing) return;
    if (serverUrl.isEmpty) {
      conn = Conn.notConfigured;
      connMessage = 'Set the server address in Settings';
      notifyListeners();
      return;
    }
    syncing = true;
    try {
      await _syncOnce();
      if (conn == Conn.portalClosed && portalAuto && portalRefused) {
        connMessage = 'Automatic login is stopped: the portal refused the stored login (save it again in Settings). $connMessage';
      }
      if (conn == Conn.portalClosed && canAutoLogin) {
        final first = connMessage;
        _step('Logging in to the Virgo portal');
        final r = await _portalLogin(portalUrl, portalCertName, portalUser, portalPassword);
        if (r.refused) archive.setMeta('portal_refused', '1');
        if (r.ok) {
          await _syncOnce();
          if (conn == Conn.ok) {
            connMessage = '${connMessage[0].toUpperCase()}${connMessage.substring(1)}, after logging in to the portal';
          } else if (conn == Conn.portalClosed) {
            connMessage = '$connMessage. The portal login succeeded (${r.message}) but the server is still not reached';
          }
        } else {
          conn = Conn.portalClosed;
          connMessage = 'Automatic login failed: ${r.message}'
              '${r.refused ? '. It will not be tried again until the login is saved again in Settings' : ''}. $first';
        }
      }
    } finally {
      syncing = false;
      progress = '';
      notifyListeners();
    }
  }

  Future<void> _syncOnce() async {
    _step('Contacting the server');
    final api = Api(serverUrl, token, client: clientFactory?.call());
    try {
      final health = await api.getJson('/api/health');
      if (health['service'] != 'raven-kn') {
        throw ApiException(Conn.portalClosed, 'The answer does not come from the server');
      }
      archive.putDoc('health', health);
      final scope = health['lvk'] == true ? 'lvk' : 'public';
      final next = batch + 1;

      // journal: everything after the cursor of this access level
      var cursor = archive.meta('cursor_$scope') ?? '';
      var added = 0;
      final touched = <String>{};
      while (true) {
        _step('Reading the journal${added > 0 ? ' ($added new)' : ''}');
        final r = await api.getJson('/api/events?limit=2000&cursor=${Uri.encodeQueryComponent(cursor)}');
        final ev = (r['events'] as List?) ?? const [];
        added += archive.addEvents(ev, next);
        for (final e in ev.cast<Map<String, dynamic>>()) {
          final o = e['optical'] ?? e['candidate']; // 'candidate': the key of older servers
          if (o != null) touched.add(o as String);
        }
        cursor = r['cursor'] as String? ?? cursor;
        archive.setMeta('cursor_$scope', cursor);
        if (r['more'] != true) break;
      }

      // optical transients: the list, and the page of those that changed or are not stored yet
      _step('Reading the follow-ups');
      try {
        archive.putDoc('followups', await api.getJson('/api/followups'));
      } on ApiException catch (e) {
        if (!e.notFound) rethrow; // an older server: no follow-ups
      }
      final list = await api.getJson('/api/optical');
      archive.putDoc('optical', list);
      final summaries = ((list['optical'] as List?) ?? const []).cast<Map<String, dynamic>>();
      final names = summaries.map((c) => c['name'] as String).toList();
      final scopeChanged = archive.meta('last_scope') != scope;
      for (final name in names) {
        final key = 'optical/$name';
        // also when the steps in the list differ from the stored page: the state can change
        // without a journal entry (a run copied from the cluster, a store rebuilt)
        final stored = archive.doc(key);
        final same = stored != null &&
            jsonEncode(stored['steps']) == jsonEncode(summaries.firstWhere((c) => c['name'] == name)['steps']);
        if (!touched.contains(name) && same && !scopeChanged) continue;
        _step('Reading $name');
        try {
          final d = await api.getJson('/api/optical/${Uri.encodeComponent(name)}');
          archive.putDoc(key, d);
          for (final run in ((d['runs'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
            final rn = run['run'] as String;
            final rd = await api.getJson('/api/runs/${Uri.encodeComponent(name)}/${Uri.encodeComponent(rn)}');
            archive.putDoc('run/$name/$rn', rd);
          }
        } on ApiException catch (e) {
          if (!e.notFound) rethrow;
        }
      }

      // sky: positions, and the maps not stored yet
      _step('Reading the sky maps');
      final sky = await api.getJson('/api/sky');
      archive.putDoc('sky', sky);
      for (final se in ((sky['gw'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
        final sid = se['superevent_id'] as String;
        for (final v in ((se['versions'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
          for (final kind in ((v['maps'] as Map?) ?? const {}).keys) {
            final key = 'map/$sid/${v['version']}/$kind';
            if (archive.hasBlob(key)) continue;
            try {
              archive.putBlob(key, await api.getBytes('/api/gw/${Uri.encodeComponent(sid)}/map/${v['version']}/$kind'));
            } on ApiException catch (e) {
              if (!e.notFound) rethrow;
            }
          }
        }
      }

      if (added > 0 || batch == 0) {
        batch = next;
        archive.setMeta('batch', '$batch');
      }
      archive.setMeta('last_scope', scope);
      lastSync = DateTime.now().toUtc();
      archive.setMeta('last_sync', lastSync!.toIso8601String());
      conn = Conn.ok;
      connMessage = added == 0 ? 'Up to date' : '$added new entr${added == 1 ? 'y' : 'ies'}';
    } on ApiException catch (e) {
      conn = e.conn == Conn.ok ? Conn.serverError : e.conn;
      connMessage = e.message;
    } catch (e) {
      conn = Conn.serverError;
      connMessage = 'Sync failed: $e';
    } finally {
      api.close();
    }
  }
}

typedef PortalLoginFn = Future<PortalResult> Function(String portalUrl, String certName, String user, String password);

Future<PortalResult> portalLoginDefault(String portalUrl, String certName, String user, String password) =>
    portalLogin(portalUrl, certName, user, password);
