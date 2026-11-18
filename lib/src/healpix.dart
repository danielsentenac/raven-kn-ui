/// HEALPix NESTED pixel of a sky position, and the sky projections of the map view.
library;

import 'dart:math' as math;

const double _twoThird = 2.0 / 3.0;

int _spread(int v) {
  // interleave the bits of v with zeros (v < 2^15)
  v &= 0xFFFF;
  v = (v | (v << 8)) & 0x00FF00FF;
  v = (v | (v << 4)) & 0x0F0F0F0F;
  v = (v | (v << 2)) & 0x33333333;
  v = (v | (v << 1)) & 0x55555555;
  return v;
}

/// NESTED pixel index at resolution [order] (nside = 2^order) of (ra, dec) in degrees.
int ang2pixNest(int order, double raDeg, double decDeg) {
  final nside = 1 << order;
  final z = math.sin(decDeg * math.pi / 180);
  final za = z.abs();
  var phi = (raDeg % 360) * math.pi / 180;
  if (phi < 0) phi += 2 * math.pi;
  var tt = phi / (math.pi / 2);
  if (tt >= 4) tt -= 4;
  int face, ix, iy;
  if (za <= _twoThird) {
    final t1 = nside * (0.5 + tt);
    final t2 = nside * z * 0.75;
    final jp = (t1 - t2).floor();
    final jm = (t1 + t2).floor();
    final ifp = jp >> order;
    final ifm = jm >> order;
    face = ifp == ifm ? (ifp | 4) : (ifp < ifm ? ifp : ifm + 8);
    ix = jm & (nside - 1);
    iy = nside - (jp & (nside - 1)) - 1;
  } else {
    final ntt = math.min(3, tt.floor());
    final tp = tt - ntt;
    final tmp = nside * math.sqrt(3 * (1 - za));
    final jp = math.min((tp * tmp).floor(), nside - 1);
    final jm = math.min(((1 - tp) * tmp).floor(), nside - 1);
    if (z >= 0) {
      face = ntt;
      ix = nside - jm - 1;
      iy = nside - jp - 1;
    } else {
      face = ntt + 8;
      ix = jp;
      iy = jm;
    }
  }
  return face * nside * nside + (_spread(ix) | (_spread(iy) << 1));
}

/// Angular separation in degrees.
double separationDeg(double ra1, double dec1, double ra2, double dec2) {
  const d = math.pi / 180;
  final a = math.sin((dec2 - dec1) * d / 2);
  final b = math.sin((ra2 - ra1) * d / 2);
  final h = a * a + math.cos(dec1 * d) * math.cos(dec2 * d) * b * b;
  return 2 * math.asin(math.min(1, math.sqrt(h))) / d;
}

/// Point at angular distance [rDeg] and position angle [paDeg] from (ra, dec).
(double, double) offsetBy(double raDeg, double decDeg, double rDeg, double paDeg) {
  const d = math.pi / 180;
  final dec = decDeg * d, r = rDeg * d, pa = paDeg * d;
  final sinDec2 = math.sin(dec) * math.cos(r) + math.cos(dec) * math.sin(r) * math.cos(pa);
  final dec2 = math.asin(sinDec2.clamp(-1.0, 1.0));
  final y = math.sin(pa) * math.sin(r) * math.cos(dec);
  final x = math.cos(r) - math.sin(dec) * sinDec2;
  return ((raDeg + math.atan2(y, x) / d) % 360, dec2 / d);
}

/// A sky projection onto the unit rectangle x, y in [-1, 1] (x to the right, y up).
abstract class SkyProjection {
  /// (x, y) of a position, or null if it is not on the visible side.
  (double, double)? forward(double raDeg, double decDeg);

  /// (ra, dec) of a point, or null outside the map.
  (double, double)? inverse(double x, double y);

  double get aspect; // width / height of the map
}

/// All-sky Mollweide, RA increasing to the left, centred on [ra0].
class Mollweide implements SkyProjection {
  Mollweide({this.ra0 = 180});
  final double ra0;
  @override
  double get aspect => 2;

  @override
  (double, double)? forward(double raDeg, double decDeg) {
    final lat = decDeg * math.pi / 180;
    var lon = ((raDeg - ra0 + 540) % 360) - 180; // -180..180
    var t = lat;
    if (lat.abs() < math.pi / 2 - 1e-9) {
      for (var i = 0; i < 12; i++) {
        final dt = (2 * t + math.sin(2 * t) - math.pi * math.sin(lat)) / (2 + 2 * math.cos(2 * t));
        t -= dt;
        if (dt.abs() < 1e-9) break;
      }
    }
    return (-lon / 180 * math.cos(t), math.sin(t));
  }

  @override
  (double, double)? inverse(double x, double y) {
    if (y.abs() > 1) return null;
    final t = math.asin(y);
    final c = math.cos(t);
    if (c.abs() < 1e-12) return x.abs() < 1e-6 ? (ra0, y > 0 ? 90.0 : -90.0) : null;
    final lon = -x / c * 180;
    if (lon.abs() > 180) return null;
    final lat = math.asin(((2 * t + math.sin(2 * t)) / math.pi).clamp(-1.0, 1.0));
    return ((lon + ra0) % 360, lat * 180 / math.pi);
  }
}

/// Azimuthal equidistant view of radius [radiusDeg] around (ra0, dec0), east to the left.
class ZoomView implements SkyProjection {
  ZoomView(this.ra0, this.dec0, this.radiusDeg);
  final double ra0, dec0, radiusDeg;
  @override
  double get aspect => 1;

  @override
  (double, double)? forward(double raDeg, double decDeg) {
    const d = math.pi / 180;
    final r = separationDeg(ra0, dec0, raDeg, decDeg);
    if (r > radiusDeg * 1.5 || r > 179) return null;
    if (r < 1e-12) return (0, 0);
    final dra = (raDeg - ra0) * d;
    final pa = math.atan2(math.sin(dra) * math.cos(decDeg * d),
        math.cos(dec0 * d) * math.sin(decDeg * d) - math.sin(dec0 * d) * math.cos(decDeg * d) * math.cos(dra));
    return (-r / radiusDeg * math.sin(pa), r / radiusDeg * math.cos(pa));
  }

  @override
  (double, double)? inverse(double x, double y) {
    final r = math.sqrt(x * x + y * y) * radiusDeg;
    if (r > 179) return null;
    final pa = math.atan2(-x, y) * 180 / math.pi;
    return offsetBy(ra0, dec0, r, pa);
  }
}
