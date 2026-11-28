// v3.39 验收：路网分块索引（.ovrd）的正确性与速度。
//
// 背景：用户反馈"导出 dxf 速度太慢，几乎快要一分钟"。最大一项是路网：
// 旧路径每次导出都要 gzip.decode(10.5MB) + jsonDecode 20.5 万条道路、
// 173 万个坐标点（实测 3~6 秒），而导出面板改档位/重算会反复触发。
//
// 本测试与 Python 侧（tool/build_road_index.py 的生成过程）独立交叉验证：
// 用索引查出来的道路，必须与"直接从源 GeoJSON 里筛"的结果一致。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/road_index.dart';

/// 直接从源 GeoJSON.gz 里筛出与 bbox 相交的道路（旧路径，作为真值）。
///
/// 这是**独立实现**：不复用 road_index.dart 的任何代码，
/// 只按 GeoJSON 语义（[lon, lat] + 外包框相交）比对。
({int count, int named, double totalDeg}) roadsFromGeoJson(
    String path, double lonMin, double latMin, double lonMax, double latMax) {
  final txt = utf8.decode(gzip.decode(File(path).readAsBytesSync()));
  final doc = jsonDecode(txt) as Map<String, dynamic>;
  final feats = (doc['features'] as List).cast<Map<String, dynamic>>();
  var count = 0, named = 0;
  var totalDeg = 0.0;
  for (final f in feats) {
    final geom = f['geometry'];
    if (geom is! Map) continue;
    if (geom['type'] != 'LineString') continue;
    final coords = (geom['coordinates'] as List).cast<List<dynamic>>();
    if (coords.length < 2) continue;
    var lo0 = double.infinity, lo1 = -double.infinity;
    var la0 = double.infinity, la1 = -double.infinity;
    for (final c in coords) {
      final lo = (c[0] as num).toDouble();
      final la = (c[1] as num).toDouble();
      if (lo < lo0) lo0 = lo;
      if (lo > lo1) lo1 = lo;
      if (la < la0) la0 = la;
      if (la > la1) la1 = la;
    }
    // 外包框相交（线要素口径：不能用"顶点在框内"）
    if (lo1 < lonMin || lo0 > lonMax) continue;
    if (la1 < latMin || la0 > latMax) continue;
    count++;
    final name = ((f['properties'] as Map?)?['name'] as String?) ?? '';
    if (name.isNotEmpty) named++;
    totalDeg += (la1 - la0) + (lo1 - lo0);
  }
  return (count: count, named: named, totalDeg: totalDeg);
}

void main() {
  const ovrdPath = 'assets/buildings/xinyang_roads.ovrd';
  const srcPath = 'assets/buildings/xinyang_roads.geojson.gz';

  test('资源登记：索引与回退用的 GeoJSON 都在', () {
    for (final p in const [
      'assets/buildings/xinyang_roads.ovrd',
      'assets/buildings/xinyang_roads.geojson.gz',
    ]) {
      final f = File(p);
      expect(f.existsSync(), isTrue, reason: '缺少 $p');
      expect(f.lengthSync(), greaterThan(1000), reason: '$p 内容异常');
    }
  });

  test('索引解析：魔数/范围/字符串表正确', () {
    final idx = RoadIndex.parse(File(ovrdPath).readAsBytesSync());
    expect(idx, isNotNull, reason: '索引应能解析（魔数 OVRD + 60 字节头）');

    // 覆盖范围应包住信阳（v3.38 数据经度 113.703~115.593、纬度 31.192~32.588）
    expect(idx!.lonMin, closeTo(113.60, 0.02));
    expect(idx.latMin, closeTo(31.10, 0.02));
    expect(idx.lonMax, greaterThan(115.55));
    expect(idx.latMax, greaterThan(32.55));

    // 20.5 万条道路只有约 2000 个不同路名
    expect(idx.nameCount, greaterThan(1500));
    expect(idx.nameCount, lessThan(3000));
  });

  test('解析容错：非索引字节返回 null（调用方回退 GeoJSON）', () {
    expect(RoadIndex.parse(File('pubspec.yaml').readAsBytesSync()), isNull);
    expect(RoadIndex.parse(File(srcPath).readAsBytesSync()), isNull,
        reason: 'gzip 源文件不是 OVRD，必须拒收而不是崩');
  });

  group('查询正确性：与源 GeoJSON 独立比对', () {
    // 三档典型图幅（经纬度窗口，最后一个数是 A3 1:3000 对应约 1260×891m）
    const cases = <(double, double, double, double, String)>[
      (114.05, 32.12, 114.08, 32.14, '羊山新区(~3km)'),
      (114.00, 32.09, 114.03, 32.11, '平桥老城(~3km)'),
      (114.52, 32.19, 114.56, 32.22, '罗山县城(~4km)'),
      (114.060, 32.125, 114.073, 32.133, 'A3 单幅(~1.3km)'),
    ];

    for (final (lo0, la0, lo1, la1, label) in cases) {
      test('$label 条数与源数据一致', () {
        final idx = RoadIndex.parse(File(ovrdPath).readAsBytesSync())!;
        final fromIdx = idx.query(lo0, la0, lo1, la1);
        final fromSrc = roadsFromGeoJson(srcPath, lo0, la0, lo1, la1);

        // 索引坐标是 1e-7° 定点（0.011m），与源 double 相比在**外包框边缘**
        // 可能有极个别路因四舍五入跨线，故允许 2% 的抖动（实测 0 差异）。
        final diff = (fromIdx.length - fromSrc.count).abs();
        final tol = fromSrc.count * 0.02 + 2;
        expect(diff, lessThanOrEqualTo(tol),
            reason: '$label：索引 ${fromIdx.length} 条 vs 源 ${fromSrc.count} 条');
        expect(fromIdx.length, greaterThan(50), reason: '$label 应有足量道路');

        // 坐标口径：pts 必须是 [lat, lon]（与 BundledRoad 一致）
        for (final r in fromIdx.take(30)) {
          expect(r.pts.length, greaterThanOrEqualTo(2));
          for (final p in r.pts) {
            expect(p[0], inInclusiveRange(31.0, 33.0), reason: '第一分量应是纬度');
            expect(p[1], inInclusiveRange(113.0, 116.0), reason: '第二分量应是经度');
          }
          expect(r.rid, greaterThanOrEqualTo(0));
        }
      });
    }

    test('跨格长路不重复、不漏（rid 全局唯一）', () {
      final idx = RoadIndex.parse(File(ovrdPath).readAsBytesSync())!;
      // 大范围必然跨多格，跨格的路在相邻块各存一份，必须靠 rid 去重
      final roads = idx.query(113.80, 31.30, 115.50, 32.50);
      final rids = <int>{};
      for (final r in roads) {
        expect(rids.add(r.rid), isTrue, reason: 'rid ${r.rid} 出现两次，去重失效');
      }
      expect(roads.length, greaterThan(100000), reason: '全市应有 10 万条以上');
    });
  });

  test('查询速度：单幅 A3 应在几十毫秒内（旧路径 3~6 秒）', () {
    final idx = RoadIndex.parse(File(ovrdPath).readAsBytesSync())!;
    // 预热（首次要解压命中块）
    idx.query(114.05, 32.12, 114.08, 32.14);

    final st = Stopwatch()..start();
    const n = 5;
    for (var i = 0; i < n; i++) {
      // 略换 bbox，避免完全命中同一批缓存块
      idx.query(114.05 + i * 0.001, 32.12, 114.08 + i * 0.001, 32.14);
    }
    final ms = st.elapsedMilliseconds / n;
    // ignore: avoid_print
    print('单幅 A3 平均 ${ms.toStringAsFixed(1)} ms/次（旧路径 3000~6000 ms）');
    expect(ms, lessThan(200), reason: '应远快于旧路径的 3~6 秒');
  });

  test('范围外查询返回空（不误报数据）', () {
    final idx = RoadIndex.parse(File(ovrdPath).readAsBytesSync())!;
    expect(idx.query(120.0, 40.0, 121.0, 41.0), isEmpty);
    // 覆盖范围内但确实没有内置路网的格子（信阳辖区外西北角）
    expect(idx.query(113.62, 31.12, 113.66, 31.15), isEmpty);
  });
}
