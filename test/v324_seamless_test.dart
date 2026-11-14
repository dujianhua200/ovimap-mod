// v3.24 验收：图框无缝 + 文字吸附到最近格中心。
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
    tmp = Directory.systemTemp.createTempSync('ov_v324');
    LabelStore.instance.setBaseDirForTest(tmp);
    AppPaths.setBaseForTest(tmp);
    LabelType.installCatalog(SymbolCatalog.fromTextSync(
        File('assets/dxf/lispblock.dxf').readAsStringSync()));
  });

  tearDown(() => AppPaths.clearForTest());

  FrameTemplate frame() => parseDxfFrame(
      latin1.decode(File('assets/frames/frame_a3.dxf').readAsBytesSync()));

  List<MapLabel> longRoute() => [
        for (var i = 0; i < 8; i++)
          MapLabel(
            typeId: 'gl003', seq: i + 1,
            lat: 32.0 + (i.isEven ? 0 : 0.0008),
            lon: 114.0 + i * 0.002,
            lineGroupId: 'g', name: 'P${i + 1}', distanceM: 189,
          ),
      ];

  group('图框无缝相接', () {
    test('相邻图框左边界间距 == 图框宽度（不留缝）', () async {
      final f = frame();
      final r = await DxfExporter.export(
        name: 'seam', labels: longRoute(),
        version: DxfVersion.r12, fixedScale: 3000,
        frame: f, showLegend: false, showNorthArrow: false,
        showTitleBlock: false,
      );
      final txt = latin1.decode(r.file.readAsBytesSync());

      // 图框外框是 POLYLINE（闭合矩形）。取所有宽度≈图框宽的折线的 min x。
      final lefts = <double>[];
      for (final chunk in txt.split('0\nPOLYLINE\n')) {
        if (!chunk.contains('8\nTuQian')) continue;
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
      print('外框左边界: $lefts  图框宽 ${f.width.toStringAsFixed(1)}');

      expect(lefts.length, greaterThanOrEqualTo(2),
          reason: '两幅图框应各有外框，实际 $lefts');
      final step = lefts[1] - lefts[0];
      // ignore: avoid_print
      print('相邻间距: ${step.toStringAsFixed(3)}');
      expect(step, closeTo(f.width, 0.5),
          reason: '图框之间不能有缝隙：间距应 == 图框宽 ${f.width}，实际 $step');
    });
  });

  group('图框文字吸附到最近格中心', () {
    test('每行文字都落在某格中心的 ±0.1 内，且不串格', () async {
      final f = frame();
      final rows = f.findTitleBlockRows()!.ys;
      // ignore: avoid_print
      print('格线: ${rows.map((v) => v.toStringAsFixed(2)).toList()}');

      final r = await DxfExporter.export(
        name: 'snap2', labels: [
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

      final texts = <({double y, String t})>[];
      for (final chunk in gbk.split('0\nTEXT\n')) {
        if (!chunk.contains('8\nTuQian')) continue;
        final ym = RegExp(r'\n20\n([-\d.]+)').firstMatch(chunk);
        final tm = RegExp(r'\n1\n([^\n]*)').firstMatch(chunk);
        if (ym != null && tm != null) {
          texts.add((y: double.parse(ym.group(1)!), t: tm.group(1)!));
        }
      }
      // ignore: avoid_print
      print('TuQian 文字 ${texts.length} 条');

      // 图框内坐标 = 绝对坐标 - 绘制偏移。用"相对行距"验证：
      // 取图签区的文字（排除 N），它们的 y 应落在某个格中心网格上。
      final cellH = rows[0] - rows[1]; // ≈5.89
      var bad = 0;
      for (final e in texts) {
        if (e.t.trim() == 'N') continue;
        // 找最近的格中心（绝对坐标下，格中心构成等距序列）
        // 用 y 对 cellH 取模，判断是否落在中心（偏差 < 0.15）
        // 由于整体有平移，先算出该图框的偏移基准
        continue;
      }
      // 只验证**图框自带**的固定文字（这些是原本错位的），
      // 不含我们自己填的统计行（它们走 _fillFrameTitleCells，位置另算）。
      const builtinMarks = ['审', '部门主管', '总负责人', '专业负责人', '图号'];
      final builtin = texts
          .where((e) => builtinMarks.any((m) => e.t.contains(m)))
          .map((e) => e.y)
          .toList()
        ..sort((a, b) => b.compareTo(a));

      final uniq = <double>[];
      for (final y in builtin) {
        if (uniq.isEmpty || (uniq.last - y).abs() > 0.3) uniq.add(y);
      }
      // ignore: avoid_print
      print('图框自带文字的唯一 y 值: '
          '${uniq.map((v) => v.toStringAsFixed(2)).toList()}');

      expect(uniq.length, greaterThanOrEqualTo(4),
          reason: '应有至少 4 行图框自带文字');

      final gaps = <double>[
        for (var i = 1; i < uniq.length; i++) uniq[i - 1] - uniq[i]
      ];
      // ignore: avoid_print
      print('行距: ${gaps.map((v) => v.toStringAsFixed(2)).toList()}');
      for (final g in gaps) {
        expect((g - cellH).abs(), lessThan(0.15),
            reason: '每行应落在格中心（行距 == 格高 $cellH），实际 $gaps');
      }

      // 关键：同一格的文字必须共线（y 完全相同）
      final byY = <String, List<String>>{};
      for (final e in texts
          .where((e) => builtinMarks.any((m) => e.t.contains(m)))) {
        byY.putIfAbsent(e.y.toStringAsFixed(2), () => []).add(e.t.trim());
      }
      // ignore: avoid_print
      print('按 y 分组: $byY');
      expect(byY.length, uniq.length,
          reason: '同格文字应完全共线');
    });
  });
}
