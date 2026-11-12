import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String root;
  _FakePathProvider(this.root);
  @override
  Future<String?> getExternalStoragePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('端到端：含拓扑的工程导出 DXF（配线图沿杆路走向 + GBK）', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final gid = 'g1';
    final labels = <MapLabel>[];
    final offsets = [
      (0.0, 0.0), (0.0004, 0.0002), (0.0009, 0.0005), (0.0013, 0.0011),
      (0.0015, 0.0018), (0.0013, 0.0024), (0.0008, 0.0028), (0.0002, 0.0030),
    ];
    for (var i = 0; i < offsets.length; i++) {
      labels.add(MapLabel(
          typeId: 'pipe',
          seq: i + 1,
          lat: 32.1264 + offsets[i].$1,
          lon: 114.0913 + offsets[i].$2,
          lineGroupId: gid,
          distLabel: i == 2 ? '埋42.5' : ''));
    }
    final cross = MapLabel(
        typeId: 'crossbox', seq: 9, lat: 32.1264, lon: 114.0913, name: '李庄光交');
    final split = MapLabel(
        typeId: 'splitterbox',
        seq: 10,
        lat: 32.1279,
        lon: 114.0931,
        name: '李庄分光箱',
        splitterRatio: '1:8');
    final fiber = MapLabel(
        typeId: 'fiberbox', seq: 11, lat: 32.1266, lon: 114.0943, name: '李庄分纤盒');
    split.topoParentId = cross.id;
    fiber.topoParentId = split.id;
    split.cableSpec = '架24芯GYTS-01';
    fiber.cableSpec = '架12芯GYTS-02';
    labels.addAll([cross, split, fiber]);

    final r = await DxfExporter.export(
        name: '拓扑测试',
        labels: labels,
        includeSurroundings: false,
        version: DxfVersion.r12);
    final f = r.file;
    final bytes = f.readAsBytesSync();
    final text = gbk_bytes.decode(bytes);

    expect(r.warnings, isEmpty);
    expect(text, contains(r'$DWGCODEPAGE'));
    expect(text, contains('ANSI_936'));
    expect(text, contains('PeiXianTu'));
    // 配线图：箱体落位 + 名称 + 光缆型号 + 箱体间距离
    expect(text, contains('李庄光交'));
    expect(text, contains('李庄分光箱'));
    expect(text, contains('李庄分纤盒'));
    expect(text, contains('架24芯GYTS-01'));
    expect(text, contains('架12芯GYTS-02'));
    expect(text, contains('237.8')); // 光交→分光箱 箱体间距离
    expect(text, contains('183.5')); // 分光箱→分纤盒 箱体间距离
    // R12 兼容：多段线用经典 POLYLINE（不再用 LWPOLYLINE），主干宽 0.6
    expect(text, contains('0\nPOLYLINE'));
    expect(text, isNot(contains('LWPOLYLINE')));
    expect(text, contains('40\n0.600'));
    // 图签 + 指北针图层
    expect(text, contains('TuQian'));
    expect(text, contains('BeiFangZhen'));
    expect(text, contains('滑洲云图导出'));
    // 杆路段标注前缀文字
    expect(text, contains('埋42.5'));
    // GBK 字节验证：'李' = 0xC0 0xEE
    expect(bytes, containsAllInOrder([0xC0, 0xEE]));
    print('DXF 端到端生成成功: ${f.path} ${bytes.length} 字节');
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
