// 图例库（lispblock.dxf）接入的端到端验证。
//
// 覆盖三件事：
//  1. 解析器能从真实 AC1021 图例里读出"块 + 名字"表；
//  2. 符号目录把图块变成一个可用的 LabelType（id=块编号, name=图例文字）；
//  3. 导出 DXF 时**真的写入了块定义并 INSERT 了该块**，且 R12 结构依旧合法
//     （不出现 LWPOLYLINE/HATCH/370/420 —— 图例库是 2007 文件，直接抄会翻车）。
import 'dart:convert' show latin1;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart' show gbk_bytes;
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_validate.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/models/label_type.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/symbols/dxf_block_parser.dart';
import 'package:ovimap/symbols/symbol_catalog.dart';

/// 真实图例库文件（仓库内随包资源）。
File _asset() => File('assets/dxf/lispblock.dxf');

/// 最小可用的合成 DXF：块 + 图例 + 嵌套 INSERT + MTEXT 格式码。
///
/// 真实资源缺失时（例如裁剪过的发布包）仍能跑通解析/导出链路，
/// 不必让 CI 依赖一个 1.9MB 的二进制资产。
const String _miniDxf = '''
  0
SECTION
  2
HEADER
  9
\$ACADVER
  1
AC1021
  0
ENDSEC
  0
SECTION
  2
BLOCKS
  0
BLOCK
  8
0
  2
test001
 70
     0
 10
0.0
 20
0.0
 30
0.0
  3
test001
  0
LINE
  8
0
 10
-1.5
 20
0.0
 30
0.0
 11
1.5
 21
0.0
 31
0.0
  0
CIRCLE
  8
0
 10
0.0
 20
0.0
 30
0.0
 40
1.2
  0
MTEXT
  8
0
 10
0.0
 20
-0.5
 30
0.0
 40
1.0
  1
\\fSimSun;{\\H0.8x;杆}
  0
ENDBLK
  8
0
  0
BLOCK
  8
0
  2
test002
 70
     0
 10
0.0
 20
0.0
 30
0.0
  3
test002
  0
INSERT
  8
0
  2
test001
 10
2.0
 20
0.0
 30
0.0
  0
ENDBLK
  8
0
  0
ENDSEC
  0
SECTION
  2
ENTITIES
  0
INSERT
  8
0
  2
test001
 10
100.0
 20
100.0
 30
0.0
  0
TEXT
  8
0
 10
120.0
 20
100.0
 30
0.0
 40
2.5
  1
测试水泥杆
  0
INSERT
  8
0
  2
test002
 10
100.0
 20
80.0
 30
0.0
  0
TEXT
  8
0
 10
120.0
 20
80.0
 30
0.0
 40
2.5
  1
测试木杆
  0
ENDSEC
  0
EOF
''';

void main() {
  group('DXF 图块解析（归一化）', () {
    test('合成 DXF：读出块、嵌套内联、清掉 MTEXT 格式码', () {
      final r = DxfBlockParser.parse(_miniDxf);
      expect(r.blocks.containsKey('test001'), isTrue);
      expect(r.blocks.containsKey('test002'), isTrue);

      final b1 = r.blocks['test001']!;
      // LINE + CIRCLE + TEXT(由 MTEXT 降维) = 3 条
      expect(b1.strokes.length, 3);
      final texts = b1.strokes.whereType<SymbolText>().toList();
      expect(texts.length, 1);
      expect(texts.first.text, '杆', reason: r'\\fSimSun;{\\H0.8x;} 必须被洗掉');

      // 嵌套 INSERT 必须**内联**：test002 只有 1 个 INSERT，但应展开出 3 条几何，
      // 且整体沿 +x 平移了 2。
      final b2 = r.blocks['test002']!;
      expect(b2.strokes.length, 3);
      expect(b2.nested, contains('test001'));
      final circle =
          b2.strokes.whereType<SymbolCircle>().first;
      expect(circle.cx, closeTo(2.0, 1e-6), reason: '嵌套插入的平移必须生效');

      // 图例：两条 INSERT 各自配上了紧邻的中文名，而不是配到英文编号。
      final byBlock = {for (final e in r.legend) e.block: e.label};
      expect(byBlock['test001'], '测试水泥杆');
      expect(byBlock['test002'], '测试木杆');
    });

    test('循环引用不炸栈（A 引 B、B 引 A）', () {
      const cyclic = '''
  0
SECTION
  2
BLOCKS
  0
BLOCK
  8
0
  2
a
 10
0.0
 20
0.0
  0
INSERT
  8
0
  2
b
 10
0.0
 20
0.0
  0
ENDBLK
  8
0
  0
BLOCK
  8
0
  2
b
 10
0.0
 20
0.0
  0
INSERT
  8
0
  2
a
 10
0.0
 20
0.0
  0
ENDBLK
  8
0
  0
ENDSEC
  0
EOF
''';
      final r = DxfBlockParser.parse(cyclic);
      expect(r.blocks.keys, containsAll(['a', 'b']));
      expect(r.warnings, isNotEmpty);
    });

    test('CRLF 文件也要能解析（行尾 \\r 曾让整份文件读出 0 个块）', () {
      final crlf = _miniDxf.replaceAll('\n', '\r\n');
      final r = DxfBlockParser.parse(crlf);
      expect(r.blocks.length, 2);
      expect(r.legend.length, 2);
    });

    test('真实图例库：89 个块 → 22 条图例名（名字来自图例文字，不是编号）', () {
      final f = _asset();
      if (!f.existsSync()) {
        markTestSkipped('assets/dxf/lispblock.dxf 不在，跳过真实资产校验');
        return;
      }
      final r = DxfBlockParser.parse(f.readAsStringSync());
      expect(r.blocks.length, greaterThan(80));
      final byBlock = {for (final e in r.legend) e.block: e.label};
      expect(byBlock['gl001'], '新建水泥杆');
      expect(byBlock['gl004'], '原有木杆');
      expect(byBlock['gx005_x'], '新建人井');
      expect(byBlock['lx001'], '新建拉线');
      // 编号本身绝不能被当成名字（否则符号库里全是 gl001/gl002）
      expect(byBlock.values, isNot(contains('gl001')));
    });

    test('LWPOLYLINE 凸度（bulge）必须展开成圆弧，不能退化成直径直线', () {
      final f = _asset();
      if (!f.existsSync()) {
        markTestSkipped('assets/dxf/lispblock.dxf 不在，跳过');
        return;
      }
      final r = DxfBlockParser.parse(f.readAsStringSync());
      final gl001 = r.blocks['gl001']!;
      // gl001 在源文件里是「HATCH 边界 = 2 顶点 bulge=1.0（两个半圆）+ CIRCLE」。
      // 只取 10/20 会画成一条 3.15 长的横线（历史 bug）；正确展开是整圆。
      expect(gl001.width, closeTo(3.15, 0.05));
      expect(gl001.height, closeTo(3.15, 0.05),
          reason: '凸度没展开时高度会是 0（一条横线）');
      // 顶点数够多才说明是折线拟合的圆，而不是 2 点直线
      final poly = gl001.strokes.whereType<SymbolPoly>().first;
      expect(poly.pts.length, greaterThan(12), reason: '圆弧应被采样成多段');
      // 采样点应覆盖四个象限（是整圆而非半圆）
      final xs = poly.pts.map((p) => p[0]).toList();
      final ys = poly.pts.map((p) => p[1]).toList();
      expect(xs.reduce((a, b) => a < b ? a : b), lessThan(-1.4));
      expect(xs.reduce((a, b) => a > b ? a : b), greaterThan(1.4));
      expect(ys.reduce((a, b) => a < b ? a : b), lessThan(-1.4));
      expect(ys.reduce((a, b) => a > b ? a : b), greaterThan(1.4));
    });

    test('HATCH 边界不能吃到种子点（否则边界多出一条横杠）', () {
      final f = _asset();
      if (!f.existsSync()) {
        markTestSkipped('assets/dxf/lispblock.dxf 不在，跳过');
        return;
      }
      final r = DxfBlockParser.parse(f.readAsStringSync());
      // 源文件里 gl001 的 HATCH 头部有图案基点 (0,0)、边界 2 顶点、种子点
      // (-0.0007,-0.045)。若把种子点当顶点，包络盒会多出一块偏移。
      final gl001 = r.blocks['gl001']!;
      // 对称性是"只吃了边界"的强证据：横竖中心都应≈0
      final cx = (gl001.minX + gl001.maxX) / 2;
      final cy = (gl001.minY + gl001.maxY) / 2;
      expect(cx.abs(), lessThan(0.1));
      expect(cy.abs(), lessThan(0.1));
    });
  });

  group('符号目录 → LabelType', () {
    test('块编号成为 id、图例文字成为 name、按组归栏', () {
      final cat = SymbolCatalog.fromTextSync(_miniDxf);
      final n = LabelType.installCatalog(cat);
      expect(n, 2);

      final t1 = LabelType.fromId('test001');
      expect(t1.id, 'test001');
      expect(t1.name, '测试水泥杆', reason: '名字取图例文字，不取块名');
      expect(t1.isBlock, isTrue);
      expect(t1.group, '杆', reason: '名称含"杆"应归入杆组');

      final t2 = LabelType.fromId('test002');
      expect(t2.name, '测试木杆');
      expect(t2.isBlock, isTrue);
    });

    test('预置符号仍在（老工程 typeId 不能失配）', () {
      final cat = SymbolCatalog.fromTextSync(_miniDxf);
      LabelType.installCatalog(cat);
      for (final id in const [
        'pipe', 'concrete', 'wood', 'electric', 'manhole', 'handwell',
        'fiberbox', 'splitterbox', 'onubox', 'crossbox', 'riser', 'room',
        'bts', 'track', 'none', 'text',
      ]) {
        expect(LabelType.all.any((t) => t.id == id), isTrue,
            reason: '预置符号 $id 必须保留');
      }
      // 未知 id 仍回退管道口（旧工程容错口径不变）
      expect(LabelType.fromId('no_such_block').id, 'pipe');
    });

    test('整幅/线性图元不进符号库（标题栏、铁路不是点符号）', () {
      final f = _asset();
      if (!f.existsSync()) {
        markTestSkipped('assets/dxf/lispblock.dxf 不在，跳过');
        return;
      }
      final cat = SymbolCatalog.fromTextSync(f.readAsStringSync());
      final ids = cat.symbols.map((s) => s.blockId).toSet();
      expect(ids, contains('gl001'));
      expect(ids, contains('gx005_x'));
      expect(ids, isNot(contains('TK_A1_001')), reason: '841×594 标题栏不是点符号');
      expect(ids, isNot(contains('铁路')), reason: '374×170 线性图元不是点符号');
    });
  });

  group('DXF 导出：用图例库图块当符号', () {
    late Directory tmp;

    setUp(() async {
      // ⚠️ 必须初始化 binding + 注入临时目录：
      // DxfExporter.export() 会走 LabelStore.exportDir() → AppPaths.baseDir()。
      // Windows 上 baseDir() 有 %APPDATA% 快路径（不碰插件），所以**本机跑得过**；
      // Linux/macOS 没这条快路径，会真的调用 path_provider MethodChannel，
      // 未初始化 binding 就直接抛 "Binding has not yet been initialized"。
      // 这正是"本机绿、CI 红"的典型平台差异，必须显式处理。
      TestWidgetsFlutterBinding.ensureInitialized();
      tmp = Directory.systemTemp.createTempSync('ovimap_lispblock');
      LabelStore.instance.setBaseDirForTest(tmp);
      LabelType.installCatalog(SymbolCatalog.fromTextSync(
          _asset().existsSync() ? _asset().readAsStringSync() : _miniDxf));
    });

    tearDown(() {
      AppPaths.clearForTest();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('R12：写出块定义 + INSERT 真块，且结构校验通过', () async {
      final labels = [
        MapLabel(typeId: 'gl001', seq: 1, lat: 32.0, lon: 114.0,
            lineGroupId: 'g', name: 'GK-1'),
        MapLabel(typeId: 'gl001', seq: 2, lat: 32.0005, lon: 114.0,
            lineGroupId: 'g', name: 'GK-2'),
      ];
      final r = await DxfExporter.export(
          name: 'lispblock_r12', labels: labels, version: DxfVersion.r12);
      final text = _readGbk(r.file);

      // 块定义在 BLOCKS 段里，且 BLOCK 名就是图块编号
      final blocksSection = _section(text, 'BLOCKS');
      expect(blocksSection, contains('2\ngl001\n'),
          reason: '必须写出 gl001 块定义');
      // 实体段里 INSERT 了 gl001
      final entities = _section(text, 'ENTITIES');
      expect(entities, contains('2\ngl001\n'), reason: '必须 INSERT gl001');
      // 结构合法（这正是"2007 实体表抄进 R12 会翻车"的防线）
      expect(DxfStructureValidator.validate(text, version: DxfVersion.r12),
          isEmpty);
      // R12 严禁项一个都不许出现（图例库原件里 LWPOLYLINE/HATCH 遍地都是）
      expect(entities, isNot(contains('LWPOLYLINE')));
      expect(entities, isNot(contains('HATCH')));
      expect(text, isNot(contains('\n370\n')));
      expect(text, isNot(contains('\n420\n')));
    });

    test('R2000：同样能写出块定义 + INSERT，并通过 R2000 结构校验', () async {
      final labels = [
        MapLabel(typeId: 'gl001', seq: 1, lat: 32.0, lon: 114.0,
            lineGroupId: 'g'),
        MapLabel(typeId: 'gx005_x', seq: 2, lat: 32.0005, lon: 114.0,
            lineGroupId: 'g'),
      ];
      final r = await DxfExporter.export(
          name: 'lispblock_r2000', labels: labels, version: DxfVersion.r2000);
      final text = _readGbk(r.file);
      expect(_section(text, 'BLOCKS'), contains('2\ngl001\n'));
      expect(_section(text, 'BLOCKS'), contains('2\ngx005_x\n'));
      expect(DxfStructureValidator.validate(text, version: DxfVersion.r2000),
          isEmpty);
    });

    test('未使用的图例块不写进文件（体积与可读性）', () async {
      final labels = [
        MapLabel(typeId: 'gl001', seq: 1, lat: 32.0, lon: 114.0,
            lineGroupId: 'g'),
        MapLabel(typeId: 'gl001', seq: 2, lat: 32.0005, lon: 114.0,
            lineGroupId: 'g'),
      ];
      final r = await DxfExporter.export(
          name: 'lispblock_minimal', labels: labels, version: DxfVersion.r12);
      final text = _readGbk(r.file);
      final blocks = _section(text, 'BLOCKS');
      expect(blocks, contains('2\ngl001\n'));
      expect(blocks, isNot(contains('2\ngx005_x\n')),
          reason: '没用到的人井块不该被写进去');
    });

    test('图例栏也用真块（图例 INSERT 与图上 INSERT 同名）', () async {
      final labels = [
        MapLabel(typeId: 'gl001', seq: 1, lat: 32.0, lon: 114.0,
            lineGroupId: 'g'),
        MapLabel(typeId: 'gl001', seq: 2, lat: 32.0005, lon: 114.0,
            lineGroupId: 'g'),
      ];
      final r = await DxfExporter.export(
          name: 'lispblock_legend',
          labels: labels,
          version: DxfVersion.r12,
          showLegend: true);
      final text = _readGbk(r.file);
      // 图例层 TuQian 上的 INSERT 必须引用 gl001
      expect(text, contains('0\nINSERT\n8\nTuQian\n2\ngl001\n'),
          reason: '图例栏必须用真图块，不能退回 HZ_* 近似块');
      // 图例标题是中文，走 GBK 解码单独验（latin1 只保结构，见 _readGbk 注释）
      expect(_readGbkText(r.file), contains('图  例'),
          reason: '图例栏标题必须写出');
    });

    test('混用预置符号 + 图例块：两种块定义同时存在且互不影响', () async {
      final labels = [
        MapLabel(typeId: 'pipe', seq: 1, lat: 32.0, lon: 114.0,
            lineGroupId: 'g'),
        MapLabel(typeId: 'gl001', seq: 2, lat: 32.0005, lon: 114.0,
            lineGroupId: 'g'),
      ];
      final r = await DxfExporter.export(
          name: 'lispblock_mixed', labels: labels, version: DxfVersion.r12);
      final text = _readGbk(r.file);
      final blocks = _section(text, 'BLOCKS');
      expect(blocks, contains('2\ngl001\n'));
      final entities = _section(text, 'ENTITIES');
      expect(entities, contains('2\ngl001\n'));
      expect(DxfStructureValidator.validate(text, version: DxfVersion.r12),
          isEmpty);
    });
  });
}

/// 读 GBK 写盘文件，按**单字节**解码以保留 ASCII 结构。
///
/// ⚠️ 必须用 `latin1`，不能用 `SystemEncoding`：
/// `SystemEncoding` 是"当前平台默认编码"——Windows 上是 GBK/CP936（能读），
/// Linux/macOS 上是 UTF-8（遇到 GBK 高位字节直接抛
/// `Failed to decode data using encoding 'system'`）。
/// 这正是"本机 Windows 绿、CI Linux 红"的第二处平台差异。
///
/// 用 latin1 做 1:1 字节→码点映射，组码与块名（全 ASCII）可正常断言；
/// 中文内容要校验时另行按 GBK 解码，本文件只断言结构。
String _readGbk(File f) => f.readAsStringSync(encoding: latin1);

/// 按 GBK 解码读取（用于断言中文内容）。
///
/// 导出器以 ANSI_936 落盘，中文必须用 GBK 解码才对得上；
/// 但 GBK 解码会把结构字节也解释掉，所以**仅用于中文文本断言**，
/// 结构断言一律走 [_readGbk]（latin1）。
String _readGbkText(File f) => gbk_bytes.decode(f.readAsBytesSync());

/// 取某一 SECTION 的正文（`0\nSECTION\n2\n<name>` 到 `ENDSEC`）。
String _section(String dxf, String name) {
  final marker = '0\nSECTION\n2\n$name\n';
  final i = dxf.indexOf(marker);
  if (i < 0) return '';
  final j = dxf.indexOf('0\nENDSEC', i);
  return j < 0 ? dxf.substring(i) : dxf.substring(i, j);
}
