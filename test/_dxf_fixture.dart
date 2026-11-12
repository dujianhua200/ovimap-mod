import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 结构/e2e/验收测试共用的路径提供者（把导出目录指到临时目录）。
class FakePathProvider extends PathProviderPlatform {
  final String root;
  FakePathProvider(this.root);
  @override
  Future<String?> getExternalStoragePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// 共用标签夹具：8 杆管链（含拓扑箱体），保证导出含丰富实体与配线图。
List<MapLabel> buildFixtureLabels() {
  const gid = 'g1';
  final labels = <MapLabel>[];
  const offsets = [
    (0.0, 0.0),
    (0.0004, 0.0002),
    (0.0009, 0.0005),
    (0.0013, 0.0011),
    (0.0015, 0.0018),
    (0.0013, 0.0024),
    (0.0008, 0.0028),
    (0.0002, 0.0030),
  ];
  for (var i = 0; i < offsets.length; i++) {
    labels.add(MapLabel(
      typeId: 'pipe',
      seq: i + 1,
      lat: 32.1264 + offsets[i].$1,
      lon: 114.0913 + offsets[i].$2,
      lineGroupId: gid,
      distLabel: i == 2 ? '埋42.5' : '',
    ));
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
  return labels;
}

/// 直线（n 段）辅助。
List<List<double>> _line(double lat0, double lon0, double lat1, double lon1,
    {int n = 4}) {
  final out = <List<double>>[];
  for (var i = 0; i <= n; i++) {
    final t = i / n;
    out.add([lat0 + (lat1 - lat0) * t, lon0 + (lon1 - lon0) * t]);
  }
  return out;
}

/// 合成底图（**无网络**）：≥4 等级道路 + 带孔建筑 + 三级地名 + 全成功报告。
BasemapData buildSyntheticBasemap() {
  final roads = <RoadPoly>[
    RoadPoly(_line(32.1264, 114.0900, 32.1264, 114.0935, n: 6), RoadGrade.trunk,
        '主干道'),
    RoadPoly(_line(32.1258, 114.0913, 32.1282, 114.0913, n: 6),
        RoadGrade.primary, '人民路'),
    RoadPoly(_line(32.1260, 114.0920, 32.1272, 114.0928, n: 4),
        RoadGrade.secondary, '支路A'),
    RoadPoly(_line(32.1300, 114.0913, 32.1306, 114.0920, n: 3),
        RoadGrade.residential, ''),
    RoadPoly(_line(32.1250, 114.0940, 32.1260, 114.0950, n: 3),
        RoadGrade.service, ''), // 无名 service：验证 N1 保留
  ];

  // 带孔建筑：rings[0]=外环，rings[1]=内环
  final outer = <List<double>>[
    [32.1268, 114.0918],
    [32.1268, 114.0924],
    [32.1273, 114.0924],
    [32.1273, 114.0918],
  ];
  final inner = <List<double>>[
    [32.1269, 114.0919],
    [32.1269, 114.0923],
    [32.1272, 114.0923],
    [32.1272, 114.0919],
  ];
  final simple = <List<double>>[
    [32.1252, 114.0930],
    [32.1252, 114.0935],
    [32.1257, 114.0935],
    [32.1257, 114.0930],
  ];
  final buildings = <BuildingPoly>[
    BuildingPoly([outer, inner], '李庄1号楼'),
    BuildingPoly([simple], ''),
  ];

  final places = <PlaceFeature>[
    const PlaceFeature(
        name: '测试市', lat: 32.1200, lon: 114.0900, level: PlaceLevel.city),
    const PlaceFeature(
        name: '李庄村', lat: 32.1280, lon: 114.0920, level: PlaceLevel.village),
    const PlaceFeature(
        name: '和谐花园',
        lat: 32.1270,
        lon: 114.0926,
        level: PlaceLevel.residential,
        isArea: true),
  ];

  return BasemapData(
    roads: roads,
    buildings: buildings,
    places: places,
    report: const BasemapFetchReport(
      roads: DatasetReport(FetchState.ok, source: 'test', count: 5),
      buildings: DatasetReport(FetchState.ok, source: 'test', count: 2),
      places: DatasetReport(FetchState.ok, source: 'test', count: 3),
    ),
  );
}
