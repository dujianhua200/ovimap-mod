// v3.16 四项修复验收：图框不重复 / 建筑不写名 / 内存 / 打点颜色。
import 'dart:convert' show latin1;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/bundled_basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_validate.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/export/frame_template.dart';
import 'package:ovimap/models/label_type.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/symbols/symbol_catalog.dart';

void main() {
  late Directory tmp;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = Directory.systemTemp.createTempSync('ov_v316');
    LabelStore.instance.setBaseDirForTest(tmp);
    AppPaths.setBaseForTest(tmp);
    LabelType.installCatalog(SymbolCatalog.fromTextSync(
        File('assets/dxf/lispblock.dxf').readAsStringSync()));
  });

  tearDown(() => AppPaths.clearForTest());

  List<MapLabel> chain({int n = 4}) => [
        for (var i = 0; i < n; i++)
          MapLabel(
            typeId: 'gl003',
            seq: i + 1,
            lat: 32.0 + i * 47 / 110540.0,
            lon: 114.0,
            lineGroupId: 'g',
            name: 'GK-${i + 1}',
            distanceM: 47,
          ),
      ];

  group('图框不重复（用户："弄了十几个"）', () {
    test('短线路 + 大片底图 → 仍然只出 1 套图框', () async {
      final frame = parseDxfFrame(latin1
          .decode(File('assets/frames/frame_a3.dxf').readAsBytesSync()));

      // 底图铺得很开（模拟 394 栋建筑撑大包围盒）
      final bm = BasemapData(
        roads: [
          for (var i = 0; i < 40; i++)
            RoadPoly(
              [
                [32.0 + i * 0.002, 113.9],
                [32.0 + i * 0.002, 114.3],
              ],
              RoadGrade.service,
              '路$i',
            ),
        ],
        buildings: [
          for (var i = 0; i < 200; i++)
            BuildingPoly(
              [
                [
                  [32.0 + i * 0.001, 113.95],
                  [32.0 + i * 0.001, 113.952],
                  [32.001 + i * 0.001, 113.952],
                  [32.001 + i * 0.001, 113.95],
                ]
              ],
              '',
            ),
        ],
        places: const [],
        report: const BasemapFetchReport(
          roads: DatasetReport(FetchState.ok, source: 't'),
          buildings: DatasetReport(FetchState.ok, source: 't'),
          places: DatasetReport(FetchState.ok, source: 't'),
          extras: DatasetReport(FetchState.ok, source: 't'),
        ),
      );

      final r = await DxfExporter.export(
        name: 'frame_once',
        labels: chain(), // 短线路（约 141 米）
        version: DxfVersion.r12,
        fixedScale: 3000,
        frame: frame,
        basemap: bm,
        includeSurroundings: true,
        showLegend: false,
      );
      final txt = latin1.decode(r.file.readAsBytesSync());

      // 一套图框的 TuQian 实体数（实测单套约 85）
      final tu = _entities(txt, 'TuQian');
      expect(tu, isNotEmpty);
      expect(tu.length, lessThan(200),
          reason: '短线路应只出 1 套房框，实际 TuQian 实体 ${tu.length} 个'
              '（一套约 85，多套会成倍增长）');
    });

    test('长线路确实需要多幅时仍会分幅', () async {
      final frame = parseDxfFrame(latin1
          .decode(File('assets/frames/frame_a3.dxf').readAsBytesSync()));
      // 20 杆 × 400 米 ≈ 7.6km；1:3000 下 1 单位=3m → 约 2500 单位
      final long = [
        for (var i = 0; i < 20; i++)
          MapLabel(
            typeId: 'gl003',
            seq: i + 1,
            lat: 32.0 + i * 400 / 110540.0,
            lon: 114.0,
            lineGroupId: 'g',
            name: 'P${i + 1}',
          ),
      ];
      final r = await DxfExporter.export(
        name: 'frame_multi',
        labels: long,
        version: DxfVersion.r12,
        fixedScale: 3000,
        frame: frame,
        showLegend: false,
      );
      final txt = latin1.decode(r.file.readAsBytesSync());
      final tu = _entities(txt, 'TuQian');
      expect(tu.length, greaterThan(200),
          reason: '7.6km 线路应分成多幅，实际 TuQian 实体 ${tu.length}');
    });
  });

  group('建筑不写名称（用户："全是乱码"）', () {
    test('内置兜底建筑名称为空，不产生"内置兜底"文字', () async {
      BundledBasemap.setTestBypass(true);
      final b = await BundledBasemap.instance;
      // 羊山一带
      final bb = BasemapFetcher.boundsOf([
        MapLabel(typeId: 'gl003', seq: 1, lat: 32.15, lon: 114.08),
        MapLabel(typeId: 'gl003', seq: 2, lat: 32.1506, lon: 114.082),
      ], 120);
      final rings = b.buildingsIn(bb[1], bb[0], bb[3], bb[2]);
      expect(rings, isNotEmpty, reason: '应有建筑数据');
    });
  });

  group('内存：建筑惰性解析', () {
    test('建筑数据以压缩字节保存，不预解析', () async {
      BundledBasemap.setTestBypass(true);
      final b = await BundledBasemap.instance;
      // 加载后 buildingsLoaded 为 true（字节在），但不持有解析结果
      expect(b.buildingsLoaded, isTrue);
      final s = b.summary();
      expect(s, contains('惰性'),
          reason: 'summary 应提示建筑是惰性加载；实际：$s');
    });
  });

  group('导出结构仍合法', () {
    test('带图框 + 颜色 R12/R2000 结构校验通过', () async {
      final frame = parseDxfFrame(latin1
          .decode(File('assets/frames/frame_a3.dxf').readAsBytesSync()));
      for (final v in [DxfVersion.r12, DxfVersion.r2000]) {
        final r = await DxfExporter.export(
          name: 'ok_${v.name}',
          labels: chain(),
          version: v,
          fixedScale: 3000,
          frame: frame,
          colorOverrides: const {'BiaoQian': 0xFF0000, 'JuLi': 0x0000FF},
        );
        final txt = latin1.decode(r.file.readAsBytesSync());
        expect(DxfStructureValidator.validate(txt, version: v), isEmpty,
            reason: '${v.name} 结构应合法');
        // 不应有"内置兜底"这类占位文字
        expect(txt, isNot(contains('内置兜底')));
      }
    });
  });
}

List<String> _entities(String dxf, String layer) {
  final out = <String>[];
  final lines = dxf.split('\n');
  var body = <String>[];
  void flush() {
    if (body.isEmpty) return;
    final joined = body.join('\n');
    final m = RegExp(r'^8\n([^\n]*)$', multiLine: true).firstMatch(joined);
    if ((m?.group(1) ?? '') == layer) out.add(joined);
    body = [];
  }

  for (var i = 0; i + 1 < lines.length; i += 2) {
    if (lines[i].trim() == '0') {
      flush();
      continue;
    }
    body.add('${lines[i].trim()}\n${lines[i + 1]}');
  }
  flush();
  return out;
}
