// v3.26 验收：A3 / A4 / 新块 三套图框可切换。
import 'dart:convert' show latin1;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
    tmp = Directory.systemTemp.createTempSync('ov_v326');
    LabelStore.instance.setBaseDirForTest(tmp);
    AppPaths.setBaseForTest(tmp);
    LabelType.installCatalog(SymbolCatalog.fromTextSync(
        File('assets/dxf/lispblock.dxf').readAsStringSync()));
  });

  tearDown(() => AppPaths.clearForTest());

  group('三套图框都能解析', () {
    test('A3 标准图框 420×297', () {
      final f = parseDxfFrame(
          latin1.decode(File('assets/frames/frame_tk_a3.dxf').readAsBytesSync()));
      // ignore: avoid_print
      print('A3: ${f.width.toStringAsFixed(1)} × ${f.height.toStringAsFixed(1)}'
          '  shapes=${f.shapes.length}');
      expect(f.width, closeTo(420, 1));
      expect(f.height, closeTo(297, 1));
      expect(f.shapes, isNotEmpty);
    });

    test('A4 标准图框 297×210', () {
      final f = parseDxfFrame(
          latin1.decode(File('assets/frames/frame_tk_a4.dxf').readAsBytesSync()));
      // ignore: avoid_print
      print('A4: ${f.width.toStringAsFixed(1)} × ${f.height.toStringAsFixed(1)}'
          '  shapes=${f.shapes.length}');
      expect(f.width, closeTo(297, 1));
      expect(f.height, closeTo(210, 1));
      expect(f.shapes, isNotEmpty);
    });

    test('新块（用户 A3 内框）392×281', () {
      final f = parseDxfFrame(
          latin1.decode(File('assets/frames/frame_a3.dxf').readAsBytesSync()));
      // ignore: avoid_print
      print('legacy: ${f.width.toStringAsFixed(1)} × '
          '${f.height.toStringAsFixed(1)}  shapes=${f.shapes.length}');
      expect(f.width, closeTo(392, 2));
      expect(f.height, closeTo(281, 2));
    });
  });

  group('用不同图框导出都合法', () {
    for (final asset in const [
      'frame_a3.dxf',
      'frame_tk_a3.dxf',
      'frame_tk_a4.dxf',
    ]) {
      test('$asset 导出结构校验通过', () async {
        final f = parseDxfFrame(
            latin1.decode(File('assets/frames/$asset').readAsBytesSync()));

        final r = await DxfExporter.export(
          name: 'case_$asset',
          labels: [
            MapLabel(typeId: 'gl003', seq: 1, lat: 32.0, lon: 114.0,
                lineGroupId: 'g', name: 'A'),
            MapLabel(typeId: 'gl003', seq: 2, lat: 32.0004, lon: 114.0005,
                lineGroupId: 'g', name: 'B'),
          ],
          version: DxfVersion.r12,
          fixedScale: 3000,
          frame: f,
          showLegend: false,
          showTitleBlock: true,
        );
        final txt = latin1.decode(r.file.readAsBytesSync());
        expect(DxfStructureValidator.validate(txt, version: DxfVersion.r12),
            isEmpty, reason: '$asset 导出应结构合法');
        // 图框内容应真的写进去了
        final tu = RegExp(r'0\n(LINE|POLYLINE|CIRCLE|TEXT)\n[\s\S]{0,60}?8\nTuQian\n')
            .allMatches(txt)
            .length;
        // ignore: avoid_print
        print('$asset → TuQian 实体 $tu 个');
        expect(tu, greaterThan(10), reason: '$asset 图框应有内容');
      });
    }
  });

  group('FrameSize 枚举', () {
    test('三种规格齐全，尺寸与资源对应', () {
      expect(FrameSize.values.length, 3);
      for (final s in FrameSize.values) {
        expect(File(s.asset).existsSync(), isTrue,
            reason: '${s.label} 的资源 ${s.asset} 应存在');
        expect(s.widthMm, greaterThan(0));
        expect(s.heightMm, greaterThan(0));
        // ignore: avoid_print
        print('${s.name}: ${s.label} ${s.widthMm}×${s.heightMm} → ${s.asset}');
      }
      // A4 比 A3 小
      expect(FrameSize.a4.widthMm, lessThan(FrameSize.a3.widthMm));
      expect(FrameSize.a4.heightMm, lessThan(FrameSize.a3.heightMm));
    });
  });
}
