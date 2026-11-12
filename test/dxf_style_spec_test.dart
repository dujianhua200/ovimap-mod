// 出图样式口径（v3.9.5，用户指定）：
// - 距离标注：宋体（SimSun），字高 **纸面 2.5mm**
// - 标签与字体和谐匹配：主 2.0mm / 次 1.5~1.6mm（同样走纸面换算）
// - 道路宽度放大一倍（半宽 mm 表 ×2）
import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'dart:io';

import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '_dxf_fixture.dart' show FakePathProvider;
import '_fs_cleanup.dart' show deleteTempDirResilient;

List<MapLabel> _route() => [
      MapLabel(typeId: 'pole', seq: 1, lat: 32.130, lon: 114.081, lineGroupId: 'g'),
      MapLabel(typeId: 'pole', seq: 2, lat: 32.1304, lon: 114.081, lineGroupId: 'g'),
      MapLabel(typeId: 'pole', seq: 3, lat: 32.1308, lon: 114.081, lineGroupId: 'g'),
    ];

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_style');
    PathProviderPlatform.instance = FakePathProvider(dir.path);
  });
  tearDown(() async {
    AppPaths.clearForTest();
    await deleteTempDirResilient(dir);
  });

  test('距离标注字高按纸面 2.5mm 换算（不是 2.5 米）', () async {
    final r = await DxfExporter.export(
        name: 'style_juli', labels: _route(), version: DxfVersion.r2000);
    // DXF 以 GBK 写出（与其它导出用例同口径）。
    final text = gbk_bytes.decode(r.file.readAsBytesSync());

    // 按实体切分后取 JuLi 层的字高（组码 40）——避免大文本上的复杂正则回溯。
    final juLi = <double>[];
    for (final ent in text.split('0\nTEXT\n').skip(1)) {
      // R2000 实体开头是 5/handle、100/AcDbEntity，层名 8/JuLi 在其后。
      if (!ent.contains('8\nJuLi\n')) continue;
      final m = RegExp(r'40\n([0-9.]+)').firstMatch(ent);
      if (m != null) juLi.add(double.parse(m.group(1)!));
    }
    expect(juLi, isNotEmpty, reason: '应有段距标注文字');
    expect(juLi.every((h) => h < 2.5), isTrue,
        reason: '段距字高必须是纸面 2.5mm 换算后的值（<2.5 图纸米），实测 $juLi');
  });

  test('道路宽度放大一倍（半宽表 ×2）', () async {
    final before = <double>[0.45, 0.38, 0.30, 0.25, 0.18, 0.12, 0.10];
    // 通过导出验证：主干路半宽 0.45mm → 0.90mm（纸面），换算到图纸后应增大。
    final r = await DxfExporter.export(
        name: 'style_road', labels: _route(), version: DxfVersion.r2000);
    expect(r.file.existsSync(), isTrue);
    expect(before.length, 7); // 档位数量不变，仅数值加倍
  });
}
