// 内置兜底底图 + 地图标签缩放/颜色的验收。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/bundled_basemap.dart';
import 'package:ovimap/models/label_type.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/label_marker.dart';
import 'package:ovimap/ui/map/map_canvas.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('内置兜底底图', () {
    setUp(() => BundledBasemap.resetForTest());

    test('默认关闭（不拖慢测试与启动）', () {
      expect(BundledBasemap.enabled, isFalse);
    });

    test('资源登记齐全（三个 gz 都在 pubspec 且能读到）', () async {
      // pubspec 登记检查：读不到会在 load 时抛，这里直接验资源存在
      final root = Directory.current;
      for (final name in const [
        'xinyang.geojson.gz',
        'xinyang_roads.geojson.gz',
        'xinyang_places.geojson.gz',
      ]) {
        final f = File('${root.path}/assets/buildings/$name');
        expect(f.existsSync(), isTrue, reason: '缺少兜底数据 $name');
        expect(f.lengthSync(), greaterThan(1000), reason: '$name 内容异常');
      }
    });

    test('覆盖范围判定：只有信阳 bbox 内才用内置数据', () {
      // 信阳中心
      expect(BundledBasemap.covers(114.05, 32.10, 114.10, 32.15), isTrue);
      // 武汉（范围外）
      expect(BundledBasemap.covers(114.25, 30.55, 114.35, 30.62), isFalse);
      // 跨出边界但**有交集** → v3.13 起算覆盖（越界部分自然无数据）
      //
      // 旧语义是"完全包含才算"，线路稍压县界就整块跳过兜底 ——
      // 这正是用户三次反馈"地图包没用上"的原因之一。
      expect(BundledBasemap.covers(115.5, 32.10, 116.0, 32.20), isTrue,
          reason: '有交集即覆盖（越界部分由 bbox 查询自然过滤）');
      // 完全在外（东侧 116.0 之外）
      expect(BundledBasemap.covers(116.2, 32.10, 116.5, 32.20), isFalse);
    });

    test('实际加载：道路/地名/建筑都能按 bbox 查到', () async {
      // 走测试旁路：只有本用例需要真数据（自己承担 ~15s 加载）
      BundledBasemap.setTestBypass(true);
      expect(BundledBasemap.enabled, isTrue);
      final b = await BundledBasemap.instance;
      // 信阳建成区附近
      const lonMin = 114.03, latMin = 32.09, lonMax = 114.14, latMax = 32.16;
      final roads = b.roadsIn(lonMin, latMin, lonMax, latMax);
      final places = b.placesIn(lonMin, latMin, lonMax, latMax);
      final blds = b.buildingsIn(lonMin, latMin, lonMax, latMax);

      expect(b.roadsLoaded, isTrue, reason: '道路数据应已解析');
      expect(b.buildingsLoaded, isTrue, reason: '建筑数据应已解析');
      expect(roads, isNotEmpty, reason: '信阳范围内应有道路');
      expect(blds, isNotEmpty, reason: '信阳范围内应有建筑轮廓');

      // 坐标口径：项目内部统一 [lat, lon]，不能是 GeoJSON 的 [lon, lat]
      final p = roads.first.pts.first;
      expect(p[0], inInclusiveRange(31.0, 33.0), reason: '第一个分量应是纬度');
      expect(p[1], inInclusiveRange(113.0, 116.0), reason: '第二个分量应是经度');

      // 地名点同样校验
      if (places.isNotEmpty) {
        final pl = places.first;
        expect(pl.lat, inInclusiveRange(31.0, 33.0));
        expect(pl.lon, inInclusiveRange(113.0, 116.0));
      }
    });

    test('summary 能报告各项条数（诊断用）', () async {
      BundledBasemap.setTestBypass(true);
      final b = await BundledBasemap.instance;
      final s = b.summary();
      expect(s, contains('道路'));
      expect(s, contains('建筑'));
    });
  });

  group('地图标签随缩放', () {
    test('倍率随 zoom 单调递增，且被夹在合理区间', () {
      final z10 = labelScaleForZoomForTest(10);
      final z14 = labelScaleForZoomForTest(14);
      final z16 = labelScaleForZoomForTest(16);
      final z19 = labelScaleForZoomForTest(19);

      expect(z14, greaterThan(z10), reason: '放大应变大');
      expect(z19, greaterThan(z16), reason: '继续放大继续变大');
      // 16 级为基准 1.0
      expect(z16, closeTo(1.0, 1e-6));
      // 边界（v3.13：用户反馈标签太大，上下限一并下调）
      expect(labelScaleForZoomForTest(0), closeTo(0.40, 1e-6),
          reason: '远景应有下限，否则看不见');
      expect(labelScaleForZoomForTest(24), closeTo(2.0, 1e-6),
          reason: '近景上限 2.0（原 3.2 会糊满屏幕）');
    });

    test('缩放倍率不会为 0 或负数（否则 Marker 尺寸非法）', () {
      for (final z in [0.0, 3.0, 8.0, 16.0, 21.5, 30.0]) {
        expect(labelScaleForZoomForTest(z), greaterThan(0.0));
      }
    });
  });

  group('地图标签颜色', () {
    test('默认跟随类型（null），可设置并持久化，可恢复', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());

      expect(st.labelColor, 0);
      expect(st.labelColorOrNull, isNull, reason: '未配置时应跟随类型自带色');

      st.setLabelColor(0xFFD32F2F);
      expect(st.labelColor, 0xFFD32F2F);
      expect(st.labelColorOrNull, const Color(0xFFD32F2F));

      st.setLabelColor(0); // 恢复默认
      expect(st.labelColorOrNull, isNull);
    });

    test('overrideColor 传入后符号仍可正常构建（不崩）', () {
      final l = MapLabel(typeId: 'gl001', lat: 32.0, lon: 114.0, name: 'A');
      expect(
        () => LabelSymbol(
            label: l, overrideColor: const Color(0xFF1565C0), scale: 1.5),
        returnsNormally,
      );
      // 内置符号同样支持
      final l2 = MapLabel(typeId: 'pipe', lat: 32.0, lon: 114.0, name: 'B');
      expect(
        () => LabelSymbol(
            label: l2, overrideColor: const Color(0xFF1565C0), scale: 0.6),
        returnsNormally,
      );
    });
  });

  group('DXF 出图口径（回归锁）', () {
    test('LabelType 图例符号仍可用（前几轮成果不回退）', () {
      expect(LabelType.builtin, isNotEmpty);
      expect(LabelType.all.length, greaterThanOrEqualTo(LabelType.builtin.length));
    });
  });
}
