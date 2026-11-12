/// 生成"真实图例库块"导出的 DXF 样本，交给 `tool/validate_lispblock.py`
/// （ezdxf 严格打开）做**外部真解析**校验。
///
/// 为什么不在测试里直接调 ezdxf：Dart 侧没有可靠的 DXF 引擎，本项目历史上
/// 正是被"字符串断言"坑过（R12 结构贴 AC1015 标签，字符串全过、CAD 打不开）。
/// 所以这条链分成两段：Dart 侧产出文件 → 第三方引擎验收。
///
/// 产物落在仓库根 `out/`，由 validate 脚本消费。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/models/label_type.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/symbols/symbol_catalog.dart';

void main() {
  test('导出供 ezdxf 校验的样本（真实图例库块）', () async {
    final asset = File('assets/dxf/lispblock.dxf');
    expect(asset.existsSync(), isTrue, reason: '图例库资产必须在仓库里');

    LabelType.installCatalog(
        SymbolCatalog.fromTextSync(asset.readAsStringSync()));
    // 三种真实图例块 + 一种预置符号：覆盖"混用"这一最常见现场
    expect(LabelType.fromId('gl001').isBlock, isTrue);
    expect(LabelType.fromId('gx005_x').name, '新建人井');
    expect(LabelType.fromId('lx001').name, '新建拉线');

    final outDir = Directory('out')..createSync(recursive: true);

    final labels = [
      MapLabel(
          typeId: 'gl001',
          seq: 1,
          lat: 32.1264,
          lon: 114.0913,
          lineGroupId: 'g',
          name: 'GK-1'),
      MapLabel(
          typeId: 'gl001',
          seq: 2,
          lat: 32.1266,
          lon: 114.0913,
          lineGroupId: 'g',
          name: 'GK-2'),
      MapLabel(
          typeId: 'gx005_x',
          seq: 3,
          lat: 32.1268,
          lon: 114.0913,
          lineGroupId: 'g',
          name: 'GK-3',
          holes: 4,
          usedHoles: 2),
      MapLabel(
          typeId: 'lx001',
          seq: 4,
          lat: 32.1270,
          lon: 114.0913,
          lineGroupId: 'g'),
      MapLabel(
          typeId: 'crossbox',
          seq: 5,
          lat: 32.1267,
          lon: 114.0916,
          name: '李庄光交',
          splitterRatio: '1:8'),
    ];

    for (final v in [DxfVersion.r12, DxfVersion.r2000]) {
      final r = await DxfExporter.export(
          name: 'lispblock_${v.name}',
          labels: labels,
          version: v,
          showLegend: true,
          showStakes: true);
      final dst = File('${outDir.path}/lispblock_${v.name}.dxf');
      r.file.copySync(dst.path);
      expect(dst.lengthSync(), greaterThan(2000));
    }
  });
}
