// v3.31 验收：道路默认**空心**（两条平行边线，中间不填充）。
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
    tmp = Directory.systemTemp.createTempSync('ov_v331');
    LabelStore.instance.setBaseDirForTest(tmp);
    AppPaths.setBaseForTest(tmp);
    LabelType.installCatalog(SymbolCatalog.fromTextSync(
        File('assets/dxf/lispblock.dxf').readAsStringSync()));
  });

  tearDown(() => AppPaths.clearForTest());

  List<MapLabel> route() => [
        for (var i = 0; i < 12; i++)
          MapLabel(
            typeId: 'gl003', seq: i + 1,
            lat: 32.140 + i * 0.0005,
            lon: 114.085,
            lineGroupId: 'g', name: 'P${i + 1}', distanceM: 55,
          ),
      ];

  BasemapData injected() {
    final road = RoadPoly(
      [
        [32.1395, 114.085],
        [32.1460, 114.085],
      ],
      RoadGrade.secondary,
      '测试路',
    );
    return BasemapData(
      roads: [road],
      buildings: const [],
      places: const [],
      report: const BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, source: 'test'),
        buildings: DatasetReport(FetchState.ok, source: 'test'),
        places: DatasetReport(FetchState.ok, source: 'test'),
        extras: DatasetReport(FetchState.ok, source: 'test'),
      ),
    );
  }

  /// 统计某图层的折线实体。
  ///
  /// 只匹配**实体头**：`0\nPOLYLINE\n8\n<layer>\n66\n1\n`。
  /// 宽度只从该实体自己的属性区取（到第一个 VERTEX 为止），
  /// 否则会把后面 TEXT 的字高等组码误当宽度。
  ({int count, List<double> widths, List<double> xs}) polys(
      String txt, String layer) {
    final widths = <double>[];
    final xs = <double>[];
    var count = 0;

    for (final m in RegExp('0\nPOLYLINE\n8\n$layer\n66\n1\n').allMatches(txt)) {
      count++;
      final start = m.end;
      // 属性区到第一个 VERTEX / SEQEND 为止
      var end = txt.indexOf('0\nVERTEX\n', start);
      if (end < 0) end = txt.length;
      final props = txt.substring(m.start, end);
      final w = RegExp(r'\n40\n([-\d.]+)').firstMatch(props);
      widths.add(w != null ? double.parse(w.group(1)!) : 0);
      // 第一个顶点的 x
      final rest = txt.substring(end,
          (end + 200).clamp(0, txt.length));
      final x = RegExp(r'0\nVERTEX\n8\n[^\n]*\n10\n([-\d.]+)').firstMatch(rest);
      if (x != null) xs.add(double.parse(x.group(1)!));
    }
    for (final m in RegExp('0\nLWPOLYLINE\n8\n$layer\n').allMatches(txt)) {
      count++;
      final end = txt.indexOf('0\n', m.end);
      final props = txt.substring(m.start, end < 0 ? txt.length : end);
      final w = RegExp(r'\n43\n([-\d.]+)').firstMatch(props);
      widths.add(w != null ? double.parse(w.group(1)!) : 0);
      final x = RegExp(r'\n10\n([-\d.]+)').firstMatch(props);
      if (x != null) xs.add(double.parse(x.group(1)!));
    }
    return (count: count, widths: widths, xs: xs);
  }

  Future<String> exportWith({
    RoadStyle? style,
    double widthScale = 1.0,
  }) async {
    final r = await DxfExporter.export(
      name: 'road_${style?.name ?? "default"}',
      labels: route(), version: DxfVersion.r12,
      fixedScale: 3000,
      basemap: injected(), includeSurroundings: true, rangeM: 120,
      clipInjectedBasemap: true,
      showLegend: false, showTitleBlock: false, showNorthArrow: false,
      roadStyle: style ?? RoadStyle.hollow,
      roadWidthScale: widthScale,
    );
    return latin1.decode(r.file.readAsBytesSync());
  }

  test('默认就是空心：两条平行边线，中间无填充', () async {
    final t = await exportWith(); // 不传 style，走默认
    final bian = polys(t, 'DaoLuBian');
    final solid = polys(t, 'DaoLu');
    // ignore: avoid_print
    print('默认: DaoLuBian=${bian.count} 条, DaoLu=${solid.count} 条');
    // ignore: avoid_print
    print('  边线 x = ${bian.xs.map((v) => v.toStringAsFixed(2)).toList()}');
    // ignore: avoid_print
    print('  边线宽度 = ${bian.widths}');

    expect(bian.count, 2, reason: '空心道路应有左右两条边线');
    expect(solid.count, 0, reason: '不应有实心带（DaoLu 折线）');
    // 两条边线的宽度必须是 0（不填充）
    for (final w in bian.widths) {
      expect(w, 0, reason: '空心道路的边线不得有宽度（否则会显示成实心）');
    }
    // 两条边线应分居道路两侧（x 一左一右）
    expect(bian.xs.length, 2);
    expect((bian.xs[0] - bian.xs[1]).abs(), greaterThan(0.5),
        reason: '两条边线应分开一段距离（= 路宽）');
  });

  test('实心模式：一条带宽度中心线，无边线', () async {
    final t = await exportWith(style: RoadStyle.solid);
    final bian = polys(t, 'DaoLuBian');
    final solid = polys(t, 'DaoLu');
    // ignore: avoid_print
    print('实心: DaoLu=${solid.count} 条(宽 ${solid.widths}), '
        'DaoLuBian=${bian.count}');

    expect(solid.count, 1);
    expect(solid.widths.first, greaterThan(0), reason: '实心带应有宽度');
    expect(bian.count, 0);
  });

  test('细线模式：一条零宽中心线', () async {
    final t = await exportWith(style: RoadStyle.hairline);
    final bian = polys(t, 'DaoLuBian');
    final solid = polys(t, 'DaoLu');
    // ignore: avoid_print
    print('细线: DaoLu=${solid.count} 条(宽 ${solid.widths}), '
        'DaoLuBian=${bian.count}');

    expect(solid.count, 1);
    expect(solid.widths.first, 0, reason: '细线不应有宽度');
    expect(bian.count, 0);
  });

  test('线宽倍数让空心道路变宽（两条边线间距变大）', () async {
    final t1 = await exportWith(widthScale: 1.0);
    final t2 = await exportWith(widthScale: 2.0);
    final b1 = polys(t1, 'DaoLuBian');
    final b2 = polys(t2, 'DaoLuBian');

    final gap1 = (b1.xs[0] - b1.xs[1]).abs();
    final gap2 = (b2.xs[0] - b2.xs[1]).abs();
    // ignore: avoid_print
    print('边线间距 ×1 = ${gap1.toStringAsFixed(2)}, '
        '×2 = ${gap2.toStringAsFixed(2)}');

    expect(gap2 / gap1, closeTo(2.0, 0.05), reason: '路宽应精确翻倍');
  });
}
