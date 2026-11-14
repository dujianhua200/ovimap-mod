// v3.25 验收：道路按缓冲逐段裁剪（不再整条保留）。
import 'dart:convert' show latin1;
import 'dart:io';
import 'dart:math' as math;

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
    tmp = Directory.systemTemp.createTempSync('ov_v325');
    LabelStore.instance.setBaseDirForTest(tmp);
    AppPaths.setBaseForTest(tmp);
    LabelType.installCatalog(SymbolCatalog.fromTextSync(
        File('assets/dxf/lispblock.dxf').readAsStringSync()));
  });

  tearDown(() => AppPaths.clearForTest());

  test('穿过线路的超长道路只保留附近那一段', () async {
    // 线路：一小段（约 400 米）
    final labels = [
      MapLabel(typeId: 'gl003', seq: 1, lat: 32.0, lon: 114.0,
          lineGroupId: 'g', name: 'A'),
      MapLabel(typeId: 'gl003', seq: 2, lat: 32.0, lon: 114.004,
          lineGroupId: 'g', name: 'B'),
    ];

    // 一条从很远的地方穿过线路附近、再延伸到很远的道路（模拟省道）
    final longRoad = RoadPoly(
      [
        [32.00, 113.90],   // 起点很远（约 9km 外）
        [32.00, 114.00],   // 经过线路
        [32.00, 114.004],  // 经过线路
        [32.00, 114.10],   // 继续很远
      ],
      RoadGrade.trunk,
      '超长省道',
    );

    final bm = BasemapData(
      roads: [longRoad],
      buildings: const [],
      places: const [],
      report: const BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, source: 't'),
        buildings: DatasetReport(FetchState.ok, source: 't'),
        places: DatasetReport(FetchState.ok, source: 't'),
        extras: DatasetReport(FetchState.ok, source: 't'),
      ),
    );

    final r = await DxfExporter.export(
      name: 'roadclip',
      labels: labels,
      version: DxfVersion.r12,
      fixedScale: 3000,
      basemap: bm,
      includeSurroundings: true,
      rangeM: 50,
      clipInjectedBasemap: true,
      showLegend: false,
      showStakes: false,
      showNorthArrow: false,
      showTitleBlock: false,
      showLabelNames: false,
    );
    final txt = latin1.decode(r.file.readAsBytesSync());

    // 量导出后道路总长（图纸单位）
    var totalLen = 0.0;
    var maxLen = 0.0;
    for (final chunk in txt.split('0\nPOLYLINE\n')) {
      if (!chunk.contains('8\nDaoLuBian')) continue;
      final pts = <List<double>>[];
      for (final v in chunk.split('0\nVERTEX\n').skip(1)) {
        final xm = RegExp(r'\n10\n([-\d.]+)').firstMatch(v);
        final ym = RegExp(r'\n20\n([-\d.]+)').firstMatch(v);
        if (xm != null && ym != null) {
          pts.add([double.parse(xm.group(1)!), double.parse(ym.group(1)!)]);
        }
      }
      var L = 0.0;
      for (var i = 1; i < pts.length; i++) {
        L += math.sqrt(math.pow(pts[i][0] - pts[i - 1][0], 2) +
            math.pow(pts[i][1] - pts[i - 1][1], 2));
      }
      totalLen += L;
      if (L > maxLen) maxLen = L;
    }

    // ignore: avoid_print
    print('导出道路总长: ${totalLen.toStringAsFixed(1)} 单位，'
        '最长一条: ${maxLen.toStringAsFixed(1)}');

    // 原道路约 0.2° 经度 ≈ 21km ≈ 7000 单位；
    // 裁剪后应只剩线路附近那段（50m 缓冲 × 双向，约 300 单位量级）。
    // 关键对照：远小于原长度。
    expect(totalLen, lessThan(500),
        reason: '只应保留线路附近那一段，不应整条 21km 省道都进图；'
            '实际 ${totalLen.toStringAsFixed(1)} 单位');
    // 最长一条也不应超过整条路
    expect(maxLen, lessThan(500),
        reason: '单条道路不应跨出缓冲区，实际最长 ${maxLen.toStringAsFixed(1)}');
  });

  test('完全不经过线路附近的道路被整条丢弃', () async {
    final labels = [
      MapLabel(typeId: 'gl003', seq: 1, lat: 32.0, lon: 114.0,
          lineGroupId: 'g', name: 'A'),
      MapLabel(typeId: 'gl003', seq: 2, lat: 32.0, lon: 114.001,
          lineGroupId: 'g', name: 'B'),
    ];
    final far = RoadPoly(
      [
        [33.0, 115.0],
        [33.01, 115.01],
      ],
      RoadGrade.trunk,
      '很远的路',
    );
    final bm = BasemapData(
      roads: [far], buildings: const [], places: const [],
      report: const BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, source: 't'),
        buildings: DatasetReport(FetchState.ok, source: 't'),
        places: DatasetReport(FetchState.ok, source: 't'),
        extras: DatasetReport(FetchState.ok, source: 't'),
      ),
    );
    final r = await DxfExporter.export(
      name: 'roadfar', labels: labels, version: DxfVersion.r12,
      fixedScale: 3000, basemap: bm, includeSurroundings: true,
      rangeM: 50, clipInjectedBasemap: true,
      showLegend: false, showStakes: false, showNorthArrow: false,
      showTitleBlock: false, showLabelNames: false,
    );
    final txt = latin1.decode(r.file.readAsBytesSync());
    final n = RegExp(r'0\nPOLYLINE\n8\nDaoLuBian\n').allMatches(txt).length;
    expect(n, 0, reason: '远离线路的道路应被丢弃，实际导出 $n 条');
  });
}
