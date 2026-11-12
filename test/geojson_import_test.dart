// 本地开源矢量底图（GeoJSON）导入：解析映射 + 离线出图 + 项目级存储往返。
// 关键：GeoJSON 坐标顺序为 [lon, lat]，本仓库内部为 [lat, lon]，必须正确换序。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/export/local_basemap.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '_dxf_fixture.dart';

/// 合成 GeoJSON FeatureCollection（覆盖 Polygon/MultiPolygon/LineString/
/// MultiLineString/Point/MultiPoint）。坐标写作 [lon, lat]（GeoJSON 规范）。
String _features() => jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': {'name': '李庄1号楼'},
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              // 外环
              [
                [114.0918, 32.1268],
                [114.0924, 32.1268],
                [114.0924, 32.1273],
                [114.0918, 32.1273],
                [114.0918, 32.1268],
              ],
              // 孔
              [
                [114.0919, 32.1269],
                [114.0923, 32.1269],
                [114.0923, 32.1272],
                [114.0919, 32.1272],
                [114.0919, 32.1269],
              ],
            ]
          }
        },
        {
          'type': 'Feature',
          'properties': {'name': ''},
          'geometry': {
            'type': 'MultiPolygon',
            'coordinates': [
              [
                [
                  [114.0930, 32.1252],
                  [114.0935, 32.1252],
                  [114.0935, 32.1257],
                  [114.0930, 32.1257],
                  [114.0930, 32.1252],
                ]
              ],
              [
                [
                  [114.0940, 32.1252],
                  [114.0944, 32.1252],
                  [114.0944, 32.1256],
                  [114.0940, 32.1256],
                  [114.0940, 32.1252],
                ]
              ],
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
              [114.0935, 32.1264],
            ]
          }
        },
        {
          'type': 'Feature',
          'properties': {'name': '', 'highway': 'residential'},
          'geometry': {
            'type': 'MultiLineString',
            'coordinates': [
              [
                [114.0913, 32.1258],
                [114.0913, 32.1282],
              ],
              [
                [114.0920, 32.1260],
                [114.0928, 32.1272],
              ],
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
        {
          'type': 'Feature',
          'properties': {'name': '和谐花园', 'landuse': 'residential'},
          'geometry': {
            'type': 'MultiPoint',
            'coordinates': [
              [114.0926, 32.1270],
              [114.0927, 32.1271],
            ]
          }
        },
      ]
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('解析映射：Polygon=建筑(含孔)、LineString=道路(分级)、Point=地名；坐标换序', () {
    final bm = GeoJsonImporter.parse(_features());

    // 建筑：1(Polygon) + 2(MultiPolygon) = 3
    expect(bm.buildings.length, 3);
    final holed = bm.buildings.firstWhere((b) => b.rings.length > 1);
    expect(holed.name, '李庄1号楼');
    expect(holed.outer.length, greaterThanOrEqualTo(4));
    expect(holed.holes.length, 1);

    // 道路：1(LineString) + 2(MultiLineString) = 3
    expect(bm.roads.length, 3);
    final primary = bm.roads.firstWhere((r) => r.grade == RoadGrade.primary);
    expect(primary.name, '人民路');
    // 坐标换序：GeoJSON [lon,lat]=[114.09,32.1264] → 内部 [lat,lon]=[32.1264,114.09]
    expect(primary.pts.first[0], closeTo(32.1264, 1e-9));
    expect(primary.pts.first[1], closeTo(114.0900, 1e-9));

    // 地名：1(Point) + 2(MultiPoint) = 3
    expect(bm.places.length, 3);
    final village = bm.places.firstWhere((p) => p.name == '李庄村');
    expect(village.level, PlaceLevel.village);
    expect(village.lat, closeTo(32.1280, 1e-9));
    expect(village.lon, closeTo(114.0920, 1e-9));

    // 报告：source=local，全 ok
    expect(bm.report.anyFailed, isFalse);
    expect(bm.report.roads.source, 'local');
  });

  test('非法输入 → FormatException', () {
    expect(() => GeoJsonImporter.parse('不是 JSON'), throwsFormatException);
    expect(() => GeoJsonImporter.parse('{"type":"FeatureCollection","features":[]}'),
        throwsFormatException);
    expect(() => GeoJsonImporter.parse('{"foo":1}'), throwsFormatException);
  });

  test('cropTo 按 bbox 过滤：范围外要素被去除', () {
    final bm = GeoJsonImporter.parse(_features());
    // 只留 114.089~114.0935 / 32.1255~32.1285 附近（覆盖全部要素）
    final all = GeoJsonImporter.cropTo(bm, [32.12, 114.08, 32.14, 114.10]);
    expect(all.buildings.length, 3);
    // 缩到只包含一栋楼的极小范围
    final one = GeoJsonImporter.cropTo(bm, [32.1251, 114.0929, 32.1258, 114.0936]);
    expect(one.buildings.length, lessThan(3));
    expect(one.places, isEmpty);
  });

  test('离线出图：导入的本地底图直接进入 DXF（无需联网）', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_geo_export');
    PathProviderPlatform.instance = FakePathProvider(dir.path);

    final bm = GeoJsonImporter.parse(_features());
    final labels = <MapLabel>[
      MapLabel(typeId: 'pipe', seq: 1, lat: 32.1264, lon: 114.0913, lineGroupId: 'g'),
      MapLabel(typeId: 'pipe', seq: 2, lat: 32.1264, lon: 114.0920, lineGroupId: 'g'),
    ];

    for (final v in DxfVersion.values) {
      final r = await DxfExporter.export(
        name: 'geo_${v.name}',
        labels: labels,
        includeSurroundings: true,
        localBasemap: bm, // 直接注入本地底图，不触网
        // 显式给足范围：本用例验「注入的底图能进 DXF」，与 UI 默认范围无关
        // （v3.7.2 起 UI 默认 100m，样本地名在 880m 外）。
        rangeM: 880,
        version: v,
        buildingFill: true, // 显式开启：本用例继续断言 HATCH/SOLID 填充路径
      );
      final text = gbk_bytes.decode(r.file.readAsBytesSync());
      expect(text, contains('JianZhu'), reason: '${v.name}: 建筑轮廓层缺失');
      expect(text, contains('DaoLuBian'), reason: '${v.name}: 道路双线层缺失');
      expect(text, contains('DiMing'), reason: '${v.name}: 地名层缺失');
      expect(text, contains('李庄村'), reason: '${v.name}: 地名未写出');
      expect(text, contains('人民路'), reason: '${v.name}: 路名未写出');
      if (v == DxfVersion.r2000) {
        expect(text, contains('HATCH'), reason: 'R2000 建筑填充应为 HATCH');
      } else {
        expect(text, contains('0\nSOLID'), reason: 'R12 建筑填充应为 SOLID');
      }
    }
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('项目级存储：save/exists/load/clear 往返 + 元信息', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_geo_store');
    PathProviderPlatform.instance = FakePathProvider(dir.path);

    final store = await LocalBasemapStore.open();
    await store.clear();
    expect(store.exists(), isFalse);
    expect(await store.load(), isNull);

    final raw = _features();
    await store.save(raw, sourceName: 'target.geojson', roads: 3, buildings: 3, places: 3);
    expect(store.exists(), isTrue);
    expect(store.meta()['sourceName'], 'target.geojson');

    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.buildings.length, 3);
    expect(loaded.roads.length, 3);
    expect(loaded.places.length, 3);

    await store.clear();
    expect(store.exists(), isFalse);
    dir.deleteSync(recursive: true);
  });
}
