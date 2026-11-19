/// Shared pieces of the interface: colours, status marks, formats, access to the state.
library;

import 'package:flutter/material.dart';

import '../state.dart';

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);
  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

/// Chart colours, light and dark (categorical order is fixed; status colours are reserved).
class Palette {
  const Palette._(this.dark);
  factory Palette.of(BuildContext c) => Palette._(Theme.of(c).brightness == Brightness.dark);
  final bool dark;

  static const _catLight = [0xff2a78d6, 0xffeb6834, 0xff1baf7a, 0xffeda100, 0xffe87ba4, 0xff008300, 0xff6250d6, 0xffe34948];
  static const _catDark = [0xff3987e5, 0xffd95926, 0xff199e70, 0xffc98500, 0xffd55181, 0xff0ca30c, 0xff9085e9, 0xffe66767];
  Color series(int slot) => Color((dark ? _catDark : _catLight)[slot % 8]);

  Color get surface => dark ? const Color(0xff1a1a19) : const Color(0xfffcfcfb);
  Color get ink => dark ? const Color(0xfff0efec) : const Color(0xff0b0b0b);
  Color get ink2 => dark ? const Color(0xffc3c2b7) : const Color(0xff52514e);
  Color get muted => dark ? const Color(0xff8a897f) : const Color(0xff8b8a84);
  Color get grid => dark ? const Color(0xff33332f) : const Color(0xffe6e5e0);
  Color get other => dark ? const Color(0xff8a897f) : const Color(0xff8b8a84);

  static const good = Color(0xff0ca30c);
  static const warning = Color(0xfffab219);
  static const serious = Color(0xffec835a);
  static const critical = Color(0xffd03b3b);

  /// Sequential blue of the sky map: credible level 0 (most probable) to 1.
  Color sequential(double credible) {
    const steps = [0xff0d366b, 0xff184f95, 0xff256abf, 0xff3987e5, 0xff6da7ec, 0xff9ec5f4, 0xffcde2fb];
    final s = dark ? steps.reversed.toList() : steps;
    final x = credible.clamp(0.0, 1.0) * (s.length - 1);
    final i = x.floor().clamp(0, s.length - 2);
    return Color.lerp(Color(s[i]), Color(s[i + 1]), x - i)!;
  }
}

/// Status of a pipeline step or of a run: colour, icon and word together.
class StatusStyle {
  const StatusStyle(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;

  static StatusStyle of(String status, BuildContext c) {
    final muted = Palette.of(c).muted;
    return switch (status) {
      'done' => const StatusStyle('Done', Icons.check_circle, Palette.good),
      'running' => StatusStyle('Running', Icons.autorenew, Palette.of(c).series(0)),
      'held' => const StatusStyle('Held', Icons.pause_circle, Palette.warning),
      'warning' => const StatusStyle('Check', Icons.warning_amber_rounded, Palette.serious),
      'failed' => const StatusStyle('Failed', Icons.cancel, Palette.critical),
      'stale' => const StatusStyle('No news', Icons.hourglass_disabled, Palette.serious),
      _ => StatusStyle('Waiting', Icons.radio_button_unchecked, muted),
    };
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.dense = false});
  final String status;
  final bool dense;
  @override
  Widget build(BuildContext context) {
    final s = StatusStyle.of(status, context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(s.icon, color: s.color, size: dense ? 16 : 18),
      const SizedBox(width: 4),
      Text(s.label, style: Theme.of(context).textTheme.labelMedium),
    ]);
  }
}

IconData kindIcon(String kind) => switch (kind) {
      'optical_new' => Icons.fiber_new,
      'optical_update' => Icons.add_chart,
      'host_lookup' => Icons.travel_explore,
      'lookup_failed' => Icons.cloud_off,
      'gw_alert' => Icons.waves,
      'gw_retraction' => Icons.undo,
      'grb_notice' => Icons.flash_on,
      'xray_position' => Icons.my_location,
      'circular' => Icons.article,
      'grb_distance' => Icons.straighten,
      'nu_notice' || 'nu_retraction' => Icons.grain,
      'grb_attached' || 'nu_attached' => Icons.link,
      'grb_detached' || 'nu_detached' => Icons.link_off,
      'coincidence' => Icons.join_inner,
      'decision' => Icons.rule,
      'search_request' => Icons.assignment,
      'run_submitted' => Icons.upload,
      'run_start' => Icons.play_arrow,
      'run_stage' || 'run_progress' => Icons.timelapse,
      'run_end' => Icons.flag,
      'run_failed' => Icons.error,
      'search_result' => Icons.insights,
      'pe_result' => Icons.scatter_plot,
      'listener_start' => Icons.power_settings_new,
      'kafka_error' => Icons.wifi_off,
      'message_failed' => Icons.report,
      _ => Icons.notes,
    };

Color? levelColor(String level) => switch (level) { 'error' => Palette.critical, 'warning' => Palette.serious, _ => null };

String two(int n) => n.toString().padLeft(2, '0');

/// `2026-10-21 01:49:17` in UTC.
String fmtTime(DateTime? t, {bool seconds = true}) {
  if (t == null) return 'time unknown';
  final u = t.toUtc();
  return '${u.year}-${two(u.month)}-${two(u.day)} ${two(u.hour)}:${two(u.minute)}${seconds ? ':${two(u.second)}' : ''}';
}

String fmtDay(DateTime t) {
  final u = t.toUtc();
  return '${u.year}-${two(u.month)}-${two(u.day)}';
}

String fmtAgo(Duration d) {
  final s = d.inSeconds.abs();
  if (s < 90) return '$s s';
  if (s < 5400) return '${(s / 60).round()} min';
  if (s < 172800) return '${(s / 3600).toStringAsFixed(1)} h';
  return '${(s / 86400).toStringAsFixed(1)} d';
}

String fmtNum(num? v, {int sig = 3}) {
  if (v == null) return 'unknown';
  final d = v.toDouble();
  if (d == 0) return '0';
  final a = d.abs();
  if (a >= 1e5 && a < 1e12) {
    // large plain numbers (GPS times): digits rather than an exponent
    final digits = a.toStringAsFixed(0).length;
    final s = d.toStringAsFixed((sig - digits).clamp(0, 3));
    return s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
  }
  if (a >= 1e12 || a < 1e-3) return d.toStringAsExponential(sig - 1);
  if (a >= 1000 || a >= _pow10(sig)) return d.toStringAsFixed(0);
  final s = d.toStringAsPrecision(sig);
  return s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
}

double _pow10(int n) {
  var r = 1.0;
  for (var i = 0; i < n; i++) {
    r *= 10;
  }
  return r;
}

double? asDouble(Object? v) => v is num ? v.toDouble() : null;
