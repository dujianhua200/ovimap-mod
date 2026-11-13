/// 出图口径验收：固定比例 / 多段线 0.5mm / 符号处断开 / 无名称 / 宋体。
///
/// 产物用于 `tool/render_*.py` 目视核对，并由 `tools/validate_*` 结构校验。
import 'dart:convert' show latin1;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart' show gbk_bytes;
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_validate.dart';
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
    tmp = Directory.systemTemp.createTempSync('ovimap_spec');
    LabelStore.instance.setBaseDirForTest(tmp);
    final asset = File('assets/dxf/lispblock.dxf');
    expect(asset.existsSync(), isTrue);
    LabelType.installCatalog(
        SymbolCatalog.fromTextSync(asset.readAsStringSync()));
  });

  tearDown(() => AppPaths.clearForTest());

  /// 一条 5 杆链（全部用图例块 gl001 新建水泥杆）。
  List<MapLabel> chain() => [
        for (var i = 0; i < 5; i++)
          MapLabel(
            typeId: 'gl001',
            seq: i + 1,
            lat: 32.0 + i * 0.0004,
            lon: 114.0 + i * 0.0006,
            lineGroupId: 'g',
            name: 'GK-${i + 1}',
          ),
      ];

  test('固定 1:3000：字高/符号按 3000 换算，不随线路长度漂移', () async {
    final r = await DxfExporter.export(
      name: 'spec_1_3000',
      labels: chain(),
      version: DxfVersion.r12,
      fixedScale: 3000,
      showLabelNames: false,
      showLegend: false,
    );
    final txt = latin1.decode(r.file.readAsBytesSync());
    expect(DxfStructureValidator.validate(txt, version: DxfVersion.r12),
        isEmpty);
    // 图签里应写明比例 1:3000（说明 fixedScale 真的生效，不是自动估的）
    final gbk = gbk_bytes.decode(r.file.readAsBytesSync());
    expect(gbk, contains('1:3000'));
  });

  test('自动比例（fixedScale=0/null）仍可用：退回按范围估算', () async {
    final r = await DxfExporter.export(
      name: 'spec_auto',
      labels: chain(),
      version: DxfVersion.r12,
      showLegend: false,
    );
    final txt = latin1.decode(r.file.readAsBytesSync());
    expect(DxfStructureValidator.validate(txt, version: DxfVersion.r12),
        isEmpty);
    expect(txt, isNot(contains('1:3000')),
        reason: '未指定固定比例时不应写死 1:3000');
  });

  test('杆路是多段线且带 0.5mm 全局宽度（组码 40/41）', () async {
    final r = await DxfExporter.export(
      name: 'spec_width',
      labels: chain(),
      version: DxfVersion.r12,
      fixedScale: 3000,
      rodLineWidthMm: 0.5,
      showLegend: false,
    );
    final txt = latin1.decode(r.file.readAsBytesSync());
    // 按实体切分：每个实体以 "0\n<TYPE>\n" 开头
    final ents = _entities(_section(txt, 'ENTITIES'));
    final ganLu = ents.where((e) => e.layer == 'GanLu').toList();
    expect(ganLu, isNotEmpty, reason: '必须有 GanLu 层实体');
    // 多段线由 POLYLINE + 若干 VERTEX (+SEQEND) 组成；关键是**没有裸 LINE**
    // （逐段画 LINE 才是用户要摆脱的旧行为）。
    final types = ganLu.map((e) => e.type).toSet();
    expect(types.contains('LINE'), isFalse,
        reason: '杆路不得是逐段 LINE；实际类型：$types');
    expect(types.contains('POLYLINE'), isTrue,
        reason: '杆路必须是多段线；实际类型：$types');
    // v3.12 口径（对齐用户插件）：纸面毫米直接=图纸单位 → 0.5mm 就是 0.5
    expect(txt, contains('40\n0.500\n'),
        reason: '全局宽度 0.5mm 应直接写 0.5（与插件一致，不再 ×比例）');
  });

  test('符号处断开：线不穿过符号本体（在符号边缘停止）', () async {
    // 两点相距约 44m，符号半宽 1.55mm@1:3000 ≈ 4.65m：
    // 断开后每条子段两端各缩进 4.65m → 可见子段约 34.7m，远小于原始 44m。
    final pair = [
      MapLabel(typeId: 'gl001', seq: 1, lat: 32.0, lon: 114.0,
          lineGroupId: 'g', name: 'A'),
      MapLabel(typeId: 'gl001', seq: 2, lat: 32.0004, lon: 114.0,
          lineGroupId: 'g', name: 'B'),
    ];
    final r = await DxfExporter.export(
      name: 'spec_gap',
      labels: pair,
      version: DxfVersion.r12,
      fixedScale: 3000,
      showLegend: false,
    );
    final txt = latin1.decode(r.file.readAsBytesSync());
    final polys = _polylines(_section(txt, 'ENTITIES'), 'GanLu');
    expect(polys, isNotEmpty, reason: '应有杆路多段线');

    // 断开效果：可见跨距应比原始间距**短掉两个符号半宽**。
    //
    // v3.12 口径：图块按 1:1 插入 → gl001 半宽 = 1.575 图纸单位
    // （旧口径 ×3 时是 4.65）。原始间距 44.2，缩进后约 44.2-3.15≈41.05。
    final all = [for (final p in polys) ...p];
    expect(all.length, greaterThanOrEqualTo(2), reason: '应有可量长度');
    final span = _len(all);
    const original = 44.2;
    expect(span, lessThan(original - 2.5),
        reason: '断开后可见跨距应短于原始间距（两端各缩进符号半宽），实际 $span');
    expect(span, greaterThan(original - 5.0),
        reason: '缩进量应≈两个符号半宽（1.575×2≈3.15），实际 $span');
  });

  test('两点完全重合：不画零长线（避免垃圾实体）', () async {
    final same = [
      MapLabel(typeId: 'gl001', seq: 1, lat: 32.0, lon: 114.0,
          lineGroupId: 'g', name: 'A'),
      MapLabel(typeId: 'gl001', seq: 2, lat: 32.0, lon: 114.0,
          lineGroupId: 'g', name: 'B'),
    ];
    final r = await DxfExporter.export(
      name: 'spec_same',
      labels: same,
      version: DxfVersion.r12,
      fixedScale: 3000,
      showLegend: false,
    );
    final txt = latin1.decode(r.file.readAsBytesSync());
    final polys = _polylines(_section(txt, 'ENTITIES'), 'GanLu');
    expect(polys, isEmpty, reason: '重合点不应产生线实体');
    expect(DxfStructureValidator.validate(txt, version: DxfVersion.r12),
        isEmpty);
  });

  test('showLabelNames=false：不写「原」等名称文字', () async {
    final labels = chain();
    // 名称固定为「原」——正是用户抱怨的那个字
    for (final l in labels) {
      l.name = '原';
    }
    final off = await DxfExporter.export(
      name: 'spec_noname_off',
      labels: labels,
      version: DxfVersion.r12,
      fixedScale: 3000,
      showLabelNames: false,
      showLegend: false,
      showStakes: false,
    );
    final offTxt = gbk_bytes.decode(off.file.readAsBytesSync());
    // 「原」只可能来自我们写的名称文字；块内代号字是「水」等
    expect(offTxt, isNot(contains('\n1\n原\n')),
        reason: 'showLabelNames=false 时不应写出名称「原」');

    final on = await DxfExporter.export(
      name: 'spec_noname_on',
      labels: labels,
      version: DxfVersion.r12,
      fixedScale: 3000,
      showLabelNames: true,
      showLegend: false,
      showStakes: false,
    );
    final onTxt = gbk_bytes.decode(on.file.readAsBytesSync());
    expect(onTxt, contains('原'),
        reason: 'showLabelNames=true 时应当写出名称（对照）');
  });

  test('文字样式指向 simsun.ttc（宋体），不是不存在的 SimSun.ttf', () async {
    final r = await DxfExporter.export(
      name: 'spec_font',
      labels: chain(),
      version: DxfVersion.r12,
      fixedScale: 3000,
      showLegend: false,
    );
    final txt = latin1.decode(r.file.readAsBytesSync());
    expect(txt, contains('simsun.ttc'));
    expect(txt, isNot(contains('SimSun.ttf')),
        reason: 'SimSun.ttf 在多数系统不存在，CAD 会回退到默认字体（看着难受）');
  });

  test('生成目视核对样本（out/spec_*.dxf）', () async {
    Directory('out').createSync(recursive: true);
    for (final v in [DxfVersion.r12, DxfVersion.r2000]) {
      final r = await DxfExporter.export(
        name: 'spec_${v.name}',
        labels: chain(),
        version: v,
        fixedScale: 3000,
        rodLineWidthMm: 0.5,
        showLabelNames: false,
        showLegend: true,
      );
      r.file.copySync('out/spec_${v.name}.dxf');
    }
  });
}

String _section(String dxf, String name) {
  final marker = '0\nSECTION\n2\n$name\n';
  final i = dxf.indexOf(marker);
  if (i < 0) return '';
  final j = dxf.indexOf('0\nENDSEC', i);
  return j < 0 ? dxf.substring(i) : dxf.substring(i, j);
}

/// 取指定图层上所有多段线，**按折线分组**返回顶点。
///
/// R12 结构：`POLYLINE … 0 VERTEX … 0 SEQEND`（SEQEND 结束一条）。
/// 符号处断开会产生**多条** POLYLINE，必须先分组再量长，
/// 否则会把不相邻折线的首尾也算进长度（虚高）。
/// 取指定图层上所有多段线，按折线分组返回顶点。
///
/// ⚠️ 不能用 `split('\n0\n')` 切实体：DXF 的值行里也可能出现 "0"
/// （例如组码 `70` 的值为 `0`），会把实体错位 —— 这是 DXF 解析的经典坑。
/// 正确读法是**按行对**（组码/值成对）顺序推进。
List<List<List<double>>> _polylines(String entities, String layer) {
  final lines = entities.split('\n');
  final out = <List<List<double>>>[];

  var inPoly = false; // 正在读一条 POLYLINE
  var wantLayer = false; // 该 POLYLINE 的图层是否匹配
  var inVertex = false;
  String? vx;
  var cur = <List<double>>[];

  void flush() {
    if (cur.isNotEmpty) out.add(cur);
    cur = <List<double>>[];
  }

  for (var i = 0; i + 1 < lines.length; i += 2) {
    final code = lines[i].trim();
    final value = lines[i + 1].trim();
    if (code == '0') {
      final t = value;
      if (inPoly && (t == 'POLYLINE' || t == 'SEQEND')) {
        flush();
        inPoly = false;
        wantLayer = false;
        inVertex = false;
      } else if (t == 'POLYLINE') {
        flush();
        inPoly = true;
        wantLayer = false;
        inVertex = false;
      } else if (t == 'VERTEX') {
        inVertex = true;
        vx = null;
      } else if (t == 'SEQEND') {
        flush();
        inPoly = false;
        wantLayer = false;
        inVertex = false;
      } else {
        inVertex = false;
      }
      continue;
    }
    if (inPoly && !inVertex && code == '8') {
      wantLayer = value == layer;
      continue;
    }
    if (inVertex && wantLayer) {
      if (code == '10') {
        vx = value;
      } else if (code == '20') {
        final x = double.tryParse(vx ?? '');
        final y = double.tryParse(value);
        if (x != null && y != null) cur.add([x, y]);
        vx = null;
      }
    }
  }
  flush();
  return out;
}

double _len(List<List<double>> pts) {
  var sum = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final dx = pts[i][0] - pts[i - 1][0];
    final dy = pts[i][1] - pts[i - 1][1];
    sum += math.sqrt(dx * dx + dy * dy);
  }
  return sum;
}

class _Ent {
  final String type;
  final String body;
  _Ent(this.type, this.body);

  /// 组码 8 的值（图层）。
  String get layer {
    final m = RegExp(r'\n8\n([^\n]*)\n').firstMatch('\n$body');
    return m?.group(1) ?? '';
  }
}

/// 把 ENTITIES 段切成实体列表（每个以 `0\nTYPE` 起始）。
List<_Ent> _entities(String entitiesSection) {
  final out = <_Ent>[];
  final parts = entitiesSection.split('\n0\n');
  for (final p in parts.skip(1)) {
    final nl = p.indexOf('\n');
    if (nl < 0) continue;
    out.add(_Ent(p.substring(0, nl).trim(), p.substring(nl + 1)));
  }
  return out;
}
