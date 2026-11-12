import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/csv.dart';
import 'package:ovimap/geo/geo_util.dart';
import 'package:ovimap/models/diff_report.dart';
import 'package:ovimap/models/map_label.dart';

void main() {
  List<MapLabel> design() => [
        MapLabel(
            typeId: 'pipe',
            seq: 1,
            lat: 32.0,
            lon: 114.0,
            name: 'GK-1',
            lineGroupId: 'g',
            distLabel: '100'),
        MapLabel(
            typeId: 'pipe',
            seq: 2,
            lat: 32.001,
            lon: 114.0,
            name: 'GK-2',
            lineGroupId: 'g',
            distLabel: '100'),
        MapLabel(
            typeId: 'pipe',
            seq: 3,
            lat: 32.002,
            lon: 114.0,
            name: 'GK-3',
            lineGroupId: 'g'),
      ];

  List<MapLabel> completion() => [
        // 一致
        MapLabel(
            typeId: 'pipe',
            seq: 1,
            lat: 32.0,
            lon: 114.0,
            name: 'GK-1',
            lineGroupId: 'g',
            distLabel: '100'),
        // 偏移（≈11m > 1m）
        MapLabel(
            typeId: 'pipe',
            seq: 2,
            lat: 32.0011,
            lon: 114.0,
            name: 'GK-2',
            lineGroupId: 'g',
            distLabel: '100'),
        // 新增
        MapLabel(
            typeId: 'pipe',
            seq: 4,
            lat: 32.003,
            lon: 114.0,
            name: 'GK-4',
            lineGroupId: 'g',
            distLabel: '120'),
      ];

  test('buildDesignDiff：增/删/偏移/一致 计数正确', () {
    final r = CsvExporter.buildDesignDiff(design(), completion());
    final s = r.summary;
    expect(s.added, 1, reason: 'GK-4 新增');
    expect(s.removed, 1, reason: 'GK-3 缺失');
    expect(s.moved, 1, reason: 'GK-2 偏移');
    expect(s.kept, 1, reason: 'GK-1 一致');
    expect(r.changedPoles.length, 3);
  });

  test('buildDesignDiff：偏移阈值生效', () {
    final r1 = CsvExporter.buildDesignDiff(design(), completion(),
        offsetThreshold: 1.0);
    expect(r1.summary.moved, 1);

    final r2 = CsvExporter.buildDesignDiff(design(), completion(),
        offsetThreshold: 1000.0);
    expect(r2.summary.moved, 0);
    expect(r2.summary.kept, 2, reason: '放大阈值后 GK-2 视为一致');
  });

  test('buildDesignDiff：段距对照 + 净长度差合理', () {
    final r = CsvExporter.buildDesignDiff(design(), completion());
    expect(r.segs.any((s) => s.seg == 'GK-1>GK-2'), isTrue);
    final seg = r.segs.firstWhere((s) => s.seg == 'GK-1>GK-2');
    expect(seg.designM, closeTo(100, 1e-6));
    expect(seg.compM, closeTo(100, 1e-6));
    expect(seg.deltaM, closeTo(0, 1e-6));
    // 净长度差 = 竣工总段距 − 设计总段距（不含盘留）
    // 设计 = 100(GK-1>GK-2) + haversine(GK-2>GK-3)；竣工 = 100 + 120(GK-2>GK-4)
    final designTotal = 100.0 +
        GeoUtil.haversine(32.001, 114.0, 32.002, 114.0);
    expect(r.summary.netLenDiffM, closeTo(220.0 - designTotal, 0.5));
  });

  test('buildDesignDiff：无同名相邻杆段时给出备注', () {
    final r = CsvExporter.buildDesignDiff(
      [
        MapLabel(typeId: 'pipe', lat: 32.0, lon: 114.0, name: 'A', lineGroupId: 'g'),
        MapLabel(typeId: 'pipe', lat: 32.001, lon: 114.0, name: 'B', lineGroupId: 'g'),
      ],
      [
        MapLabel(typeId: 'pipe', lat: 32.0, lon: 114.0, name: 'C', lineGroupId: 'g'),
        MapLabel(typeId: 'pipe', lat: 32.001, lon: 114.0, name: 'D', lineGroupId: 'g'),
      ],
    );
    expect(r.segs, isEmpty);
    expect(r.notes, isNotEmpty);
  });

  test('DiffReport：changedPoles 过滤掉一致项', () {
    final r = CsvExporter.buildDesignDiff(design(), completion());
    expect(r.poles.length, 4);
    expect(r.changedPoles.every((p) => p.status != DiffStatus.same), isTrue);
  });
}
