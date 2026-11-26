import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/export/basemap.dart';
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

/// 生成一份"整幅图"级别的合成底图：路网含小路/田间路，建筑散布，村庄在远端。
BasemapData buildWideBasemap() {
  const baseLat = 32.1264, baseLon = 114.0913;
  // 1 米 ≈ 0.00000905°(纬) / 0.0000106°(经)
  double latM(double m) => baseLat + m * 0.00000905;
  double lonM(double m) => baseLon + m * 0.0000106;

  final roads = <RoadPoly>[
    RoadPoly([
      [latM(-450), lonM(-450)],
      [latM(450), lonM(-450)],
    ], RoadGrade.trunk, '京广路'),
    RoadPoly([
      [latM(-450), lonM(-120)],
      [latM(450), lonM(-120)],
    ], RoadGrade.residential, '村前街'),
    RoadPoly([
      [latM(-200), lonM(-450)],
      [latM(-180), lonM(450)],
    ], RoadGrade.service, '机耕道'),
    RoadPoly([
      [latM(320), lonM(-400)],
      [latM(330), lonM(400)],
    ], RoadGrade.other, '乡间小路'),
  ];

  final buildings = <BuildingPoly>[];
  for (var i = 0; i < 40; i++) {
    final cx = -420.0 + (i % 10) * 90.0;
    final cy = -380.0 + (i ~/ 10) * 120.0;
    buildings.add(BuildingPoly([
      [
        [latM(cy - 5), lonM(cx - 5)],
        [latM(cy - 5), lonM(cx + 5)],
        [latM(cy + 5), lonM(cx + 5)],
        [latM(cy + 5), lonM(cx - 5)],
        [latM(cy - 5), lonM(cx - 5)],
      ]
    ], ''));
  }

  final places = <PlaceFeature>[
    PlaceFeature(
        name: '李庄村', lat: latM(300), lon: lonM(300), level: PlaceLevel.village),
    PlaceFeature(
        name: '王湾', lat: latM(-320), lon: lonM(260), level: PlaceLevel.hamlet),
    PlaceFeature(
        name: '小李庄', lat: latM(160), lon: lonM(-340), level: PlaceLevel.hamlet),
    PlaceFeature(
        name: '镇区', lat: latM(0), lon: lonM(0), level: PlaceLevel.town),
  ];

  return BasemapData(
    roads: roads,
    buildings: buildings,
    places: places,
    extras: const [],
    report: BasemapFetchReport(
      roads: DatasetReport(FetchState.ok, source: 'test', count: roads.length),
      buildings: DatasetReport(FetchState.ok,
          source: 'test', count: buildings.length),
      places:
          DatasetReport(FetchState.ok, source: 'test', count: places.length),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('图幅口径：小路/建筑/村庄全量入图，注记用 72=4 正中', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap334');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final labels = <MapLabel>[
      MapLabel(typeId: 'pole', seq: 1, lat: 32.1260, lon: 114.0900,
          lineGroupId: 'g1'),
      MapLabel(typeId: 'pole', seq: 2, lat: 32.1264, lon: 114.0913,
          lineGroupId: 'g1'),
      MapLabel(typeId: 'pole', seq: 3, lat: 32.1268, lon: 114.0926,
          lineGroupId: 'g1'),
    ];

    final bm = buildWideBasemap();
    final r = await DxfExporter.export(
      name: 'v334图幅口径',
      labels: labels,
      includeSurroundings: true,
      basemap: bm,
      coverage: BasemapCoverage.frame,
      fixedScale: 3000,
      version: DxfVersion.r12,
      layerRoads: true,
      layerPlaces: true,
    );

    final text = gbk_bytes.decode(r.file.readAsBytesSync());
    // 合成底图未被裁剪：40 栋建筑全部写出
    final jz = 'JianZhu'.allMatches(text).length;
    expect(jz, greaterThanOrEqualTo(40));
    // 小路也写出（DaoLu / DaoLuBian 图层存在几何）
    expect(text, contains('DaoLuBian'));
    // 村庄名不再丢
    expect(text, contains('李庄村'));
    expect(text, contains('王湾'));
    expect(text, contains('小李庄'));
    // 注记正中对齐
    expect(text, contains('72\n4\n'));
    // 路名写在路面上方（字号与路宽脱钩）：residential 1.3mm → 3.9 图纸单位
    expect(text, contains('村前街'));

    // 落一份样本，供人工渲染核对（用系统临时目录，Windows/macOS 通用）
    final sample = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}ovimap_v334_sample.dxf');
    r.file.copySync(sample.path);
    // ignore: avoid_print
    print('SAMPLE ${sample.path}');
  });
}
