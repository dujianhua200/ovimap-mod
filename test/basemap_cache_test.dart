// 项目级底图缓存与失败三态（**零网络**）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/models/map_label.dart';

void main() {
  test('缓存：写入后子范围覆盖命中、超范围不命中、invalidate 生效、可离线读', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_bm_cache');
    final cache = BasemapCache(dir);

    const json = '{"elements":[{"type":"node","lat":32,"lon":114,"tags":{}}]}';
    final bbox = [32.00, 114.00, 32.01, 114.01];

    expect(await cache.read('roads', bbox), isNull, reason: '写入前应未命中');

    await cache.write('roads', bbox, json);

    // 完全相同的 bbox → 命中
    expect(await cache.read('roads', bbox), json);
    // 被包含的子范围 → 命中（覆盖复用）
    final sub = [32.002, 114.002, 32.008, 114.008];
    expect(await cache.read('roads', sub), json);
    // 超出范围 → 不命中
    final big = [31.0, 113.0, 33.0, 115.0];
    expect(await cache.read('roads', big), isNull);
    // 跨数据集隔离
    expect(await cache.read('buildings', sub), isNull);

    // 刷新底图：invalidate 覆盖该 bbox 的条目 → 变未命中
    await cache.invalidate(bbox);
    expect(await cache.read('roads', bbox), isNull);

    dir.deleteSync(recursive: true);
  });

  test('缓存：过期（超 maxAgeDays）不复用', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_bm_expire');
    final cache = BasemapCache(dir);
    final bbox = [32.0, 114.0, 32.01, 114.01];
    await cache.write('places', bbox, '{"ok":1}');
    // maxAgeDays = -1 → 任何条目都视为过期
    expect(await cache.read('places', bbox, maxAgeDays: -1), isNull);
    dir.deleteSync(recursive: true);
  });

  test('BasemapFetchReport：三态聚合与中文可操作指引', () {
    final report = BasemapFetchReport(
      roads: const DatasetReport(FetchState.ok, source: 'overpass', count: 3),
      buildings: const DatasetReport(FetchState.failed, error: '网络不可达'),
      places: const DatasetReport(
          FetchState.cached, source: 'cache', count: 5),
    );
    expect(report.anyFailed, isTrue);
    expect(report.allFailed, isFalse);
    expect(report.anyCached, isTrue);

    final w = report.toWarnings();
    // ok 且 count>0 → 不打扰（无道路行）
    expect(w.any((s) => s.contains('道路矢量')), isFalse);
    // 失败 → 明确缺哪类
    expect(w.any((s) => s.contains('建筑轮廓')), isTrue);
    // 缓存 → 说明离线复用
    expect(w.any((s) => s.contains('地名') && s.contains('缓存')), isTrue);
    // 存在失败 → 有总体指引
    expect(w.any((s) => s.contains('刷新底图')), isTrue);
  });

  test('BasemapFetchReport：全成功且均有数据 → 无警告', () {
    const report = BasemapFetchReport(
      roads: DatasetReport(FetchState.ok, count: 1),
      buildings: DatasetReport(FetchState.ok, count: 1),
      places: DatasetReport(FetchState.ok, count: 1),
    );
    expect(report.toWarnings(), isEmpty);
  });

  test('boundsOf：按纬度自适应外扩（纬/经不等距修正）', () {
    final labels = [MapLabel(lat: 32.0, lon: 114.0)];
    final b = BasemapFetcher.boundsOf(labels, 880);
    expect(b[0], lessThan(32.0));
    expect(b[2], greaterThan(32.0));
    // 纬向 880m ≈ 0.00796°（外扩为负，取绝对值）
    expect(32.0 - b[0], closeTo(880 / 110540.0, 1e-6));
    // 经向在 lat≈32° 应比纬向更大（cos(32°)≈0.848）
    expect((b[1] - 114.0).abs(), greaterThan((b[2] - 32.0).abs()));
  });
}
