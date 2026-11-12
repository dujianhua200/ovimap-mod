// E1 工程统计：computeProjectStats 数据正确性 + 与「材料统计 CSV」口径对拍。
// 纯 Dart、零网络；段距全部用人工确认值（distLabel/distanceM），不依赖 haversine 数值。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/csv.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/ui/desktop/stats_section.dart';

final store = LabelStore.instance;

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_stats');
    store.setBaseDirForTest(dir);
  });

  tearDown(() {
    AppPaths.clearForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 已知数据：
  /// 链 g1：p1 →(distLabel=100, 管道, 48芯GYTS)→ p2 →(distanceM=250, 架空, 24芯GYTA)→ p3
  /// p4 为独立箱体（不入链，计入点位总数）。
  List<MapLabel> knownLabels() => [
        MapLabel(
            typeId: 'pipe', seq: 1, lat: 32.0, lon: 114.0, lineGroupId: 'g1'),
        MapLabel(
          typeId: 'pipe',
          seq: 2,
          lat: 32.0,
          lon: 114.001,
          lineGroupId: 'g1',
          distLabel: '100', // 段 p1→p2 = 100（人工确认，优先级最高）
          segKind: 3, // 管道
          segCable: '48芯GYTS',
        ),
        MapLabel(
          typeId: 'pipe',
          seq: 3,
          lat: 32.0,
          lon: 114.002,
          lineGroupId: 'g1',
          distanceM: 250, // 段 p2→p3 = 250
          segKind: 1, // 架空
          segCable: ' 24芯GYTA ', // 带空白：统计前应 trim
          slackM: 5,
        ),
        MapLabel(typeId: 'splitterbox', seq: 4, lat: 32.1, lon: 114.0),
      ];

  test('已知数据：总数/段数/总距离/盘留/敷设方式/型号 全部正确', () {
    final s = computeProjectStats(knownLabels());

    expect(s.pointCount, 4, reason: '点位总数含独立箱体');
    expect(s.segCount, 2, reason: '链上相邻点对');
    expect(s.totalLenM, 350.0, reason: '100 + 250（不含盘留）');
    expect(s.slackTotalM, 5.0);

    // 敷设方式分布（段取后点）
    expect(s.byKind.length, 2);
    expect(s.byKind[3]!.lenM, 100.0, reason: '管道段 = p1→p2');
    expect(s.byKind[3]!.segs, 1);
    expect(s.byKind[1]!.lenM, 250.0, reason: '架空段 = p2→p3');
    expect(s.byKind[1]!.segs, 1);

    // 光缆型号汇总（trim 后归并）
    expect(s.cableLenM.length, 2);
    expect(s.cableLenM['48芯GYTS'], 100.0);
    expect(s.cableLenM['24芯GYTA'], 250.0);
  });

  test('段距口径：distLabel 优先于 distanceM，二者皆无时用 haversine', () {
    final a = MapLabel(typeId: 'pipe', lat: 32.0, lon: 114.0);
    // distLabel 优先
    final b1 = MapLabel(
        typeId: 'pipe', lat: 32.0, lon: 114.001, distLabel: '77', distanceM: 999);
    expect(statsSegDist(a, b1), 77.0);
    // 无 distLabel → distanceM
    final b2 = MapLabel(typeId: 'pipe', lat: 32.0, lon: 114.001, distanceM: 888);
    expect(statsSegDist(a, b2), 888.0);
    // 都没有 → haversine（约 105m，与人工值明显区分即可）
    final b3 = MapLabel(typeId: 'pipe', lat: 32.0, lon: 114.001);
    final d3 = statsSegDist(a, b3);
    expect(d3, greaterThan(90000 * 0.001));
    expect(d3, lessThan(120000 * 0.001));
  });

  test('与「材料统计 CSV」口径一致：合计行数值 == totalLenM', () async {
    final labels = knownLabels();
    final s = computeProjectStats(labels);
    final f = await CsvExporter.exportMaterialStats('统计对拍', labels);
    final text = f.readAsStringSync();
    expect(text.contains('合计,${s.totalLenM.toStringAsFixed(1)},${s.segCount}'),
        isTrue,
        reason: '统计面板总距离/段数须与材料统计 CSV 完全一致');
    expect(text.contains('48芯GYTS'), isTrue);
    expect(text.contains('24芯GYTA'), isTrue);
  });

  test('空工程 / 无链（全是独立点）→ 全零，不抛', () {
    final empty = computeProjectStats(const []);
    expect(empty.pointCount, 0);
    expect(empty.segCount, 0);
    expect(empty.totalLenM, 0.0);

    final onlyBoxes = computeProjectStats([
      MapLabel(typeId: 'splitterbox', lat: 32.0, lon: 114.0),
    ]);
    expect(onlyBoxes.pointCount, 1);
    expect(onlyBoxes.segCount, 0, reason: '独立点不成链');
    expect(onlyBoxes.byKind, isEmpty);
  });
}
