/// One x-y plot widget for every figure: markers with error bars and upper
/// limits, lines, histograms, vertical marks and bands, an inverted axis for
/// magnitudes, a legend, and a readout of the nearest point on tap or hover.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'common.dart';

enum SeriesStyle { markers, line, bars }

class Pt {
  const Pt(this.x, this.y, {this.err, this.limit = false, this.note});
  final double x, y;
  final double? err;

  /// An upper limit (drawn as an open triangle pointing to fainter values).
  final bool limit;
  final String? note;
}

class Series {
  const Series(this.name, this.color, this.points, {this.style = SeriesStyle.markers, this.dashed = false});
  final String name;
  final Color color;
  final List<Pt> points;
  final SeriesStyle style;
  final bool dashed;
}

class VMark {
  const VMark(this.x, this.label, this.color, {this.dashed = true});
  final double x;
  final String label;
  final Color color;
  final bool dashed;
}

class VBand {
  const VBand(this.x0, this.x1, this.label, this.color);
  final double x0, x1;
  final String label;
  final Color color;
}

List<double> niceTicks(double lo, double hi, int target) {
  if (!(hi > lo)) return [lo];
  final raw = (hi - lo) / math.max(1, target);
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final f = raw / mag;
  final step = (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * mag;
  final out = <double>[];
  for (var v = (lo / step).ceil() * step; v <= hi + step * 1e-9; v += step) {
    out.add((v / step).round() * step);
  }
  return out;
}

String tickLabel(double v, double step) {
  if (v == 0) return '0';
  final a = v.abs();
  if (a >= 1e5 || a < 1e-3) return v.toStringAsExponential(1);
  final dec = step >= 1 ? 0 : (-(math.log(step) / math.ln10).floor()).clamp(0, 6);
  return v.toStringAsFixed(dec);
}

class XYPlot extends StatefulWidget {
  const XYPlot({super.key, required this.series, this.vmarks = const [], this.vbands = const [], this.xLabel = '',
      this.yLabel = '', this.invertY = false, this.height = 260, this.yMin, this.yMax, this.xMin, this.xMax,
      this.title});
  final List<Series> series;
  final List<VMark> vmarks;
  final List<VBand> vbands;
  final String xLabel, yLabel;
  final bool invertY;
  final double height;
  final double? yMin, yMax, xMin, xMax;
  final String? title;

  @override
  State<XYPlot> createState() => _XYPlotState();
}

class _XYPlotState extends State<XYPlot> {
  Offset? _probe;

  @override
  Widget build(BuildContext context) {
    final pal = Palette.of(context);
    final text = Theme.of(context).textTheme;
    final shown = widget.series.where((s) => s.points.isNotEmpty).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.title != null)
        Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(widget.title!, style: text.titleSmall)),
      if (shown.isEmpty)
        SizedBox(height: 80, child: Center(child: Text('No data', style: text.bodySmall)))
      else
        SizedBox(
          height: widget.height,
          width: double.infinity,
          child: MouseRegion(
            onHover: (e) => setState(() => _probe = e.localPosition),
            onExit: (_) => setState(() => _probe = null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => setState(() => _probe = d.localPosition),
              onPanUpdate: (d) => setState(() => _probe = d.localPosition),
              child: CustomPaint(painter: _PlotPainter(widget, shown, pal, text, _probe)),
            ),
          ),
        ),
      if (shown.length > 1 || widget.vbands.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 44),
          child: Wrap(spacing: 14, runSpacing: 4, children: [
            for (final s in shown) _legend(s.color, s.name, text, pal, line: s.style == SeriesStyle.line),
            for (final b in widget.vbands) _legend(b.color.withValues(alpha: 0.35), b.label, text, pal, band: true),
          ]),
        ),
    ]);
  }

  Widget _legend(Color c, String name, TextTheme text, Palette pal, {bool line = false, bool band = false}) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: line ? 16 : (band ? 14 : 10),
            height: line ? 2.5 : 10,
            decoration: BoxDecoration(color: c, shape: line || band ? BoxShape.rectangle : BoxShape.circle)),
        const SizedBox(width: 5),
        Text(name, style: text.labelSmall?.copyWith(color: pal.ink2)),
      ]);
}

class _PlotPainter extends CustomPainter {
  _PlotPainter(this.w, this.series, this.pal, this.text, this.probe);
  final XYPlot w;
  final List<Series> series;
  final Palette pal;
  final TextTheme text;
  final Offset? probe;

  TextPainter _tp(String s, Color c, {double size = 11, FontWeight? weight}) => TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: c, fontSize: size, fontWeight: weight, fontFamily: text.bodySmall?.fontFamily)),
      textDirection: TextDirection.ltr)
    ..layout();

  @override
  void paint(Canvas canvas, Size size) {
    const left = 46.0, right = 10.0, top = 16.0, bottom = 36.0;
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    if (plot.width < 20 || plot.height < 20) return;

    // ranges
    var x0 = double.infinity, x1 = -double.infinity, y0 = double.infinity, y1 = -double.infinity;
    for (final s in series) {
      for (final p in s.points) {
        if (!p.x.isFinite || !p.y.isFinite) continue;
        x0 = math.min(x0, p.x);
        x1 = math.max(x1, p.x);
        y0 = math.min(y0, p.y - (p.err ?? 0));
        y1 = math.max(y1, p.y + (p.err ?? 0));
      }
      if (s.style == SeriesStyle.bars) y0 = math.min(y0, 0);
    }
    for (final m in w.vmarks) {
      x0 = math.min(x0, m.x);
      x1 = math.max(x1, m.x);
    }
    if (!x0.isFinite || !y0.isFinite) return;
    if (x1 == x0) {
      x0 -= 0.5;
      x1 += 0.5;
    }
    if (y1 == y0) {
      y0 -= 0.5;
      y1 += 0.5;
    }
    final padX = (x1 - x0) * 0.04, padY = (y1 - y0) * 0.08;
    final bars = series.any((s) => s.style == SeriesStyle.bars);
    x0 = w.xMin ?? x0 - padX;
    x1 = w.xMax ?? x1 + padX;
    y0 = w.yMin ?? (bars && y0 == 0 ? 0 : y0 - padY);
    y1 = w.yMax ?? y1 + padY;

    double px(double x) => plot.left + (x - x0) / (x1 - x0) * plot.width;
    double py(double y) {
      final f = (y - y0) / (y1 - y0);
      return w.invertY ? plot.top + f * plot.height : plot.bottom - f * plot.height;
    }

    // grid and ticks (recessive)
    final grid = Paint()
      ..color = pal.grid
      ..strokeWidth = 1;
    final xt = niceTicks(x0, x1, (plot.width / 80).floor().clamp(2, 8));
    final yt = niceTicks(y0, y1, (plot.height / 44).floor().clamp(2, 8));
    final xs = xt.length > 1 ? xt[1] - xt[0] : 1.0, ys = yt.length > 1 ? yt[1] - yt[0] : 1.0;
    for (final v in yt) {
      canvas.drawLine(Offset(plot.left, py(v)), Offset(plot.right, py(v)), grid);
      final t = _tp(tickLabel(v, ys), pal.muted);
      t.paint(canvas, Offset(plot.left - 6 - t.width, py(v) - t.height / 2));
    }
    for (final v in xt) {
      canvas.drawLine(Offset(px(v), plot.bottom), Offset(px(v), plot.bottom + 4), grid);
      final t = _tp(tickLabel(v, xs), pal.muted);
      t.paint(canvas, Offset((px(v) - t.width / 2).clamp(0, size.width - t.width), plot.bottom + 6));
    }
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, Paint()..color = pal.muted);
    if (w.xLabel.isNotEmpty) {
      final t = _tp(w.xLabel, pal.ink2);
      t.paint(canvas, Offset(plot.center.dx - t.width / 2, size.height - t.height - 1));
    }
    if (w.yLabel.isNotEmpty) {
      final t = _tp(w.yLabel, pal.ink2);
      t.paint(canvas, Offset(2, 0));
    }

    canvas.save();
    canvas.clipRect(plot.inflate(1));
    // bands and vertical marks
    for (final b in w.vbands) {
      var a = px(b.x0), c = px(b.x1);
      if (c - a < 3) {
        final m = (a + c) / 2;
        a = m - 1.5;
        c = m + 1.5;
      }
      canvas.drawRect(Rect.fromLTRB(a, plot.top, c, plot.bottom), Paint()..color = b.color.withValues(alpha: 0.22));
    }
    canvas.restore();
    var labelRow = 0;
    for (final m in w.vmarks) {
      final x = px(m.x);
      if (x < plot.left - 1 || x > plot.right + 1) continue;
      final p = Paint()
        ..color = m.color
        ..strokeWidth = 1.5;
      if (m.dashed) {
        for (var y = plot.top; y < plot.bottom; y += 7) {
          canvas.drawLine(Offset(x, y), Offset(x, math.min(y + 4, plot.bottom)), p);
        }
      } else {
        canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), p);
      }
      final t = _tp(m.label, pal.ink2, size: 10);
      final tx = (x + 3 + t.width > plot.right) ? x - 3 - t.width : x + 3;
      t.paint(canvas, Offset(tx, plot.top + 2 + 12.0 * (labelRow++ % 3)));
    }

    canvas.save();
    canvas.clipRect(plot.inflate(6));
    for (final s in series) {
      final pts = s.points.where((p) => p.x.isFinite && p.y.isFinite).toList();
      switch (s.style) {
        case SeriesStyle.line:
          final path = Path();
          for (var i = 0; i < pts.length; i++) {
            final o = Offset(px(pts[i].x), py(pts[i].y));
            i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
          }
          canvas.drawPath(
              path,
              Paint()
                ..color = s.color
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2
                ..strokeJoin = StrokeJoin.round);
        case SeriesStyle.bars:
          if (pts.length < 2) break;
          final bw = (px(pts[1].x) - px(pts[0].x)).abs();
          for (final p in pts) {
            if (p.y <= 0) continue;
            final r = Rect.fromLTRB(px(p.x) - bw / 2 + 1, py(p.y), px(p.x) + bw / 2 - 1, py(0));
            canvas.drawRRect(
                RRect.fromRectAndCorners(r, topLeft: const Radius.circular(3), topRight: const Radius.circular(3)),
                Paint()..color = s.color);
          }
        case SeriesStyle.markers:
          final fill = Paint()..color = s.color;
          final ring = Paint()
            ..color = pal.surface
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5;
          final stroke = Paint()
            ..color = s.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5;
          for (final p in pts) {
            final o = Offset(px(p.x), py(p.y));
            if (p.limit) {
              // open triangle pointing towards fainter (larger) magnitudes
              final d = w.invertY ? 1.0 : -1.0;
              final tri = Path()
                ..moveTo(o.dx - 5, o.dy - 4 * d)
                ..lineTo(o.dx + 5, o.dy - 4 * d)
                ..lineTo(o.dx, o.dy + 5 * d)
                ..close();
              canvas.drawPath(tri, Paint()..color = pal.surface);
              canvas.drawPath(tri, stroke);
              continue;
            }
            if (p.err != null && p.err! > 0) {
              canvas.drawLine(Offset(o.dx, py(p.y - p.err!)), Offset(o.dx, py(p.y + p.err!)), stroke);
            }
            canvas.drawCircle(o, 4, fill);
            canvas.drawCircle(o, 4.75, ring);
          }
      }
    }
    canvas.restore();

    // readout of the nearest point
    if (probe != null && plot.inflate(12).contains(probe!)) {
      Pt? best;
      Series? bs;
      var bd = double.infinity;
      for (final s in series) {
        for (final p in s.points) {
          if (!p.x.isFinite || !p.y.isFinite) continue;
          final d = s.style == SeriesStyle.markers
              ? (Offset(px(p.x), py(p.y)) - probe!).distance
              : (px(p.x) - probe!.dx).abs() + (s.style == SeriesStyle.line ? (py(p.y) - probe!.dy).abs() * 0.15 : 0);
          if (d < bd) {
            bd = d;
            best = p;
            bs = s;
          }
        }
      }
      if (best != null && bs != null) {
        final o = Offset(px(best.x), py(best.y));
        canvas.drawLine(Offset(o.dx, plot.top), Offset(o.dx, plot.bottom), Paint()..color = pal.muted);
        canvas.drawCircle(
            o,
            6,
            Paint()
              ..color = bs.color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2);
        final label = '${series.length > 1 ? '${bs.name}  ' : ''}'
            '${w.xLabel.isEmpty ? 'x' : w.xLabel.split(' (').first} ${fmtNum(best.x, sig: 5)},  '
            '${best.limit ? 'limit ' : ''}${fmtNum(best.y, sig: 4)}'
            '${best.err != null ? ' ± ${fmtNum(best.err, sig: 2)}' : ''}'
            '${best.note != null ? '  ${best.note}' : ''}';
        final t = _tp(label, pal.ink, size: 11, weight: FontWeight.w600);
        final bx = (o.dx + 10 + t.width + 12 > size.width) ? o.dx - 10 - t.width - 12 : o.dx + 10;
        final by = (o.dy - 30).clamp(plot.top, plot.bottom - 24);
        final r = RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, t.width + 12, t.height + 8), const Radius.circular(4));
        canvas.drawRRect(r, Paint()..color = pal.surface);
        canvas.drawRRect(
            r,
            Paint()
              ..color = pal.muted
              ..style = PaintingStyle.stroke);
        t.paint(canvas, Offset(bx + 6, by + 4));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PlotPainter old) => true;
}

/// Histogram of [values] in [bins] bins, as a bar series.
Series histogram(String name, Color color, List<double> values, {int bins = 24, double? lo, double? hi}) {
  final v = values.where((x) => x.isFinite).toList();
  if (v.isEmpty) return Series(name, color, const [], style: SeriesStyle.bars);
  final a = lo ?? v.reduce(math.min), b0 = hi ?? v.reduce(math.max);
  final b = b0 > a ? b0 : a + 1;
  final counts = List.filled(bins, 0);
  for (final x in v) {
    counts[(((x - a) / (b - a)) * bins).floor().clamp(0, bins - 1)]++;
  }
  final step = (b - a) / bins;
  return Series(name, color, [for (var i = 0; i < bins; i++) Pt(a + (i + 0.5) * step, counts[i].toDouble())],
      style: SeriesStyle.bars);
}
