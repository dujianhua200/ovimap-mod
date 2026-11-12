import 'dart:math' as math;

import '../models/map_label.dart';

/// 轨迹核查结果。
class TrackCheckResult {
  /// 参与核查的杆数。
  final int poleCount;

  /// 轨迹总长（米）。
  final double trackLen;

  /// 每杆到轨迹的平均偏移（米）。
  final double avgOffset;

  /// 超过阈值的杆（按偏移从大到小）：(杆, 偏移米)。
  final List<(MapLabel, double)> outliers;

  /// 阈值（米）。
  final double threshold;

  const TrackCheckResult(this.poleCount, this.trackLen, this.avgOffset,
      this.outliers, this.threshold);
}

/// 轨迹 vs 杆路偏移检测（他们没有的自查利器）：
/// 现场沿设计杆路走一遍并记录轨迹，本工具逐杆计算杆位到轨迹折线的
/// 最近距离——偏移超阈值的杆即"可能漏杆/错位/走了别处的路"，一目了然。
class TrackChecker {
  TrackChecker._();

  /// 默认阈值 30 米：GPS 民用误差 + 走路偏离杆位的合理余量。
  static TrackCheckResult check(List<MapLabel> trackPts, List<MapLabel> poles,
      {double threshold = 30}) {
    // 轨迹总长
    var trackLen = 0.0;
    for (var i = 1; i < trackPts.length; i++) {
      trackLen += _hav(trackPts[i - 1], trackPts[i]);
    }
    if (trackPts.length < 2 || poles.isEmpty) {
      return TrackCheckResult(poles.length, trackLen, 0, const [], threshold);
    }

    // 每杆到轨迹折线各段的最近距离
    final outliers = <(MapLabel, double)>[];
    var sum = 0.0;
    for (final p in poles) {
      var best = double.infinity;
      for (var i = 1; i < trackPts.length; i++) {
        final d = _pointToSegMeters(p, trackPts[i - 1], trackPts[i]);
        if (d < best) best = d;
      }
      if (best == double.infinity) best = 0;
      sum += best;
      if (best > threshold) outliers.add((p, best));
    }
    outliers.sort((a, b) => b.$2.compareTo(a.$2));
    return TrackCheckResult(
        poles.length, trackLen, sum / poles.length, outliers, threshold);
  }

  /// 点到线段的最近距离（米）。用以线段中点为基准的等距圆柱近似，
  /// 杆路场景跨度小（数百米级），精度足够。
  static double _pointToSegMeters(MapLabel p, MapLabel a, MapLabel b) {
    final cosLat = math.cos(((a.lat + b.lat) / 2) * math.pi / 180);
    double toX(MapLabel l) => (l.lon - a.lon) * 111320 * cosLat;
    double toY(MapLabel l) => (l.lat - a.lat) * 110540;
    final px = toX(p), py = toY(p);
    final ax = 0.0, ay = 0.0; // a 为原点
    final bx = toX(b), by = toY(b);
    final dx = bx - ax, dy = by - ay;
    final segLen2 = dx * dx + dy * dy;
    if (segLen2 < 1e-9) {
      return math.sqrt(px * px + py * py);
    }
    var t = (px * dx + py * dy) / segLen2;
    t = t.clamp(0.0, 1.0);
    final cx = ax + dx * t, cy = ay + dy * t;
    return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
  }

  static double _hav(MapLabel a, MapLabel b) {
    const r = 6371000.0;
    final dLat = (b.lat - a.lat) * math.pi / 180;
    final dLon = (b.lon - a.lon) * math.pi / 180;
    final s = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.lat * math.pi / 180) *
            math.cos(b.lat * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return 2 * r * math.asin(math.sqrt(s));
  }
}
