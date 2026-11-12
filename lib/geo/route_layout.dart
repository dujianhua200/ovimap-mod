import 'dart:math' as math;

/// 等距自动布杆纯算法（不依赖 Flutter，可单测）。
///
/// 口径：给定起止两点与平均档距，沿两点连线等距落杆；
/// **含起点**，按 [spacingM] 递推，并**含终点**（末段不足一档时以终点收尾），
/// 保证 `杆数 = ceil(总长/spacingM) + 1` 且首=起点、末=终点。
/// 本迭代仅支持直线两点，不支持折线。
class RouteLayout {
  RouteLayout._();

  /// 地球平均半径（米），与 `GeoUtil`/`CsvExporter` 口径一致。
  static const double earthR = 6371000.0;

  static double _rad(double deg) => deg * math.pi / 180.0;

  /// 起点到终点的初始方位角（度，0=正北，顺时针）。
  static double bearingDeg(double la1, double lo1, double la2, double lo2) {
    final phi1 = _rad(la1);
    final phi2 = _rad(la2);
    final dLon = _rad(lo2 - lo1);
    final y = math.sin(dLon) * math.cos(phi2);
    final x = math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(dLon);
    final theta = math.atan2(y, x);
    return (theta * 180.0 / math.pi + 360.0) % 360.0;
  }

  /// 从 (lat, lon) 沿方位角 [brgDeg] 前进 [distM] 米后的坐标 → [lat, lon]。
  static List<double> destination(
      double lat, double lon, double brgDeg, double distM) {
    final delta = distM / earthR;
    final theta = _rad(brgDeg);
    final phi1 = _rad(lat);
    final lambda1 = _rad(lon);
    final sinPhi2 = math.sin(phi1) * math.cos(delta) +
        math.cos(phi1) * math.sin(delta) * math.cos(theta);
    final phi2 = math.asin(sinPhi2.clamp(-1.0, 1.0));
    final lambda2 = lambda1 +
        math.atan2(
            math.sin(theta) * math.sin(delta) * math.cos(phi1),
            math.cos(delta) - math.sin(phi1) * sinPhi2);
    final lat2 = phi2 * 180.0 / math.pi;
    final lon2 = (lambda2 * 180.0 / math.pi + 540.0) % 360.0 - 180.0;
    return [lat2, lon2];
  }

  /// 等距布杆：返回 `[[lat, lon], ...]`，长度 = 杆数。
  ///
  /// · 含起点 `[startLat, startLon]`；
  /// · 按 [spacingM] 递推落点；
  /// · [includeEnd] 为 true 时以终点 `[endLat, endLon]` 收尾（末段不足一档也补齐），
  ///   杆数 = `ceil(总长/spacingM) + 1`；为 false 时仅含间距内的落点
  ///   （不含终点），杆数 = `ceil(总长/spacingM)`。
  /// · 起止重合（总长为 0）时返回起点单点。
  static List<List<double>> autoPoles({
    required double startLat,
    required double startLon,
    required double endLat,
    required double endLon,
    required double spacingM,
    bool includeEnd = true,
  }) {
    // 防御 NaN / Infinity / 非正档距：统一兜底为默认 50m（避免 NaN.ceil() 抛异常）。
    if (!spacingM.isFinite || spacingM <= 0) spacingM = 50.0;
    final total = haversineM(startLat, startLon, endLat, endLon);
    if (total < 1e-6) {
      return [
        [startLat, startLon]
      ];
    }
    final intervals = (total / spacingM).ceil();
    final count = includeEnd ? intervals + 1 : intervals;
    if (count <= 0) {
      return [
        [startLat, startLon]
      ];
    }
    final bearing = bearingDeg(startLat, startLon, endLat, endLon);
    final out = <List<double>>[];
    for (var i = 0; i < count; i++) {
      // 末点（或超出总长）直接落在终点，保证首=起点、末=终点。
      if (i == count - 1 && includeEnd) {
        out.add([endLat, endLon]);
        break;
      }
      final d = i * spacingM;
      if (d >= total) {
        out.add([endLat, endLon]);
      } else {
        out.add(destination(startLat, startLon, bearing, d));
      }
    }
    return out;
  }

  /// 两点大圆距离（米），与 `GeoUtil.haversine` 口径一致。
  static double haversineM(
      double la1, double lo1, double la2, double lo2) {
    final dLat = _rad(la2 - la1);
    final dLon = _rad(lo2 - lo1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(la1)) *
            math.cos(_rad(la2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return earthR * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}
