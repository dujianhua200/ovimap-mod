// 验证沿线路缓冲裁剪：折线线路 + 大范围底图 → 只保留沿线附近的要素。
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
    tmp = Directory.systemTemp.createTempSync('ov_buf');
    LabelStore.instance.setBaseDirForTest(tmp);
    AppPaths.setBaseForTest(tmp);
    LabelType.installCatalog(SymbolCatalog.fromTextSync(
        File('assets/dxf/lispblock.dxf').readAsStringSync()));
  });

  tearDown(() => AppPaths.clearForTest());

  test('折线线路 + 全程铺设的底图：只保留沿线 50m 内', () async {
    // 一条"L 形"线路，横跨约 600 x 600 米
    final labels = [
      MapLabel(typeId: 'gl003', seq: 1, lat: 32.000, lon: 114.000,
          lineGroupId: 'g', name: 'A'),
      MapLabel(typeId: 'gl003', seq: 2, lat: 32.000, lon: 114.006,
          lineGroupId: 'g', name: 'B'), // 东西 ~570m
      MapLabel(typeId: 'gl003', seq: 3, lat: 32.005, lon: 114.006,
          lineGroupId: 'g', name: 'C'), // 南北 ~550m
    ];

    // 底图：在整片区域铺满建筑（含线路拐角外侧的空白区）
    final blds = <BuildingPoly>[];
    for (var i = 0; i < 30; i++) {
      for (var j = 0; j < 30; j++) {
        final lat = 31.998 + i * 0.0003;
        final lon = 113.998 + j * 0.0003;
        blds.add(BuildingPoly([
          [
            [lat, lon],
            [lat, lon + 0.00008],
            [lat + 0.00008, lon + 0.00008],
            [lat + 0.00008, lon],
          ]
        ], ''));
      }
    }
    final bm = BasemapData(
      roads: const [],
      buildings: blds,
      places: const [],
      report: const BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, source: 't'),
        buildings: DatasetReport(FetchState.ok, source: 't'),
        places: DatasetReport(FetchState.ok, source: 't'),
        extras: DatasetReport(FetchState.ok, source: 't'),
      ),
    );
    // ignore: avoid_print
    print('底图建筑总数: ${blds.length}');

    final r = await DxfExporter.export(
      name: 'buffer50',
      labels: labels,
      version: DxfVersion.r12,
      fixedScale: 3000,
      basemap: bm,
      includeSurroundings: true,
      rangeM: 50,
      // 显式要求按范围裁剪注入的底图（模拟 UI 导出路径）
      clipInjectedBasemap: true,
      showLegend: false,
      showStakes: false,
      showNorthArrow: false,
      showTitleBlock: false,
      showLabelNames: false,
    );
    final txt = latin1.decode(r.file.readAsBytesSync());

    // 数 JianZhu 层的多段线
    final n = RegExp(r'0\nPOLYLINE\n8\nJianZhu\n').allMatches(txt).length;
    // ignore: avoid_print
    print('导出建筑数: $n (总 ${blds.length})');
    expect(n, greaterThan(0), reason: '沿线附近应有建筑');
    expect(n, lessThan(blds.length * 0.35),
        reason: '沿线路缓冲后应大幅裁掉远端建筑，实际 $n / ${blds.length}');
  });

  test('范围档位越大，保留要素越多', () async {
    final labels = [
      MapLabel(typeId: 'gl003', seq: 1, lat: 32.000, lon: 114.000,
          lineGroupId: 'g', name: 'A'),
      MapLabel(typeId: 'gl003', seq: 2, lat: 32.000, lon: 114.006,
          lineGroupId: 'g', name: 'B'),
    ];
    final blds = <BuildingPoly>[];
    for (var i = 0; i < 40; i++) {
      for (var j = 0; j < 40; j++) {
        final lat = 31.9985 + i * 0.00025;
        final lon = 113.9990 + j * 0.00025;
        blds.add(BuildingPoly([
          [
            [lat, lon],
            [lat, lon + 0.00006],
            [lat + 0.00006, lon + 0.00006],
            [lat + 0.00006, lon],
          ]
        ], ''));
      }
    }
    final bm = BasemapData(
      roads: const [], buildings: blds, places: const [],
      report: const BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, source: 't'),
        buildings: DatasetReport(FetchState.ok, source: 't'),
        places: DatasetReport(FetchState.ok, source: 't'),
        extras: DatasetReport(FetchState.ok, source: 't'),
      ),
    );

    Future<int> countAt(double rangeM) async {
      final r = await DxfExporter.export(
        name: 'r${rangeM.round()}', labels: labels,
        version: DxfVersion.r12, fixedScale: 3000,
        basemap: bm, includeSurroundings: true, rangeM: rangeM,
        clipInjectedBasemap: true,
        showLegend: false, showStakes: false,
        showNorthArrow: false, showTitleBlock: false, showLabelNames: false);
      final txt = latin1.decode(r.file.readAsBytesSync());
      return RegExp(r'0\nPOLYLINE\n8\nJianZhu\n').allMatches(txt).length;
    }

    final n30 = await countAt(30);
    final n300 = await countAt(300);
    // ignore: avoid_print
    print('30m 保留 $n30 栋 / 300m 保留 $n300 栋');
    expect(n300, greaterThan(n30),
        reason: '范围档位应真实生效：300m 保留数 > 30m 保留数');
  });
}
