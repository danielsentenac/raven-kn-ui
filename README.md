# RAVEN-KN logbook

A logbook of the [RAVEN-KN](https://github.com/danielsentenac/raven-kn) pipeline for Android and Linux
(Flutter). It copies the pipeline's journal from `raven-kn serve` when it is opened or when Sync is
pressed, keeps the copy for good, and shows it offline. It sends no notification.

| Screen | Shows |
|---|---|
| Logbook | every journal entry, newest first; search, filters by kind, problems only, date range; the values recorded with each entry |
| Candidates | the follow-ups the pipeline labels as candidates (or all follow-ups): their alerts named by detection type (optical, GW, GRB, neutrino), what started them, why they are candidates; for each alert, what the GCN Circulars report (number, optical detection or upper limits, redshift), and whether that redshift puts a GRB within the range of a GW search or too far; one page per follow-up with its steps, log, light curve (with, apart, the magnitudes reported in GCN Circulars, not verified), search and PE results, sky view, the circulars of each alert with their text, and four tabs with what those circulars report, read from their text and not verified: prompt emission (T90, fluence, peak flux, peak energy, spectral index), afterglow (decay index, X-ray and radio fluxes, magnitudes), spectroscopy (redshift, lines, host), images and links (the linked images are shown) |
| Sky | candidates: first selector, the candidate; second selector, the alerts of that candidate only. Alerts without candidate: a type selector (GW, GRB, X-ray, optical, neutrino, radio), a date selector (UTC days) and the list of the alerts, newest first; each alert chosen is added to the map over those already there, and they are removed one by one or with "Clear map". The GW localisation (any stored version) is named on the map; all-sky or zoomed. Under the map, what the GCN Circulars report about each alert shown, which opens the list of its circulars |
| System | link to the server, listeners, age of the run copy, outages and errors |
| Settings | server address, LVK Targeted search token (the reading token), Virgo Targeted search token, portal address; export to JSON or CSV |

The GCN Circulars are linked to the alerts and labelled by the pipeline (keyword rules, see its
`docs/listener.md`); with a server that does not read them, nothing about circulars is shown.

Two tokens are set in Settings. The **LVK Targeted search token** is the reading token of the service: it
gives the logbook, with the results obtained on LVK data when it is the LVK one, and is kept for searches
on LVK data outside the Virgo site. The **Virgo Targeted search token** is sent beside it and is needed to
start a targeted search on the Virgo site; Settings shows whether the server accepted it at the last sync.

With the Virgo Targeted search token accepted, the "GW search" tab of an optical transient has a
"Start targeted search" button: on the site data (the detectors' online strain kept on the Virgo site) or on
the O4 replay (a test of the chain), with the coherent or the network statistic. The application only asks:
the launcher on the Virgo site checks which detectors have observing data and runs the search, or refuses
with the reason for each detector. The requests and what became of them are listed under the button.

## Access through the Virgo portal

The server is inside the Virgo network. The application tells four cases apart:

| Case | How it is recognised | What it offers |
|---|---|---|
| No network | the device has no network interface | Retry |
| Portal session closed or expired | no answer, a redirect, or an answer without the server's `X-Raven-KN` header | Retry, which logs in again (Settings if no portal login is stored) |
| Token refused | a 401 from the server itself | Settings |
| Server error | an error answer from the server | Retry |

In every case the local copy stays readable, with the time of the last sync.

### Automatic portal login

The portal address (a Check Point captive portal) is set in Settings; there is no built-in default. With it and a portal login and password saved, the application logs in by itself when
the server is not reached, at opening and at each sync, then syncs. `lib/src/portal.dart` follows the
portal page's own sequence (session, public key and one-time token, encrypted password, final state),
read from the page served on 2026-11-18; a firewall update may change it, and the application then
says so instead of guessing.

- The password is sent only to the portal address, over HTTPS with the certificate verified. The
  firewall node presents a certificate issued for another name than its address; the setting "name
  on the portal certificate" makes the check use that name. Verification is never switched off.
- If the portal refuses the login, no further automatic attempt is made until the login is saved
  again, so that a wrong password cannot lock the account.
- The two tokens, the portal login and its password are stored in the application's private
  database, not encrypted (owner-only file on Linux; excluded from Android backups).
- `dart run tool/portal_probe.dart <portal URL> [certificate name]` checks the first two steps against the real portal without
  credentials.

## Build and run

```bash
flutter build linux --release      # build/linux/x64/release/bundle/raven_kn_logbook
flutter build apk --release        # build/app/outputs/flutter-apk/app-release.apk
flutter test                       # unit tests, and screenshots of every screen in build/screenshots/
```

The release APK is signed with the debug key of the Flutter template; set a signing key in
`android/app/build.gradle.kts` before distributing it. Plain-HTTP servers are allowed
(`usesCleartextTraffic`), since the service is reached inside the Virgo network.

`sqlite3` is kept at version 2 and two `path_provider` implementations are pinned in `pubspec.yaml`:
the newer versions use native build hooks, which need a clang toolchain to build the Linux application.

## Test data

The tests run on answers of the service saved in `test/fixtures/`. To regenerate them from the pipeline:

```bash
cd ../RAVEN-Kilonova
python examples/logbook_fixture/make_fixture.py --out ../RAVEN-kilonova-gui/fixture/store
RAVEN_KN_TOKEN=pubtok RAVEN_KN_LVK_TOKEN=lvktok raven-kn serve --store ../RAVEN-kilonova-gui/fixture/store &
cd ../RAVEN-kilonova-gui && python tool/capture_fixtures.py http://127.0.0.1:8765 lvktok
```

The same server can be used to try the application: address `http://127.0.0.1:8765`, token `pubtok`
(public runs) or `lvktok` (also the run on LVK data).

## Layout

| File | Role |
|---|---|
| `lib/src/api.dart` | client of the service; what a failed request means |
| `lib/src/archive.dart` | local SQLite copy: entries, documents, sky maps |
| `lib/src/state.dart` | settings and sync |
| `lib/src/healpix.dart` | HEALPix pixel of a position (checked against healpy), sky projections |
| `lib/src/ui/` | screens; `plots.dart` is the one plot widget, `sky.dart` the sky view, `circulars.dart` the GCN Circulars of an alert, `reported.dart` what they report by category |
