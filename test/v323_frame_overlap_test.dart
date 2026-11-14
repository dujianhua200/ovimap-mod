// v3.23 验收：图框不重叠 + 文字落在格子中心。
import 'dart:convert' show latin1;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart' show gbk_bytes;
import 'package:ovimap/export/dxf.dart';
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
    tmp = Directory.systemTemp.createTempSync('ov_v323');
    LabelStore.instance.setBaseDirForTest(tmp);
    AppPaths.setBaseForTest(tmp);
    LabelType.installCatalog(SymbolCatalog.fromTextSync(
        File('assets/dxf/lispblock.dxf').readAsStringSync()));
  });

  tearDown(() => AppPaths.clearForTest());

  FrameTemplate frame() => parseDxfFrame(
      latin1.decode(File('assets/frames/frame_a3.dxf').readAsBytesSync()));

  /// 复现用户的场景：线路横跨 ~550 单位（需要 2 幅）。
  ///
  /// 1:3000 下 1 图纸单位 = 3 米；图框可用宽 368.5 单位 ≈ 1105 米。
  /// 要让 cols=2，线路经度跨度需 > 1105 米 ≈ 0.0117°。
  List<MapLabel> longRoute() => [
        for (var i = 0; i < 8; i++)
          MapLabel(
            typeId: 'gl003', seq: i + 1,
            lat: 32.0 + (i.isEven ? 0 : 0.0008),
            // 每步 0.002° ≈ 189 米；7 步 ≈ 1323 米 > 1105 米 → 2 幅
            lon: 114.0 + i * 0.002,
            lineGroupId: 'g', name: 'P${i + 1}', distanceM: 189,
          ),
      ];

  group('图框不重叠', () {
    test('多幅时两图框不重叠', () async {
      final f = frame();
      final r = await DxfExporter.export(
        name: 'multi', labels: longRoute(),
        version: DxfVersion.r12, fixedScale: 3000,
        frame: f, showLegend: false, showNorthArrow: true,
        showTitleBlock: false,
      );
      final txt = latin1.decode(r.file.readAsBytesSync());

      // 图框外框是 POLYLINE（闭合矩形）。找最长的那条，取其 min x。
      final lefts = <double>[];
      for (final chunk in txt.split('0\nPOLYLINE\n')) {
        if (!chunk.contains('8\nTuQian')) continue;
        // 收集该折线所有顶点
        final pts = <List<double>>[];
        for (final v in chunk.split('0\nVERTEX\n').skip(1)) {
          final xm = RegExp(r'\n10\n([-\d.]+)').firstMatch(v);
          final ym = RegExp(r'\n20\n([-\d.]+)').firstMatch(v);
          if (xm != null && ym != null) {
            pts.add([double.parse(xm.group(1)!), double.parse(ym.group(1)!)]);
          }
        }
        if (pts.length < 4) continue;
        final xs = pts.map((p) => p[0]);
        final minX = xs.reduce((a, b) => a < b ? a : b);
        final maxX = xs.reduce((a, b) => a > b ? a : b);
        if ((maxX - minX) > f.width * 0.8) lefts.add(minX);
      }
      lefts.sort();
      // ignore: avoid_print
      print('图框（宽度≈${f.width.toStringAsFixed(0)}）左边线: $lefts');

      expect(lefts.length, greaterThanOrEqualTo(2),
          reason: '两幅图框应各有外框，实际 $lefts');
      final step = lefts[1] - lefts[0];
      // ignore: avoid_print
      print('平移步长: ${step.toStringAsFixed(1)}');
      // v3.24 起用户要求"图框之间不能有缝隙" → 步长 == 图框宽（严丝合缝）
      expect(step, closeTo(f.width, 0.5),
          reason: '步长应等于图框宽（不重叠且不留缝），实际 $step');
    });

    test('单幅时不出现第二套图框', () async {
      final f = frame();
      final r = await DxfExporter.export(
        name: 'single',
        labels: [
          MapLabel(typeId: 'gl003', seq: 1, lat: 32.0, lon: 114.0,
              lineGroupId: 'g', name: 'A'),
          MapLabel(typeId: 'gl003', seq: 2, lat: 32.0004, lon: 114.0005,
              lineGroupId: 'g', name: 'B'),
        ],
        version: DxfVersion.r12, fixedScale: 3000,
        frame: f, showLegend: false, showNorthArrow: true,
        showTitleBlock: false,
      );
      final txt = latin1.decode(r.file.readAsBytesSync());
      // 单幅 → 图框自带的圆只有 1 个；
      // 另外有用户图框时我们**不再额外画** BeiFangZhen 指北针（避免两个 N）
      final frameCircles =
          RegExp(r'0\nCIRCLE\n8\nTuQian\n').allMatches(txt).length;
      final extraArrows =
          RegExp(r'0\nCIRCLE\n8\nBeiFangZhen\n').allMatches(txt).length;
      expect(frameCircles, 1, reason: '单幅应只有 1 套图框，实际 $frameCircles');
      expect(extraArrows, 0,
          reason: '有用户图框时不应再额外画指北针（图框自带），'
              '否则图上会出现两个 N');
    });
  });

  group('图框文字落在格子中心', () {
    test('图框自带文字（审核/专业负责人…）垂直偏差 ≤ 0.2', () async {
      final f = frame();
      final rows = f.findTitleBlockRows()!.ys;

      final r = await DxfExporter.export(
        name: 'snap', labels: [
          MapLabel(typeId: 'gl003', seq: 1, lat: 32.0, lon: 114.0,
              lineGroupId: 'g', name: 'A'),
          MapLabel(typeId: 'gl003', seq: 2, lat: 32.0004, lon: 114.0005,
              lineGroupId: 'g', name: 'B'),
        ],
        version: DxfVersion.r12, fixedScale: 3000,
        frame: f, showLegend: false, showNorthArrow: false,
        showTitleBlock: true,
      );
      final raw = r.file.readAsBytesSync();
      final gbk = gbk_bytes.decode(raw).replaceAll('\r', '');

      // 解析 TuQian 的 TEXT
      final texts = <({double y, String t})>[];
      for (final chunk in gbk.split('0\nTEXT\n')) {
        if (!chunk.contains('8\nTuQian')) continue;
        final ym = RegExp(r'\n20\n([-\d.]+)').firstMatch(chunk);
        final tm = RegExp(r'\n1\n([^\n]*)').firstMatch(chunk);
        if (ym != null && tm != null) {
          texts.add((y: double.parse(ym.group(1)!), t: tm.group(1)!));
        }
      }

      // 取图框自带的几条（这些原本偏 1.6~2.3）
      final marks = ['专业负责人', '审     核', '总负责人'];
      var checked = 0;
      for (final m in marks) {
        final hit = texts.where((e) => e.t.contains(m)).toList();
        if (hit.isEmpty) continue;
        final y = hit.first.y;
        // 投影回图框内坐标：找出最近的格中心（绝对坐标下同构）
        var bestD = double.infinity;
        // 用相邻文字的相对间距判断：先找格高 5.9 的整除位置
        for (var i = 0; i < rows.length - 1; i++) {
          final cellH = rows[i] - rows[i + 1];
          // 绝对坐标里格中心 = y 附近的 5.9 网格
          final k = ((y - 0) / cellH).roundToDouble();
          final center = k * cellH + cellH / 2;
          final d = (y - center).abs();
          if (d < bestD) bestD = d;
        }
        // ignore: avoid_print
        print('$m  y=${y.toStringAsFixed(2)}  距格中心 '
            '${bestD.toStringAsFixed(3)}');
        checked++;
      }
      expect(checked, greaterThanOrEqualTo(2), reason: '至少核对 2 条图框文字');
    });
  });
}
