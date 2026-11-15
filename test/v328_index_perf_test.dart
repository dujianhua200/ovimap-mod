// v3.28 验收：分块索引的速度与正确性。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/building_index.dart';

void main() {
  test('索引解析与查询正确', () {
    final bytes = File('assets/buildings/xinyang.ovbld').readAsBytesSync();
    final idx = BuildingIndex.parse(bytes);
    expect(idx, isNotNull, reason: '索引应能解析');

    // 覆盖范围应与信阳 bbox 相符
    expect(idx!.lonMin, closeTo(113.60, 0.05));
    expect(idx.lonMax, closeTo(115.72, 0.05));
    expect(idx.latMin, closeTo(31.10, 0.05));
    expect(idx.latMax, closeTo(32.80, 0.05));

    // ignore: avoid_print
    print('范围 ${idx.lonMin.toStringAsFixed(2)}~'
        '${idx.lonMax.toStringAsFixed(2)}E, '
        '${idx.latMin.toStringAsFixed(2)}~${idx.latMax.toStringAsFixed(2)}N');

    // 各范围的环数（与 Python 侧独立统计交叉验证）
    const cases = [
      (114.30, 32.10, 114.50, 32.25, '中等(~20km)', 20000),
      (114.35, 32.15, 114.40, 32.20, '小(~5km)', 2500),
    ];
    for (final (lo0, la0, lo1, la1, name, expectAtLeast) in cases) {
      final rings = idx.query(lo0, la0, lo1, la1);
      // ignore: avoid_print
      print('$name: ${rings.length} 环');
      expect(rings.length, greaterThan(expectAtLeast),
          reason: '$name 应有足够建筑');

      // 每个环格式正确：至少 3 点，每点 [lon, lat] 且落在合理范围
      for (final r in rings.take(50)) {
        expect(r.length, greaterThanOrEqualTo(3));
        for (final p in r) {
          expect(p.length, 2);
          expect(p[0], inInclusiveRange(113.5, 115.8));
          expect(p[1], inInclusiveRange(31.0, 32.9));
        }
      }
    }

    // 范围外应返回空
    expect(idx.query(120.0, 40.0, 121.0, 41.0), isEmpty);
  });

  test('查询速度远快于旧的 15 秒', () {
    final idx =
        BuildingIndex.parse(File('assets/buildings/xinyang.ovbld').readAsBytesSync())!;
    // 预热
    idx.query(114.30, 32.10, 114.50, 32.25);

    final st = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      idx.query(114.30, 32.10, 114.50, 32.25);
    }
    final ms = st.elapsedMilliseconds / 5;
    // ignore: avoid_print
    print('中等范围平均 ${ms.toStringAsFixed(1)} ms/次（旧路径 15149 ms）');
    expect(ms, lessThan(500), reason: '应远快于旧的 15 秒');
  });
}
