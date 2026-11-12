// 「从文件选择」导入 GeoJSON 底图：文件 → 文本 → 解析 → 落盘 全链路单测。
//
// 零网络、不依赖真实文件选择器：用临时文件模拟用户选中的 .geojson，
// 验证解析与存储语义**复用**既有 GeoJsonImporter / LocalBasemapStore，
// 并覆盖非 GeoJSON / 文件过大 / 文件不存在 等错误分支。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/basemap_file_import.dart';
import 'package:ovimap/export/local_basemap.dart';
import 'package:ovimap/services/store.dart';

/// 合成一份最小 GeoJSON（建筑 1 / 道路 1 / 地名 1），坐标写作 [lon, lat]。
String _sampleGeoJson() => jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': {'name': '李庄1号楼'},
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              [
                [114.0918, 32.1268],
                [114.0924, 32.1268],
                [114.0924, 32.1273],
                [114.0918, 32.1273],
                [114.0918, 32.1268],
              ]
            ]
          }
        },
        {
          'type': 'Feature',
          'properties': {'name': '人民路', 'highway': 'primary'},
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [114.0900, 32.1264],
              [114.0935, 32.1264]
            ]
          }
        },
        {
          'type': 'Feature',
          'properties': {'name': '李庄村', 'place': 'village'},
          'geometry': {
            'type': 'Point',
            'coordinates': [114.0920, 32.1280]
          }
        },
      ]
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_geo_file');
    // 注入基础目录，绕开 path_provider 插件（逐测隔离，避免落盘串扰）。
    LabelStore.instance.setBaseDirForTest(dir);
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('全链路：文件 → 文本 → parse → save，要素数正确且已落盘', () async {
    final src = File('${dir.path}/信阳矢量底图_整市.geojson');
    src.writeAsStringSync(_sampleGeoJson());

    final bm = await BasemapFileImporter.importFromPath(src.path);

    // 解析映射（复用既有 GeoJsonImporter 口径）
    expect(bm.buildings.length, 1);
    expect(bm.roads.length, 1);
    expect(bm.places.length, 1);

    // 已落盘：与「粘贴/剪贴板」导入同一条路径（LocalBasemapStore）
    final store = await LocalBasemapStore.open();
    expect(store.exists(), isTrue);
    final meta = store.meta();
    expect(meta['sourceName'], '信阳矢量底图_整市.geojson'); // 缺省取文件名
    expect(meta['roads'], 1);
    expect(meta['buildings'], 1);
    expect(meta['places'], 1);
    expect((meta['savedAt'] as int), greaterThan(0));

    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.buildings.length, 1);
    expect(loaded.roads.length, 1);
    expect(loaded.places.length, 1);
  });

  test('UTF-8 BOM 容错：带 BOM 的文本仍能解析', () async {
    final src = File('${dir.path}/bom.geojson');
    src.writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode(_sampleGeoJson())]);

    final bm = await BasemapFileImporter.importFromPath(src.path);
    expect(bm.roads.length, 1);
    expect(bm.buildings.length, 1);
  });

  test('错误①：非 JSON 文本 → FormatException，且不落盘', () async {
    final src = File('${dir.path}/notjson.geojson');
    src.writeAsStringSync('这不是 JSON，只是一段普通文本');

    await expectLater(
      BasemapFileImporter.importFromPath(src.path),
      throwsA(isA<FormatException>()),
    );
    final store = await LocalBasemapStore.open();
    expect(store.exists(), isFalse, reason: '解析失败不应写入项目存储');
  });

  test('错误②：合法 JSON 但无可映射要素 → FormatException', () async {
    final src = File('${dir.path}/empty.geojson');
    src.writeAsStringSync('{"type":"FeatureCollection","features":[]}');
    await expectLater(
      BasemapFileImporter.importFromPath(src.path),
      throwsFormatException,
    );
  });

  test('错误③：文件过大 → BasemapImportException，提示含「文件过大」', () async {
    final src = File('${dir.path}/big.geojson');
    src.writeAsStringSync(_sampleGeoJson());

    await expectLater(
      BasemapFileImporter.importFromPath(src.path, limit: 4), // 4 字节上限
      throwsA(isA<BasemapImportException>()),
    );
    try {
      await BasemapFileImporter.importFromPath(src.path, limit: 4);
      fail('应抛 BasemapImportException');
    } on BasemapImportException catch (e) {
      expect(e.message, contains('文件过大'));
      expect(e.toString(), contains('文件过大'));
    }
  });

  test('错误④：文件不存在 → FileSystemException（UI 落到「导入失败」分支）', () async {
    await expectLater(
      BasemapFileImporter.importFromPath('${dir.path}/不存在.geojson'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('字节回退：content:// 无 path 时按字节解码同样可导入', () async {
    final bytes = utf8.encode(_sampleGeoJson());
    final bm = await BasemapFileImporter.importFromBytes(bytes,
        sourceName: 'from_bytes.geojson');

    expect(bm.buildings.length, 1);
    expect(bm.roads.length, 1);
    expect(bm.places.length, 1);
    final store = await LocalBasemapStore.open();
    expect(store.meta()['sourceName'], 'from_bytes.geojson');
  });

  test('decodeBytes：空/BOM/非法字节均不抛（非 UTF-8 交给 parse 报错）', () {
    expect(BasemapFileImporter.decodeBytes(const []), '');
    expect(BasemapFileImporter.decodeBytes(const [0xEF, 0xBB, 0xBF]), '');
    expect(BasemapFileImporter.decodeBytes(utf8.encode('abc')), 'abc');
    expect(() => BasemapFileImporter.decodeBytes(const [0xFF, 0xFE, 0x00]),
        returnsNormally);
  });

  test('basename：跨平台路径取末段', () {
    expect(BasemapFileImporter.basename('/a/b/信阳.geojson'), '信阳.geojson');
    expect(BasemapFileImporter.basename(r'C:\dir\file.json'), 'file.json');
    expect(BasemapFileImporter.basename('only.geojson'), 'only.geojson');
  });
}
