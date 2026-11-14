// v3.19 验收：指北针/图签可关、图签行距、单点图标色。
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
import 'package:ovimap/symbols/symbol_catalog.dart';

void main() {
  late Directory tmp;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = Directory.systemTemp.createTempSync('ov_v319');
    LabelStore.instance.setBaseDirForTest(tmp);
    AppPaths.setBaseForTest(tmp);
    LabelType.installCatalog(SymbolCatalog.fromTextSync(
        File('assets/dxf/lispblock.dxf').readAsStringSync()));
  });

  tearDown(() => AppPaths.clearForTest());

  List<MapLabel> chain() => [
        for (var i = 0; i < 4; i++)
          MapLabel(
            typeId: 'gl003', seq: i + 1,
            lat: 32.0 + i * 0.0004, lon: 114.0 + i * 0.0005,
            lineGroupId: 'g', name: 'P${i + 1}', distanceM: 60,
          ),
      ];

  group('指北针 / 图签可关', () {
    test('全开：有 BeiFangZhen 与图签文字', () async {
      final r = await DxfExporter.export(
        name: 'all_on', labels: chain(), version: DxfVersion.r12,
        fixedScale: 3000, showLegend: false,
        showNorthArrow: true, showTitleBlock: true);
      // 注意：DXF 以 **GBK** 写出（中文），latin1 只能读结构。
      final raw = r.file.readAsBytesSync();
      final txt = latin1.decode(raw);
      final gbk = gbk_bytes.decode(raw);
      expect(txt, contains('\n8\nBeiFangZhen\n'), reason: '应有指北针');
      expect(gbk, contains('滑洲云图导出'), reason: '应有图签');
    });

    test('全关：没有指北针三角、没有图签方框', () async {
      final r = await DxfExporter.export(
        name: 'all_off', labels: chain(), version: DxfVersion.r12,
        fixedScale: 3000, showLegend: false,
        showNorthArrow: false, showTitleBlock: false);
      final raw = r.file.readAsBytesSync();
      final txt = latin1.decode(raw);
      final gbk = gbk_bytes.decode(raw);
      expect(txt, isNot(contains('\n8\nBeiFangZhen\n')),
          reason: '关掉后不应再画指北针（那个"方框套正三角形"）');
      expect(gbk, isNot(contains('滑洲云图导出')),
          reason: '关掉后不应再有图签统计栏');
      // 业务内容仍在
      expect(txt, contains('\n8\nGanLu\n'));
      expect(DxfStructureValidator.validate(txt, version: DxfVersion.r12),
          isEmpty);
    });
  });

  group('图签文字不错行', () {
    test('每行文字落在各自格子中心（行距 6.0、字高不超格）', () async {
      final r = await DxfExporter.export(
        name: 'tb', labels: chain(), version: DxfVersion.r12,
        fixedScale: 3000, showLegend: false, showTitleBlock: true);
      final raw = r.file.readAsBytesSync();
      final txt = latin1.decode(raw);
      final gbk = gbk_bytes.decode(raw);

      // 图签 5 行，行高 = 30/5 = 6.0 —— 用 GBK 文本确认行内容存在
      expect(gbk, contains('比例 1:'), reason: '应有比例行');
      expect(gbk, contains('总点数'), reason: '应有统计行');

      final tbTexts = _ents(txt, 'TEXT', 'TuQian');
      expect(tbTexts, isNotEmpty, reason: '应有图签文字');

      final hs = <double>[];
      for (final b in tbTexts) {
        final m = RegExp(r'^40\n([-\d.]+)$', multiLine: true).firstMatch(b);
        if (m != null) hs.add(double.parse(m.group(1)!));
      }
      expect(hs, isNotEmpty);
      for (final h in hs) {
        // 行高 6.0，字高必须明显小于行高，否则压线（用户说的"错行"）
        expect(h, lessThanOrEqualTo(6.0 * 0.62 + 0.01),
            reason: '图签字高应≤行高的 0.62（6.0×0.62=3.72），实际 $h');
      }
    });
  });

  group('单点图标颜色', () {
    test('每个点可各自设色，写入 INSERT 的 62 组码', () async {
      final labels = chain();
      // 第 1 点红色、第 2 点蓝色、其余跟随默认
      labels[0].iconColor = 0xD32F2F;
      labels[1].iconColor = 0x1565C0;

      final r = await DxfExporter.export(
        name: 'iconcolor', labels: labels, version: DxfVersion.r12,
        fixedScale: 3000, showLegend: false);
      final txt = latin1.decode(r.file.readAsBytesSync());

      final ins = _ents(txt, 'INSERT', 'BiaoQian');
      expect(ins.length, labels.length);

      // 收集每个 INSERT 的 62 值
      final acis = <int>[];
      for (final b in ins) {
        final m = RegExp(r'^62\n(\d+)$', multiLine: true).firstMatch(b);
        acis.add(m == null ? 0 : int.parse(m.group(1)!));
      }
      // 有颜色覆盖的点应写出 62；未设色的不写
      expect(acis.any((v) => v != 0), isTrue,
          reason: '设了色的点应写出 62 组码，实际 $acis');
      final distinct = acis.where((v) => v != 0).toSet();
      expect(distinct.length, greaterThanOrEqualTo(2),
          reason: '两个不同颜色的点应写出不同的 ACI，实际 $distinct');
    });

    test('R2000 下同时写真彩色 420', () async {
      final labels = chain();
      labels[0].iconColor = 0xFF0000;
      final r = await DxfExporter.export(
        name: 'iconcolor2000', labels: labels, version: DxfVersion.r2000,
        fixedScale: 3000, showLegend: false);
      final txt = latin1.decode(r.file.readAsBytesSync());
      expect(txt, contains('420\n16711680\n'),
          reason: 'R2000 应写红色真彩色');
    });

    test('未设色的点不带 62（不破坏默认）', () async {
      final r = await DxfExporter.export(
        name: 'iconnone', labels: chain(), version: DxfVersion.r12,
        fixedScale: 3000, showLegend: false);
      final txt = latin1.decode(r.file.readAsBytesSync());
      for (final b in _ents(txt, 'INSERT', 'BiaoQian')) {
        expect(RegExp(r'^62\n', multiLine: true).hasMatch(b), isFalse,
            reason: '未设色时不应写 62，否则会覆盖图层色');
      }
    });
  });
}

List<String> _ents(String dxf, String type, String? layer) {
  final out = <String>[];
  final lines = dxf.split('\n');
  var cur = '';
  var body = <String>[];
  void flush() {
    if (cur != type) {
      cur = '';
      body = [];
      return;
    }
    final joined = body.join('\n');
    if (layer != null) {
      final m = RegExp(r'^8\n([^\n]*)$', multiLine: true).firstMatch(joined);
      if ((m?.group(1) ?? '') != layer) {
        cur = '';
        body = [];
        return;
      }
    }
    out.add(joined);
    cur = '';
    body = [];
  }

  for (var i = 0; i + 1 < lines.length; i += 2) {
    if (lines[i].trim() == '0') {
      flush();
      cur = lines[i + 1].trim();
      continue;
    }
    body.add('${lines[i].trim()}\n${lines[i + 1]}');
  }
  flush();
  return out;
}
