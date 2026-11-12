// 导出代表性 DXF 样本到 build/dxf_samples/，供 **真实解析器闸门** `tool/validate_dxf.py`
// （ezdxf 严格 readfile）做端到端校验。
//
// 为什么单独保留这个「样本生成」用例：Dart 测试内无法直接调 Python/ezdxf，
// 于是「结构自洽」在 Dart 侧回归（test/dxf_validate_test.dart），
// 「真实解析器严格打开」交给本用例产出的样本 + tool/validate_dxf.py。
// 二者共同构成 P0-2 防复发闸门（上批正是被字符串断言骗过去）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '_dxf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('生成 DXF 样本（R12/R2000 × 有/无底图）到 build/dxf_samples', () async {
    final root = Directory('${Directory.current.path}/build/dxf_samples');
    if (root.existsSync()) root.deleteSync(recursive: true);
    root.createSync(recursive: true);
    PathProviderPlatform.instance = FakePathProvider(root.path);

    final labels = buildFixtureLabels();
    final bm = buildSyntheticBasemap();
    final cases = <String, ({DxfVersion v, bool withBm, bool fill})>{
      'sample_r12_nobasemap': (v: DxfVersion.r12, withBm: false, fill: false),
      'sample_r12_basemap': (v: DxfVersion.r12, withBm: true, fill: true),
      'sample_r2000_nobasemap': (v: DxfVersion.r2000, withBm: false, fill: false),
      'sample_r2000_basemap': (v: DxfVersion.r2000, withBm: true, fill: true),
    };

    final produced = <File>[];
    for (final e in cases.entries) {
      final r = await DxfExporter.export(
        name: e.key,
        labels: labels,
        includeSurroundings: e.value.withBm,
        basemap: e.value.withBm ? bm : null,
        version: e.value.v,
        straightenedWiring: true,
        corridorWidth: 2, // 管廊双线
        buildingFill: e.value.fill, // 底图样本显式开填充：ezdxf 顺带严校 HATCH/SOLID 路径
      );
      expect(r.file.existsSync(), isTrue);
      expect(r.file.lengthSync(), greaterThan(0));
      produced.add(r.file);
    }
    expect(produced.length, cases.length);
    // 仅确认文件非空且体量合理；**结构自洽**由 test/dxf_validate_test.dart 回归，
    // **真实解析器严格打开**由 tool/validate_dxf.py（ezdxf）对本目录样本执行。
    for (final f in produced) {
      expect(f.lengthSync(), greaterThan(1000), reason: '${f.path} 过小');
    }
    // ignore: avoid_print
    print('DXF 样本已生成于 ${root.path}（${produced.length} 个）');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
