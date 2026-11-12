// QA 独立验证（Edward）：「GeoJSON 底图从文件选择导入」
//
// 与工程师的 test/geojson_file_import_test.dart 相互独立：本文件
// ① 用**真实 18MB 整市文件**跑全链路（文件→文本→parse→save→load 回读）；
// ② 独立统计原始 GeoJSON 的几何类型数，与解析结果交叉核对；
// ③ 重点证明「失败不破坏旧数据」（非 JSON / 过大 / 空集合 均不得覆盖已导入数据）；
// ④ 测量解析耗时 / 落盘大小 / 进程 RSS 增量。
//
// 真实文件：~/Desktop/信阳矢量底图_整市.geojson（约 18MB）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/basemap_file_import.dart';
import 'package:ovimap/export/local_basemap.dart';
import 'package:ovimap/services/store.dart';

final String kRealFile =
    '${Platform.environment['HOME']}/Desktop/信阳矢量底图_整市.geojson';

/// 独立统计原始 GeoJSON：按几何类型计数（Multi* 展开为其子几何个数）。
/// 与 [GeoJsonImporter] 无共享代码，用于交叉核对解析结果。
Map<String, int> countRawTypes(String text) {
  final root = jsonDecode(text) as Map<String, dynamic>;
  final feats = (root['features'] as List).cast<Map<String, dynamic>>();
  var poly = 0, road = 0, place = 0;
  for (final f in feats) {
    final g = f['geometry'];
    if (g is! Map) continue;
    final t = g['type'];
    final c = g['coordinates'];
    switch (t) {
      case 'Polygon':
        poly += 1;
        break;
      case 'MultiPolygon':
        if (c is List) poly += c.length;
        break;
      case 'LineString':
        road += 1;
        break;
      case 'MultiLineString':
        if (c is List) road += c.length;
        break;
      case 'Point':
        place += 1;
        break;
      case 'MultiPoint':
        if (c is List) place += c.length;
        break;
    }
  }
  return {'poly': poly, 'road': road, 'place': place};
}

String sampleGeoJson() => jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': {'name': '楼A'},
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              [
                [114.09, 32.12],
                [114.10, 32.12],
                [114.10, 32.13],
                [114.09, 32.12],
              ]
            ]
          }
        },
        {
          'type': 'Feature',
          'properties': {'name': '路A', 'highway': 'primary'},
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [114.08, 32.11],
              [114.12, 32.11]
            ]
          }
        },
        {
          'type': 'Feature',
          'properties': {'name': '村A', 'place': 'village'},
          'geometry': {
            'type': 'Point',
            'coordinates': [114.095, 32.125]
          }
        },
      ]
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('qa_geo_file');
    LabelStore.instance.setBaseDirForTest(dir);
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('B. 真实 18MB 整市文件端到端（与 UI 相同链路）', () {
    test('importFromPath → 解析计数与独立统计一致 → 落盘 → load 回读一致',
        () async {
      final real = File(kRealFile);
      expect(real.existsSync(), isTrue, reason: '真实文件需存在：$kRealFile');
      final sizeBytes = real.lengthSync();
      // ignore: avoid_print
      print('REAL_FILE size=${(sizeBytes / 1024 / 1024).toStringAsFixed(2)}MB');

      // 独立统计（只读文本，不走被验代码）
      final rawText = real.readAsStringSync();
      final rawCount = countRawTypes(rawText);
      // ignore: avoid_print
      print('RAW_COUNTS $rawCount');

      // 走 UI 相同链路
      final rss0 = ProcessInfo.currentRss;
      final t0 = DateTime.now();
      final bm = await BasemapFileImporter.importFromPath(kRealFile);
      final ms = DateTime.now().difference(t0).inMilliseconds;
      final rss1 = ProcessInfo.currentRss;
      // ignore: avoid_print
      print('IMPORT_MS=$ms RSS_DELTA_MB='
          '${((rss1 - rss0) / 1024 / 1024).toStringAsFixed(1)}');
      // ignore: avoid_print
      print('PARSED roads=${bm.roads.length} buildings=${bm.buildings.length} '
          'places=${bm.places.length}');

      // 独立统计应与解析一致（Multi* 已展开）
      expect(bm.buildings.length, rawCount['poly'],
          reason: '建筑数应等于 Polygon+MultiPolygon 子几何数');
      expect(bm.roads.length, rawCount['road'],
          reason: '道路数应等于 LineString+MultiLineString 子几何数');
      expect(bm.places.length, rawCount['place'],
          reason: '地名数应等于 Point+MultiPoint 子几何数');

      // 落盘 + 回读
      final store = await LocalBasemapStore.open();
      expect(store.exists(), isTrue);
      final meta = store.meta();
      expect(meta['sourceName'], '信阳矢量底图_整市.geojson');
      expect(meta['roads'], bm.roads.length);
      expect(meta['buildings'], bm.buildings.length);
      expect(meta['places'], bm.places.length);
      expect(meta['savedAt'], isA<int>());

      final savedFile = File('${dir.path}/labels/basemap/local/imported.geojson');
      expect(savedFile.existsSync(), isTrue, reason: '原始 GeoJSON 应落盘');
      // ignore: avoid_print
      print('SAVED_BYTES=${savedFile.lengthSync()} '
          '(${(savedFile.lengthSync() / 1024 / 1024).toStringAsFixed(2)}MB)');

      final loaded = await store.load();
      expect(loaded, isNotNull, reason: '落盘后必须能 load 回读');
      expect(loaded!.roads.length, bm.roads.length);
      expect(loaded.buildings.length, bm.buildings.length);
      expect(loaded.places.length, bm.places.length);
    }, timeout: const Timeout(Duration(minutes: 3)),
        // 该用例依赖本机桌面上的 18MB 真实样本。CI 或换一台机器时样本不存在，
        // 此时自动跳过，避免「样本固件缺失」把整条构建流水线判红；
        // 本机样本在，则照常执行真实的端到端校验。
        skip: File(kRealFile).existsSync()
            ? null
            : '缺少本机样本 $kRealFile，跳过真实文件端到端用例');
  });

  group('B-边界：错误输入的中文报错 + 不落盘', () {
    test('①非 JSON → FormatException，且不落盘', () async {
      final src = File('${dir.path}/bad.geojson')
        ..writeAsStringSync('这只是一段普通文本，不是 JSON');
      await expectLater(
        BasemapFileImporter.importFromPath(src.path),
        throwsA(isA<FormatException>()),
      );
      final store = await LocalBasemapStore.open();
      expect(store.exists(), isFalse);
    });

    test('②空 FeatureCollection → FormatException', () async {
      final src = File('${dir.path}/empty.geojson')
        ..writeAsStringSync('{"type":"FeatureCollection","features":[]}');
      await expectLater(
        BasemapFileImporter.importFromPath(src.path),
        throwsFormatException,
      );
    });

    test('③超过上限 → BasemapImportException 中文「文件过大」，不落盘', () async {
      final src = File('${dir.path}/ok.geojson')
        ..writeAsStringSync(sampleGeoJson());
      try {
        await BasemapFileImporter.importFromPath(src.path, limit: 8);
        fail('应抛 BasemapImportException');
      } on BasemapImportException catch (e) {
        expect(e.message, contains('文件过大'));
        expect(e.message, contains('MB'));
        expect(e.toString(), e.message);
      }
      final store = await LocalBasemapStore.open();
      expect(store.exists(), isFalse);
    });

    test('④文件不存在 → FileSystemException', () async {
      await expectLater(
        BasemapFileImporter.importFromPath('${dir.path}/nope.geojson'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('⑤带 BOM → 正常解析', () async {
      final src = File('${dir.path}/bom.geojson')
        ..writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode(sampleGeoJson())]);
      final bm = await BasemapFileImporter.importFromPath(src.path);
      expect(bm.roads.length, 1);
      expect(bm.buildings.length, 1);
    });
  });

  group('B-数据安全：失败导入不得破坏已导入的好数据（重点）', () {
    test('先导入好数据 → 再导入坏数据 → 好数据原封不动、仍可 load', () async {
      // 1) 导入好数据
      final good = File('${dir.path}/good.geojson')
        ..writeAsStringSync(sampleGeoJson());
      await BasemapFileImporter.importFromPath(good.path,
          sourceName: 'good.geojson');
      final store = await LocalBasemapStore.open();
      final savedFile =
          File('${dir.path}/labels/basemap/local/imported.geojson');
      final metaFile =
          File('${dir.path}/labels/basemap/local/imported.meta.json');
      expect(store.exists(), isTrue);
      final goodBytes = savedFile.readAsBytesSync();
      final goodMeta = metaFile.readAsBytesSync();
      final goodLoaded = await store.load();
      expect(goodLoaded, isNotNull);
      final goodRoads = goodLoaded!.roads.length;

      // 2) 三种坏输入依次尝试
      final bad1 = File('${dir.path}/bad.geojson')
        ..writeAsStringSync('not json at all');
      final bad2 =
          File('${dir.path}/empty.geojson')..writeAsStringSync('{"type":"FeatureCollection","features":[]}');
      final bad3 = File('${dir.path}/tooBig.geojson')
        ..writeAsStringSync(sampleGeoJson());

      await expectLater(BasemapFileImporter.importFromPath(bad1.path),
          throwsA(isA<FormatException>()));
      await expectLater(BasemapFileImporter.importFromPath(bad2.path),
          throwsFormatException);
      await expectLater(
          BasemapFileImporter.importFromPath(bad3.path, limit: 4),
          throwsA(isA<BasemapImportException>()));

      // 3) 好数据必须原封不动
      expect(savedFile.readAsBytesSync(), equals(goodBytes),
          reason: '坏导入不得改写已落盘的 imported.geojson 字节');
      expect(metaFile.readAsBytesSync(), equals(goodMeta),
          reason: '坏导入不得改写元信息');
      final still = await store.load();
      expect(still, isNotNull, reason: '好数据仍必须可 load');
      expect(still!.roads.length, goodRoads);
      expect(store.meta()['sourceName'], 'good.geojson');
    });
  });

  group('C. IO 层接线正确性', () {
    test('decodeBytes：BOM 跳过 + 非法字节不抛', () {
      expect(BasemapFileImporter.decodeBytes(const [0xEF, 0xBB, 0xBF, 0x61]),
          'a');
      expect(BasemapFileImporter.decodeBytes(const []), '');
      expect(() => BasemapFileImporter.decodeBytes(const [0xFF, 0x00, 0x80]),
          returnsNormally);
    });

    test('basename 跨平台 + importFromBytes 回退路径落盘', () async {
      expect(BasemapFileImporter.basename('/x/y/信阳.geojson'), '信阳.geojson');
      expect(BasemapFileImporter.basename(r'a\b\f.json'), 'f.json');
      final bm = await BasemapFileImporter.importFromBytes(
          utf8.encode(sampleGeoJson()),
          sourceName: 'bytes.geojson');
      expect(bm.roads.length, 1);
      final store = await LocalBasemapStore.open();
      expect(store.meta()['sourceName'], 'bytes.geojson');
      expect(await store.load(), isNotNull);
    });

    test('解析/存储语义复用既有实现：GeoJsonImporter 直接解析同文本结果一致',
        () async {
      final bmDirect = GeoJsonImporter.parse(sampleGeoJson());
      final bmFile = await BasemapFileImporter.importFromText(sampleGeoJson());
      expect(bmFile.roads.length, bmDirect.roads.length);
      expect(bmFile.buildings.length, bmDirect.buildings.length);
      expect(bmFile.places.length, bmDirect.places.length);
    });
  });
}
