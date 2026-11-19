// v3.32 验收：道路宽度可自定义，线宽恒为 0.000。
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
    tmp = Directory.systemTemp.createTempSync('ov_v332');
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
            lat: 32.140 + i * 0.0005, lon: 114.085,
            lineGroupId: 'g', name: 'P${i + 1}', distanceM: 55,
          ),
      ];

  BasemapData injected() => BasemapData(
        roads: [
          RoadPoly([[32.1395, 114.085], [32.1460, 114.085]],
              RoadGrade.secondary, '测试路'),
        ],
        buildings: const [], places: const [],
        report: const BasemapFetchReport(
          roads: DatasetReport(FetchState.ok, source: 't'),
          buildings: DatasetReport(FetchState.ok, source: 't'),
          places: DatasetReport(FetchState.ok, source: 't'),
          extras: DatasetReport(FetchState.ok, source: 't'),
        ),
      );

  /// 取道路边线：数量、x 坐标、以及**所有宽度组码**（40/43）。
  ({int count, List<double> xs, List<String> widthCodes}) edges(String txt) {
    final xs = <double>[];
    final widthCodes = <String>[];
    var count = 0;
    for (final m
        in RegExp('0\nPOLYLINE\n8\nDaoLuBian\n66\n1\n').allMatches(txt)) {
      count++;
      // 属性区：从实体头到第一个 VERTEX
      var end = txt.indexOf('0\nVERTEX\n', m.end);
      if (end < 0) end = txt.length;
      final props = txt.substring(m.start, end);
      // 抓宽度组码
      for (final w in RegExp(r'\n(40|41)\n([-\d.]+)').allMatches(props)) {
        widthCodes.add('${w.group(1)}=${w.group(2)}');
      }
      final rest = txt.substring(end, (end + 200).clamp(0, txt.length));
      final x = RegExp(r'0\nVERTEX\n8\n[^\n]*\n10\n([-\d.]+)').firstMatch(rest);
      if (x != null) xs.add(double.parse(x.group(1)!));
    }
    // LWPOLYLINE 的 43
    for (final m in RegExp('0\nLWPOLYLINE\n8\nDaoLuBian\n').allMatches(txt)) {
      count++;
      final end = txt.indexOf('0\n', m.end);
      final props = txt.substring(m.start, end < 0 ? txt.length : end);
      for (final w in RegExp(r'\n43\n([-\d.]+)').allMatches(props)) {
        widthCodes.add('43=${w.group(1)}');
      }
      final x = RegExp(r'\n10\n([-\d.]+)').firstMatch(props);
      if (x != null) xs.add(double.parse(x.group(1)!));
    }
    return (count: count, xs: xs, widthCodes: widthCodes);
  }

  Future<String> exportWith({double? widthMm, double scale = 1.0}) async {
    final r = await DxfExporter.export(
      name: 'rw_${widthMm ?? "default"}',
      labels: route(), version: DxfVersion.r12,
      fixedScale: 3000,
      basemap: injected(), includeSurroundings: true, rangeM: 120,
      clipInjectedBasemap: true,
      showLegend: false, showTitleBlock: false, showNorthArrow: false,
      roadStyle: RoadStyle.hollow,
      roadWidthScale: scale,
      roadWidthMm: widthMm,
    );
    return latin1.decode(r.file.readAsBytesSync());
  }

  test('线宽永远是 0.000（不写任何宽度组码）', () async {
    for (final w in [null, 0.5, 2.0, 5.0]) {
      final t = await exportWith(widthMm: w, scale: 1.0);
      final e = edges(t);
      // ignore: avoid_print
      print('宽度参数=$w → 边线 ${e.count} 条, 宽度组码 ${e.widthCodes}');
      expect(e.count, 2, reason: '空心道路应有两条边线');
      expect(e.widthCodes, isEmpty,
          reason: '不管路宽设多少，线宽组码都不得出现（线宽恒 0.000）');
    }
  });

  test('自定义宽度决定两条边线的间距', () async {
    Future<double> gapFor(double mm) async {
      final t = await exportWith(widthMm: mm);
      final e = edges(t);
      expect(e.xs.length, 2);
      return (e.xs[0] - e.xs[1]).abs();
    }

    final g1 = await gapFor(1.0);
    final g2 = await gapFor(3.0);
    // ignore: avoid_print
    print('宽度 1.0mm → 间距 ${g1.toStringAsFixed(2)}；'
        '3.0mm → ${g2.toStringAsFixed(2)}');

    // 单位是图纸单位；1:3000 下 1mm 纸面 = 1 单位（_mmOf 恒等）
    expect(g1, closeTo(1.0, 0.05), reason: '1.0mm 路宽 → 边线间距 1.0');
    expect(g2, closeTo(3.0, 0.05), reason: '3.0mm 路宽 → 边线间距 3.0');
    expect(g2 / g1, closeTo(3.0, 0.1), reason: '宽度应线性可控');
  });

  test('不给宽度时按等级默认（secondary 半宽 0.60 → 间距 1.2）', () async {
    final t = await exportWith();
    final e = edges(t);
    final gap = (e.xs[0] - e.xs[1]).abs();
    // ignore: avoid_print
    print('默认宽度: 间距 ${gap.toStringAsFixed(2)}');
    expect(gap, closeTo(1.2, 0.05), reason: 'secondary 默认全宽 1.2');
  });
}
