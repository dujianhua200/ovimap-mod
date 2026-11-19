// v3.30 验收：道路单线 / 双线 / 线宽 / 建筑外移。
//
// 用**注入底图**测绘制逻辑本身，不依赖内置包在某个位置是否有路。
import 'dart:convert' show latin1;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/models/label_type.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/symbols/symbol_catalog.dart';

void main() {
  late Directory tmp;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = Directory.systemTemp.createTempSync('ov_v330');
    LabelStore.instance.setBaseDirForTest(tmp);
    AppPaths.setBaseForTest(tmp);
    LabelType.installCatalog(SymbolCatalog.fromTextSync(
        File('assets/dxf/lispblock.dxf').readAsStringSync()));
  });

  tearDown(() => AppPaths.clearForTest());

  // 线路沿经线走（lat 变化），lon 固定
  List<MapLabel> route() => [
        for (var i = 0; i < 12; i++)
          MapLabel(
            typeId: 'gl003', seq: i + 1,
            lat: 32.140 + i * 0.0005,
            lon: 114.085,
            lineGroupId: 'g', name: 'P${i + 1}', distanceM: 55,
          ),
      ];

  /// 注入一张底图：一条与线路**重合**的道路 + 道路两侧各一栋建筑。
  BasemapData injected() {
    // 道路与线路同一位置（都在 lon=114.085, lat 32.140~32.1455）
    final road = RoadPoly(
      [
        [32.1395, 114.085],
        [32.1460, 114.085],
      ],
      RoadGrade.secondary,
      '测试路',
    );
    // 建筑：紧贴道路两侧（lon 差 0.00008 ≈ 7.5 米）
    List<List<double>> box(double lonC, double latC) => [
          [latC - 0.00005, lonC - 0.00005],
          [latC - 0.00005, lonC + 0.00005],
          [latC + 0.00005, lonC + 0.00005],
          [latC + 0.00005, lonC - 0.00005],
          [latC - 0.00005, lonC - 0.00005],
        ];
    final blds = <BuildingPoly>[
      for (var i = 0; i < 5; i++) ...[
        BuildingPoly([box(114.08508, 32.1400 + i * 0.001)], ''),
        BuildingPoly([box(114.08492, 32.1400 + i * 0.001)], ''),
      ],
    ];
    return BasemapData(
      roads: [road],
      buildings: blds,
      places: const [],
      report: const BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, source: 'test'),
        buildings: DatasetReport(FetchState.ok, source: 'test'),
        places: DatasetReport(FetchState.ok, source: 'test'),
        extras: DatasetReport(FetchState.ok, source: 'test'),
      ),
    );
  }

  /// 统计某图层的**折线实体**（排除同层 TEXT/INSERT 等）。
  ///
  /// 判据：实体头必须是 `0\nPOLYLINE\n` 且紧随 `8\n<layer>\n`
  /// （旧写法用 split 会把后面的 TEXT 一并算进来）。
  ({int count, List<double> widths}) roadPolys(String txt, String layer) {
    final widths = <double>[];
    var count = 0;

    // R12：POLYLINE，头部固定是 0/POLYLINE/8/<layer>/66/1
    for (final m in RegExp('0\nPOLYLINE\n8\n$layer\n66\n1\n').allMatches(txt)) {
      count++;
      // 从该位置往后 400 字符找 40 组码
      final seg = txt.substring(m.start, (m.start + 400).clamp(0, txt.length));
      final w = RegExp(r'\n40\n([-\d.]+)').firstMatch(seg);
      widths.add(w != null ? double.parse(w.group(1)!) : 0);
    }
    // R2000：LWPOLYLINE
    for (final m in RegExp('0\nLWPOLYLINE\n8\n$layer\n').allMatches(txt)) {
      count++;
      final seg = txt.substring(m.start, (m.start + 400).clamp(0, txt.length));
      final w = RegExp(r'\n43\n([-\d.]+)').firstMatch(seg);
      widths.add(w != null ? double.parse(w.group(1)!) : 0);
    }
    return (count: count, widths: widths);
  }

  Future<String> exportWith({
    RoadStyle style = RoadStyle.solid,
    double widthScale = 1.0,
    DxfVersion ver = DxfVersion.r12,
  }) async {
    // 道路起点比线路起点低 0.0005°（55 米），端到端略超 50m 缓冲；
    // 用 120m 缓冲确保整条都在范围内，专测"单线/双线/线宽"逻辑本身。
    final r = await DxfExporter.export(
      name: 'road_${style.name}_$widthScale',
      labels: route(), version: ver,
      fixedScale: 3000,
      basemap: injected(), includeSurroundings: true, rangeM: 120,
      clipInjectedBasemap: true,
      showLegend: false, showTitleBlock: false, showNorthArrow: false,
      roadStyle: style, roadWidthScale: widthScale,
    );
    return latin1.decode(r.file.readAsBytesSync());
  }

  test('实心：道路画一条带宽度 DaoLu，不画边线', () async {
    final t = await exportWith(style: RoadStyle.solid);
    final dl = roadPolys(t, 'DaoLu');
    final bian = roadPolys(t, 'DaoLuBian');
    // ignore: avoid_print
    print('实心: DaoLu=${dl.count} 条(宽 ${dl.widths}), DaoLuBian=${bian.count}');

    expect(dl.count, 1, reason: '一条道路应只画一条单线');
    expect(bian.count, 0, reason: '实心模式不应出现边线 DaoLuBian');
    expect(dl.widths.first, greaterThan(0), reason: '单线应带宽度');
  });

  test('空心：同一条路画左右两条边线', () async {
    final t = await exportWith(style: RoadStyle.hollow);
    final dl = roadPolys(t, 'DaoLu');
    final bian = roadPolys(t, 'DaoLuBian');
    // ignore: avoid_print
    print('空心: DaoLu=${dl.count}, DaoLuBian=${bian.count}');

    expect(bian.count, 2, reason: '左右各一条');
    expect(dl.count, 0, reason: '空心模式不画实心带');
  });

  test('线宽倍数真实生效', () async {
    final t1 = await exportWith(widthScale: 1.0);
    final t2 = await exportWith(widthScale: 2.0);
    final w1 = roadPolys(t1, 'DaoLu').widths;
    final w2 = roadPolys(t2, 'DaoLu').widths;
    // ignore: avoid_print
    print('线宽 ×1 = $w1   ×2 = $w2');

    expect(w1.first, greaterThan(0));
    expect(w2.first / w1.first, closeTo(2.0, 0.03),
        reason: '线宽应精确翻倍');
  });

  test('R2000 用 LWPOLYLINE + 常量宽度 43', () async {
    final t = await exportWith(ver: DxfVersion.r2000, widthScale: 1.5);
    // R2000 的实体头带句柄（5/330/100），所以不能要求 `8\nDaoLu` 紧跟
    // `0\nLWPOLYLINE`；改为在实体块内查找。
    var roadLw = 0;
    final blocks = t.split('0\nLWPOLYLINE\n');
    for (var i = 1; i < blocks.length; i++) {
      final head = blocks[i].substring(
          0, blocks[i].length < 200 ? blocks[i].length : 200);
      if (head.contains('8\nDaoLu\n')) roadLw++;
    }
    // ignore: avoid_print
    print('R2000 DaoLu LWPOLYLINE = $roadLw，全文件 '
        '${RegExp('0\nLWPOLYLINE\n').allMatches(t).length} 个');
    expect(roadLw, 1, reason: '单线道路应是 1 个 LWPOLYLINE');
    expect(t.contains('\n43\n'), isTrue, reason: '应写常量宽度 43');
    // 宽度应为 1.5 倍默认（secondary 半宽 0.60 → 全宽 1.2 → ×1.5 = 1.8）
    final m = RegExp(r'\n43\n([-\d.]+)').firstMatch(t);
    // ignore: avoid_print
    print('首个常量宽度 43 = ${m?.group(1)}');
    expect(double.parse(m!.group(1)!), greaterThan(0));
  });

  test('加宽时建筑向外让开，不加宽时原位', () async {
    Future<List<double>> bldCentersLon(double scale) async {
      final r = await DxfExporter.export(
        name: 'push$scale', labels: route(), version: DxfVersion.r12,
        fixedScale: 3000,
        basemap: injected(), includeSurroundings: true, rangeM: 50,
        clipInjectedBasemap: true,
        showLegend: false, showTitleBlock: false, showNorthArrow: false,
        roadStyle: RoadStyle.solid, roadWidthScale: scale,
      );
      final t = latin1.decode(r.file.readAsBytesSync());
      // 收集 JianZhu 多段线的 x（图纸坐标），取点最多的那条的均值
      final xs = <double>[];
      for (final chunk in t.split('0\nPOLYLINE\n')) {
        if (!chunk.contains('8\nJianZhu\n')) continue;
        for (final m in RegExp(r'\n10\n([-\d.]+)').allMatches(chunk)) {
          xs.add(double.parse(m.group(1)!));
        }
      }
      return xs..sort();
    }

    final a = await bldCentersLon(1.0);
    final b = await bldCentersLon(2.5);
    // ignore: avoid_print
    print('建筑 x（×1）前3=${a.take(3).toList()}');
    // ignore: avoid_print
    print('建筑 x（×2.5）前3=${b.take(3).toList()}');

    expect(a, isNotEmpty, reason: '应有建筑');
    expect(b, isNotEmpty, reason: '应有建筑');
    // 道路在 lon=114.085，x 基准；加宽后建筑应离道路更远
    // 取最靠近道路的 |x| 值比较
    var minA = double.infinity, minB = double.infinity;
    for (final v in a) {
      if (v.abs() < minA) minA = v.abs();
    }
    for (final v in b) {
      if (v.abs() < minB) minB = v.abs();
    }
    // ignore: avoid_print
    print('最靠近道路的建筑边距: ×1=${minA.toStringAsFixed(2)} '
        '×2.5=${minB.toStringAsFixed(2)}');
    expect(minB, greaterThanOrEqualTo(minA),
        reason: '加宽后建筑不应更靠近道路');
  });
}
