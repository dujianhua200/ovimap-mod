// QA 独立对抗性验证（Edward / 严过关）——不复用工程师任何 fixture。
//   G1 结构校验器对抗：畸形输入必须被抓出（含复现"上一轮旧 bug"文件）
//   G2 GeoJSON 恶意/异常输入：必须优雅、不崩
//   G3 本地 GeoJSON 导入端到端：离线出图，落盘到 build/qa_e2e 供 ezdxf 严格复核
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_validate.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/export/local_basemap.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String root;
  _FakePathProvider(this.root);
  @override
  Future<String?> getExternalStoragePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// 极简实体解析：按组码 0 切分实体，收集其后的 (code,value) 对。
class _E {
  final String type;
  final List<List<String>> kv = [];
  _E(this.type);
  String? first(String c) {
    for (final p in kv) {
      if (p[0] == c) return p[1].trim();
    }
    return null;
  }
}

List<_E> _parse(String t) {
  final lines = t.replaceAll('\r\n', '\n').split('\n');
  final out = <_E>[];
  _E? cur;
  var i = 0;
  while (i + 1 < lines.length) {
    final code = lines[i].trim();
    final val = lines[i + 1];
    if (code == '0') {
      cur = _E(val.trim());
      out.add(cur);
    } else if (cur != null) {
      cur.kv.add([code, val]);
    }
    i += 2;
  }
  return out;
}

List<MapLabel> _poles() => [
      MapLabel(typeId: 'pipe', seq: 1, lat: 32.1264, lon: 114.0913, lineGroupId: 'g'),
      MapLabel(typeId: 'pipe', seq: 2, lat: 32.1266, lon: 114.0918, lineGroupId: 'g'),
      MapLabel(typeId: 'pipe', seq: 3, lat: 32.1268, lon: 114.0924, lineGroupId: 'g'),
    ];

/// 自造 GeoJSON：带孔 Polygon 建筑 + LineString 道路 + Point 地名（坐标 [lon,lat]）。
const String _myGeoJson = '{"type":"FeatureCollection","features":['
    '{"type":"Feature","properties":{"name":"QA大厦"},"geometry":{"type":"Polygon",'
    '"coordinates":[[[114.0918,32.1268],[114.0924,32.1268],[114.0924,32.1273],'
    '[114.0918,32.1273],[114.0918,32.1268]],[[114.0919,32.1269],[114.0923,32.1269],'
    '[114.0923,32.1272],[114.0919,32.1272],[114.0919,32.1269]]]}},'
    '{"type":"Feature","properties":{"name":"人民路","highway":"primary"},'
    '"geometry":{"type":"LineString","coordinates":[[114.0900,32.1264],[114.0935,32.1264]]}},'
    '{"type":"Feature","properties":{"name":"QA村","place":"village"},'
    '"geometry":{"type":"Point","coordinates":[114.0913,32.1280]}}]}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ================= G1 结构校验器对抗 =================
  group('G1 结构校验器对抗（畸形输入必须被抓出）', () {
    test('复现旧 bug：R12 结构贴 AC1015 标签 → R2000 校验必须报错', () async {
      final dir = Directory.systemTemp.createTempSync('qa_oldbug');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final r = await DxfExporter.export(
          name: 'r12', labels: _poles(), version: DxfVersion.r12);
      final r12 = gbk_bytes.decode(r.file.readAsBytesSync());
      final oldBug = r12.replaceAll('AC1009', 'AC1015'); // 旧 bug 文件
      final p = DxfStructureValidator.validate(oldBug, version: DxfVersion.r2000);
      // 必须检出：缺 $HANDSEED / 缺 OBJECTS / 实体缺句柄 缺 100 子类
      expect(p, isNotEmpty, reason: '旧 bug 文件竟被判合法：$p');
      expect(p.any((s) => s.contains(r'$HANDSEED')), isTrue, reason: '$p');
      // 反向：同一文本按 R12 校验也应报 ACADVER 不符
      final p12 = DxfStructureValidator.validate(oldBug, version: DxfVersion.r12);
      expect(p12.any((s) => s.contains('AC1009')), isTrue, reason: '$p12');
      dir.deleteSync(recursive: true);
    });

    test('SECTION 未闭合 → 报错', () {
      const bad = '0\nSECTION\n2\nENTITIES\n0\nLINE\n8\nL\n10\n0\n20\n0\n';
      final p = DxfStructureValidator.validate(bad, version: DxfVersion.r12);
      expect(p.any((s) => s.contains('未闭合')), isTrue, reason: '$p');
    });

    test('组码悬空（奇数行）→ 报错', () {
      const bad = '0\nSECTION\n2\nENTITIES\n0\nENDSEC\n0\nEOF\n10\n';
      final p = DxfStructureValidator.validate(bad, version: DxfVersion.r12);
      expect(p.any((s) => s.contains('不成对')), isTrue, reason: '$p');
    });

    test('缺 ENTITIES 段 → 报错', () {
      const bad = '0\nSECTION\n2\nHEADER\n9\n\$ACADVER\n1\nAC1009\n0\nENDSEC\n'
          '0\nSECTION\n2\nTABLES\n0\nENDSEC\n'
          '0\nSECTION\n2\nBLOCKS\n0\nENDSEC\n0\nEOF\n';
      final p = DxfStructureValidator.validate(bad, version: DxfVersion.r12);
      expect(p.any((s) => s.contains('ENTITIES')), isTrue, reason: '$p');
    });

    test('缺 HEADER 段 → 报错', () {
      const bad = '0\nSECTION\n2\nENTITIES\n0\nENDSEC\n0\nEOF\n';
      final p = DxfStructureValidator.validate(bad, version: DxfVersion.r12);
      expect(p.any((s) => s.contains('HEADER')), isTrue, reason: '$p');
    });

    test('R2000 实体缺句柄(5) → 报错', () {
      const bad = '0\nSECTION\n2\nHEADER\n9\n\$ACADVER\n1\nAC1015\n'
          '9\n\$HANDSEED\n5\nFF\n0\nENDSEC\n'
          '0\nSECTION\n2\nTABLES\n0\nENDSEC\n'
          '0\nSECTION\n2\nBLOCKS\n0\nENDSEC\n'
          '0\nSECTION\n2\nENTITIES\n'
          '0\nLINE\n100\nAcDbEntity\n8\nL\n100\nAcDbLine\n10\n0\n20\n0\n'
          '0\nENDSEC\n0\nSECTION\n2\nOBJECTS\n0\nENDSEC\n0\nEOF\n';
      final p = DxfStructureValidator.validate(bad, version: DxfVersion.r2000);
      expect(p.any((s) => s.contains('缺句柄')), isTrue, reason: '$p');
    });
  });

  // ================= G2 GeoJSON 恶意/异常输入 =================
  group('G2 GeoJSON 恶意/异常输入（不得崩溃）', () {
    test('非法 JSON → FormatException', () {
      expect(() => GeoJsonImporter.parse('{not json'), throwsFormatException);
    });

    test('空 FeatureCollection → FormatException（无可映射要素）', () {
      expect(() => GeoJsonImporter.parse('{"type":"FeatureCollection","features":[]}'),
          throwsFormatException);
    });

    test('坐标为字符串 → 过滤后无要素 → FormatException，不崩', () {
      // 源码已按契约修复（local_basemap.dart `_pointFrom` 改为类型判定）：
      // 非数值坐标按非法过滤，全无有效点 → parse 抛 FormatException。此处锁死契约防回归。
      const s = '{"type":"FeatureCollection","features":[{"type":"Feature",'
          '"properties":{},"geometry":{"type":"Point","coordinates":["114.1","32.1"]}}]}';
      expect(() => GeoJsonImporter.parse(s), throwsFormatException,
          reason: '非数值坐标须过滤为非法，最终抛 FormatException（不得 TypeError/不得静默产脏数据）');
    });

    test('坐标越界 → 过滤，不崩', () {
      const s = '{"type":"FeatureCollection","features":[{"type":"Feature",'
          '"properties":{"name":"X"},"geometry":{"type":"Point","coordinates":[999,999]}}]}';
      expect(() => GeoJsonImporter.parse(s), throwsFormatException);
    });

    test('MultiPolygon → 拆成多个建筑', () {
      const s = '{"type":"FeatureCollection","features":[{"type":"Feature",'
          '"properties":{"name":"多块"},"geometry":{"type":"MultiPolygon","coordinates":'
          '[[[[114.09,32.12],[114.091,32.12],[114.091,32.121],[114.09,32.12]]],'
          '[[[114.095,32.125],[114.096,32.125],[114.096,32.126],[114.095,32.125]]]]}}]}';
      final bm = GeoJsonImporter.parse(s);
      expect(bm.buildings.length, 2);
    });

    test('GeometryCollection 递归展开', () {
      const s = '{"type":"FeatureCollection","features":[{"type":"Feature",'
          '"properties":{"name":"集合"},"geometry":{"type":"GeometryCollection","geometries":'
          '[{"type":"Point","coordinates":[114.09,32.12]},'
          '{"type":"LineString","coordinates":[[114.09,32.12],[114.091,32.121]]}]}}]}';
      final bm = GeoJsonImporter.parse(s);
      expect(bm.places.length, 1);
      expect(bm.roads.length, 1);
    });
  });

  // ================= G3 本地导入端到端 =================
  group('G3 本地 GeoJSON 导入端到端（离线出图）', () {
    test('导入→保存→载入→导出 R12/R2000，落盘 build/qa_e2e', () async {
      final outDir = Directory('${Directory.current.path}/build/qa_e2e');
      if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      outDir.createSync(recursive: true);
      PathProviderPlatform.instance = _FakePathProvider(outDir.path);

      // 1) 解析自造 GeoJSON
      final bm = GeoJsonImporter.parse(_myGeoJson);
      expect(bm.buildings.length, 1, reason: '1 个带孔 Polygon 建筑');
      expect(bm.roads.length, 1, reason: '1 条 LineString 道路');
      expect(bm.places.length, 1, reason: '1 个 Point 地名');

      // 2) 本地存储往返（项目级离线复用）
      final store = LocalBasemapStore(Directory('${outDir.path}/loc'));
      store.root.createSync(recursive: true);
      await store.save(_myGeoJson,
          sourceName: 'qa.geojson',
          roads: bm.roads.length,
          buildings: bm.buildings.length,
          places: bm.places.length);
      expect(store.exists(), isTrue);
      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.buildings.length, 1);

      // 3) 两版本导出（includeSurroundings + localBasemap → 完全离线，无网络调用）
      for (final v in DxfVersion.values) {
        final r = await DxfExporter.export(
            name: 'qa_local_${v.name}',
            labels: _poles(),
            includeSurroundings: true,
            localBasemap: loaded,
            // 显式给足范围：本用例验「注入的底图能进 DXF」，与 UI 默认范围无关
            // （v3.7.2 起 UI 默认 100m）。
            rangeM: 880,
            version: v,
            buildingFill: true); // 显式开启：继续覆盖填充路径
        final text = gbk_bytes.decode(r.file.readAsBytesSync());
        final ents = _parse(text);
        int cnt(String layer) => ents.where((e) => e.first('8') == layer).length;
        // 底图图层必须都有实体（证明建筑/地名真的进图了）
        expect(cnt('JianZhu'), greaterThan(0), reason: '${v.name} 无建筑轮廓');
        expect(cnt('JianZhuFill'), greaterThan(0), reason: '${v.name} 无建筑填充');
        expect(cnt('DiMing'), greaterThan(0), reason: '${v.name} 无地名');
        expect(cnt('DaoLuBian'), greaterThan(0), reason: '${v.name} 无道路边线');
        // 道路中心线已按新规格删除：任何版本都不得再输出 DaoLuZhong 实体
        expect(cnt('DaoLuZhong'), equals(0),
            reason: '${v.name} 不应输出道路中心线（DaoLuZhong 已删除）');
        // 复制到固定目录供 python 复核
        final keep = File('${outDir.path}/${v.name}_local.dxf');
        keep.writeAsBytesSync(r.file.readAsBytesSync());
        // ignore: avoid_print
        print('QA_E2E ${v.name}: JianZhu=${cnt('JianZhu')} '
            'JianZhuFill=${cnt('JianZhuFill')} DiMing=${cnt('DiMing')} '
            'DaoLuBian=${cnt('DaoLuBian')} DaoLuZhong=${cnt('DaoLuZhong')} '
            '-> ${keep.path}');
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
