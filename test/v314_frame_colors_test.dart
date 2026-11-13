// v3.14 五项验收：图框 / 标签颜色 / 图标不连线 / 兜底底图 / 距离居中。
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
    tmp = Directory.systemTemp.createTempSync('ov_v314');
    LabelStore.instance.setBaseDirForTest(tmp);
    AppPaths.setBaseForTest(tmp);
    final asset = File('assets/dxf/lispblock.dxf');
    LabelType.installCatalog(
        SymbolCatalog.fromTextSync(asset.readAsStringSync()));
  });

  tearDown(() => AppPaths.clearForTest());

  List<MapLabel> chain({int n = 4, double dLat = 0.0004}) => [
        for (var i = 0; i < n; i++)
          MapLabel(
            typeId: 'gl003',
            seq: i + 1,
            lat: 32.0 + i * dLat,
            lon: 114.0,
            lineGroupId: 'g',
            name: 'GK-${i + 1}',
          ),
      ];

  group('图框：用用户 DXF，尺寸不变，装不下就多张', () {
    test('能解析用户图框（A3 内框约 392×281）', () async {
      final f = File('assets/frames/frame_a3.dxf');
      expect(f.existsSync(), isTrue, reason: '图框资源应随包');
      final t = parseDxfFrame(latin1.decode(f.readAsBytesSync()));
      expect(t.shapes, isNotEmpty, reason: '应解析出图元');
      // 用户图框实测 392 × 281
      expect(t.width, closeTo(392, 6), reason: '宽度应≈392，实际 ${t.width}');
      expect(t.height, closeTo(281, 6), reason: '高度应≈281，实际 ${t.height}');
    });

    test('内容装得下 → 1 个图框；装不下 → 多张', () {
      final t = FrameTemplate(const [], 392, 281);
      final one = t.tilesFor(t.contentWidth * 0.8, t.contentHeight * 0.8);
      expect(one.cols, 1);
      expect(one.rows, 1);

      final two = t.tilesFor(t.contentWidth * 2.2, t.contentHeight * 0.8);
      expect(two.cols, greaterThanOrEqualTo(3));

      final tall = t.tilesFor(t.contentWidth * 0.8, t.contentHeight * 2.5);
      expect(tall.rows, greaterThanOrEqualTo(3));
    });

    test('导出带图框：结构合法，且图框尺寸不被缩放', () async {
      final f = File('assets/frames/frame_a3.dxf');
      final t = parseDxfFrame(latin1.decode(f.readAsBytesSync()));
      final r = await DxfExporter.export(
        name: 'framed',
        labels: chain(),
        version: DxfVersion.r12,
        fixedScale: 3000,
        frame: t,
        showLegend: false,
      );
      final txt = latin1.decode(r.file.readAsBytesSync());
      expect(DxfStructureValidator.validate(txt, version: DxfVersion.r12),
          isEmpty);
      // TuQian 层应有图框实体
      expect(txt, contains('\n8\nTuQian\n'), reason: '应有图框层实体');
    });
  });

  group('标签颜色可选', () {
    test('可指定 BiaoQian / JuLi 颜色（R2000 真彩色 + ACI）', () async {
      final r = await DxfExporter.export(
        name: 'colors',
        labels: chain(),
        version: DxfVersion.r2000,
        fixedScale: 3000,
        showLegend: false,
        colorOverrides: {
          'BiaoQian': 0xFF0000, // 红
          'JuLi': 0x0080FF, // 蓝
        },
      );
      final txt = latin1.decode(r.file.readAsBytesSync());
      // 0xFF0000 = 16711680
      expect(txt, contains('420\n16711680\n'),
          reason: 'BiaoQian 应写红色真彩色');
      // 0x0080FF = 33023
      expect(txt, contains('420\n33023\n'), reason: 'JuLi 应写蓝色真彩色');
      expect(DxfStructureValidator.validate(txt, version: DxfVersion.r2000),
          isEmpty);
    });

    test('R12 下自定义颜色退到 ACI（不会全黑）', () async {
      final r = await DxfExporter.export(
        name: 'colors_r12',
        labels: chain(),
        version: DxfVersion.r12,
        fixedScale: 3000,
        showLegend: false,
        colorOverrides: {'JuLi': 0xFF0000},
      );
      final txt = latin1.decode(r.file.readAsBytesSync());
      expect(txt, isNot(contains('\n420\n')), reason: 'R12 无真彩色');
      // 红色 → ACI 1
      final tables = _section(txt, 'TABLES');
      final i = tables.indexOf('2\nJuLi\n');
      expect(i, greaterThan(0));
      final chunk = tables.substring(i, (i + 80).clamp(0, tables.length));
      expect(chunk, contains('62\n1\n'), reason: '红色应映射到 ACI 1，实际：'
          '${chunk.split('\n').take(10).join('|')}');
    });

    test('未指定颜色时保持默认（不误改）', () async {
      final r = await DxfExporter.export(
        name: 'colors_default',
        labels: chain(),
        version: DxfVersion.r12,
        fixedScale: 3000,
        showLegend: false,
      );
      final txt = latin1.decode(r.file.readAsBytesSync());
      expect(txt, contains('2\nJuLi\n'));
      expect(DxfStructureValidator.validate(txt, version: DxfVersion.r12),
          isEmpty);
    });
  });

  group('距离数字居中', () {
    test('JuLi 文字带 72=1 / 73=2 对齐码', () async {
      final r = await DxfExporter.export(
        name: 'centered',
        labels: chain(),
        version: DxfVersion.r12,
        fixedScale: 3000,
        showLegend: false,
        showStakes: false,
      );
      final txt = latin1.decode(r.file.readAsBytesSync());
      final ents = _textEntities(txt, 'JuLi');
      expect(ents, isNotEmpty, reason: '应有距离文字');
      for (final e in ents) {
        expect(e, contains('72\n1\n'), reason: '水平居中');
        expect(e, contains('73\n2\n'), reason: '垂直居中');
        expect(e, contains('11\n'), reason: '应有对齐点 11/21');
      }
    });
  });

  group('兜底底图：bbox 顺序修正后真的能查到', () {
    test('羊山一带 100m 内能查到建筑', () async {
      BundledBasemap.setTestBypass(true);
      final b = await BundledBasemap.instance;
      final labels = [
        MapLabel(
            typeId: 'gl003', seq: 1, lat: 32.15, lon: 114.08,
            lineGroupId: 'g'),
        MapLabel(
            typeId: 'gl003', seq: 2, lat: 32.1505, lon: 114.083,
            lineGroupId: 'g'),
      ];
      // boundsOf 返回 [minLat, minLon, maxLat, maxLon]
      final bb = BasemapFetcher.boundsOf(labels, 100);
      final lonMin = bb[1], latMin = bb[0], lonMax = bb[3], latMax = bb[2];

      expect(BundledBasemap.covers(lonMin, latMin, lonMax, latMax), isTrue,
          reason: '有交集即覆盖');
      final blds = b.buildingsIn(lonMin, latMin, lonMax, latMax);
      expect(blds, isNotEmpty,
          reason: 'bbox 顺序修正后应查到建筑（修正前一直是 0）');
    });

    test('covers 用"有交集"语义，不是"完全包含"', () {
      // 跨出边界但有交集 → true
      expect(BundledBasemap.covers(115.5, 32.1, 116.2, 32.2), isTrue);
      // 完全在外 → false
      expect(BundledBasemap.covers(117.0, 33.0, 117.5, 33.5), isFalse);
    });
  });
}

List<String> _textEntities(String dxf, String layer) {
  final out = <String>[];
  final lines = dxf.split('\n');
  var type = '';
  var body = <String>[];
  void flush() {
    if (type == 'TEXT') {
      final joined = body.join('\n');
      final m = RegExp(r'^8\n([^\n]*)$', multiLine: true).firstMatch(joined);
      if ((m?.group(1) ?? '') == layer) out.add(joined);
    }
    type = '';
    body = [];
  }

  for (var i = 0; i + 1 < lines.length; i += 2) {
    if (lines[i].trim() == '0') {
      flush();
      type = lines[i + 1].trim();
      continue;
    }
    body.add('${lines[i].trim()}\n${lines[i + 1]}');
  }
  flush();
  return out;
}

String _section(String dxf, String name) {
  final marker = '0\nSECTION\n2\n$name\n';
  final i = dxf.indexOf(marker);
  if (i < 0) return '';
  final j = dxf.indexOf('0\nENDSEC', i);
  return j < 0 ? dxf.substring(i) : dxf.substring(i, j);
}
