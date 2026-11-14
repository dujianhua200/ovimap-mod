// 验证图签格线实测 + 文字精确居中。
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
    tmp = Directory.systemTemp.createTempSync('ov_tb21');
    LabelStore.instance.setBaseDirForTest(tmp);
    AppPaths.setBaseForTest(tmp);
    LabelType.installCatalog(SymbolCatalog.fromTextSync(
        File('assets/dxf/lispblock.dxf').readAsStringSync()));
  });

  tearDown(() => AppPaths.clearForTest());

  test('能从图框里实测出图签格线（5~6 条等距横线）', () {
    final frame = parseDxfFrame(
        latin1.decode(File('assets/frames/frame_a3.dxf').readAsBytesSync()));
    final rows = frame.findTitleBlockRows();
    expect(rows, isNotNull, reason: '应识别出图签格线组');
    // ignore: avoid_print
    print('实测格线 y: ${rows!.ys.map((v) => v.toStringAsFixed(2)).toList()}');
    // ignore: avoid_print
    print('格线 x 范围: ${rows.x0.toStringAsFixed(1)} ~ ${rows.x1.toStringAsFixed(1)}');

    expect(rows.ys.length, greaterThanOrEqualTo(4),
        reason: '至少 4 条线（3 格）');
    // 间距应一致（±15%）
    final gaps = <double>[
      for (var i = 1; i < rows.ys.length; i++) rows.ys[i - 1] - rows.ys[i]
    ];
    final mean = gaps.reduce((a, b) => a + b) / gaps.length;
    for (final g in gaps) {
      expect((g - mean).abs() / mean, lessThan(0.16),
          reason: '格高应一致，实际 $gaps');
    }
  });

  test('图签文字落在各自格子中心（误差 < 0.1）', () async {
    final frame = parseDxfFrame(
        latin1.decode(File('assets/frames/frame_a3.dxf').readAsBytesSync()));
    final rows = frame.findTitleBlockRows()!;

    final r = await DxfExporter.export(
      name: '测试工程',
      labels: [
        MapLabel(typeId: 'gl003', seq: 1, lat: 32.0, lon: 114.0,
            lineGroupId: 'g', name: 'A'),
        MapLabel(typeId: 'gl003', seq: 2, lat: 32.0004, lon: 114.0005,
            lineGroupId: 'g', name: 'B'),
      ],
      version: DxfVersion.r12,
      fixedScale: 3000,
      frame: frame,
      showLegend: false,
      showNorthArrow: false,
      showTitleBlock: true,
    );
    final raw = r.file.readAsBytesSync();
    final txt = latin1.decode(raw);
    // DXF 用 CRLF：先统一成 LF，否则组码值尾部带 \r，正则匹配不到
    final gbk = gbk_bytes.decode(raw).replaceAll('\r', '');
    // ignore: avoid_print
    print('文件里能否找到"滑洲云图": ${gbk.contains('滑洲云图')}');

    // 收集 TuQian 里的 TEXT 的 (y, text)
    // 直接按 "0\nTEXT\n" 切块——比逐行配对稳妥（DXF 有 100/AcDbText 等隔断）
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
    print('TuQian TEXT 解析到 ${texts.length} 个');
    // ignore: avoid_print
    print('内容: ${texts.map((e) => '${e.y.toStringAsFixed(1)}:${e.t}').toList()}');

    // 图框的格线在**图框内坐标**（0~29.48）；文件里是绝对坐标，
    // 所以要用"文字 y 的相对间距"验证：相邻行间隔应等于格高。
    final marks = ['滑洲云图', '点数', '长度', '1:3000'];
    final ys = <double>[];
    for (final m in marks) {
      final hit = texts.where((e) => e.t.contains(m)).toList();
      expect(hit, isNotEmpty, reason: '应写出「$m」这一行');
      ys.add(hit.first.y);
    }
    ys.sort((a, b) => b.compareTo(a));
    // ignore: avoid_print
    print('图签各行 y: ${ys.map((v) => v.toStringAsFixed(2)).toList()}');

    // 相邻间距应等于格高（实测约 5.89~5.90）
    final gaps = <double>[
      for (var i = 1; i < ys.length; i++) ys[i - 1] - ys[i]
    ];
    final mean = gaps.reduce((a, b) => a + b) / gaps.length;
    // ignore: avoid_print
    print('行距: ${gaps.map((v) => v.toStringAsFixed(2)).toList()}  均值 '
        '${mean.toStringAsFixed(2)}');
    for (final g in gaps) {
      expect((g - mean).abs(), lessThan(0.15),
          reason: '行距应均匀（等于格高），实际 ${gaps}');
    }
    expect(mean, closeTo(5.9, 0.3),
        reason: '行距应等于图框格高 ≈5.9，实际 $mean');
  });
}
