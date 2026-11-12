// 道路几何裁剪护栏（v3.9.2，用户反馈「导出的矢量图路超级长」）。
//
// 旧实现：任一点在 bbox 内 → **整条路保留**，于是横穿县城的国道只要蹭到
// 100m 范围就被整条（数十公里）写进 DXF。现在按边界截断，只留附近一段。
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/models/map_label.dart';

double _len(List<List<double>> pts) {
  var s = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final dLat = (pts[i][0] - pts[i - 1][0]) * 110540.0;
    final dLon = (pts[i][1] - pts[i - 1][1]) * 111320.0 * 0.848; // cos(32°)
    s += sqrt(dLat * dLat + dLon * dLon);
  }
  return s;
}

void main() {
  test('超长道路：只保留 bbox 附近那一段，长度被大幅截断', () {
    final labels = [
      MapLabel(typeId: 'pipe', seq: 1, lat: 32.130, lon: 114.081),
      MapLabel(typeId: 'pipe', seq: 2, lat: 32.1305, lon: 114.0815),
    ];
    final bbox = BasemapFetcher.boundsOf(labels, 100); // ±100m

    // 一条自西南很远处斜穿到东北很远处的国道（只有中段经过线路旁）。
    final long = <List<double>>[
      [32.00, 114.00],
      [32.10, 114.05],
      [32.130, 114.081],
      [32.20, 114.15],
      [32.40, 114.30],
    ];
    final road = RoadPoly(long, RoadGrade.primary, '国道G107');
    final out = BasemapFetcher.cropRoadsToBbox([road], bbox);

    final inLen = _len(out.fold(<List<double>>[], (a, r) => a..addAll(r.pts)));
    // 原路长度（整条超 100km）。
    final srcLenKm = 40.0; // 量级：32.00→32.40 纬度跨度 ≈ 44km
    expect(out, isNotEmpty, reason: '经过线路旁的路必须保留一段');
    expect(inLen < 1000, isTrue,
        reason: '裁剪后应只剩公里级以内的片段（实测 $inLen m），'
            '整条 $srcLenKm km 已不复存在');
  });

  test('完全在框外的道路：整条丢弃（不为 0 长度也不留残点）', () {
    final labels = [
      MapLabel(typeId: 'pipe', seq: 1, lat: 32.130, lon: 114.081),
    ];
    final bbox = BasemapFetcher.boundsOf(labels, 100);
    final far = RoadPoly([
      [33.0, 115.0],
      [33.5, 115.5],
    ], RoadGrade.primary, '远处高速');
    expect(BasemapFetcher.cropRoadsToBbox([far], bbox), isEmpty);
  });

// ---------- 沿线路缓冲（v3.9.3）：矩形包围盒 vs 沿轨迹 ----------
  test('L 形线路：包围盒角落（离线路很远）必须被排除，只留沿轨迹一段', () {
    // L 形线路：先向北 500m，再向东 500m。
    final labels = [
      MapLabel(typeId: 'pipe', seq: 1, lat: 32.130, lon: 114.081, lineGroupId: 'g'),
      MapLabel(typeId: 'pipe', seq: 2, lat: 32.1345, lon: 114.081, lineGroupId: 'g'),
      MapLabel(typeId: 'pipe', seq: 3, lat: 32.1345, lon: 114.086, lineGroupId: 'g'),
    ];
    // 包围盒的西北角：离两段线路都很远（约 350m+），但**在矩形框内**。
    final cornerLat = 32.1302, cornerLon = 114.0858;
    final nearLat = 32.1301, nearLon = 114.0811; // 紧贴第一段

    final dCorner = BasemapFetcher.distToRouteM(labels, cornerLat, cornerLon);
    final dNear = BasemapFetcher.distToRouteM(labels, nearLat, nearLon);

    expect(dNear < 50, isTrue, reason: '轨迹旁的点应在 50m 内（实测 ${dNear}m）');
    expect(dCorner > 300, isTrue,
        reason: 'L 形包围盒西北角离线路应很远（实测 ${dCorner}m）——'
            '这正是"矩形包围盒太广"的证据，必须被缓冲裁剪掉');
  });

  test('道路按沿线路缓冲裁剪：远离轨迹的路段丢弃', () {
    final labels = [
      MapLabel(typeId: 'pipe', seq: 1, lat: 32.130, lon: 114.081, lineGroupId: 'g'),
      MapLabel(typeId: 'pipe', seq: 2, lat: 32.1305, lon: 114.081, lineGroupId: 'g'),
    ];
    // 与线路平行、但横向偏 800m 的一条路（在矩形包围盒 ±100m 内？不在——
    // 这里用 ±1km 的 bbox 概念验证"缓冲带"才是对的）。
    final far = RoadPoly([
      [32.1300, 114.0900],
      [32.1305, 114.0900],
    ], RoadGrade.primary, '平行远路');
    final near = RoadPoly([
      [32.1300, 114.0811],
      [32.1305, 114.0811],
    ], RoadGrade.primary, '贴线路的路');

    final out = BasemapFetcher.cropRoadsToRoute([far, near], labels, 50);
    expect(out.length, 1, reason: '只留沿轨迹 50m 内那条');
    expect(out.first.name, '贴线路的路');
  });
}
