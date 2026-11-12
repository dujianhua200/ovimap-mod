// 底图数据层纯解析验证（**零网络**）：N1 分级保留、N2 关系多环缝合、地名解析。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/overpass.dart';

Map<String, dynamic> _way(
    List<List<double>> pts, Map<String, dynamic> tags) {
  return {
    'type': 'way',
    'geometry': [
      for (final p in pts) {'lat': p[0], 'lon': p[1]}
    ],
    'tags': tags,
  };
}

void main() {
  test('N1：仅丢弃无名 footway/steps/cycleway/pedestrian/bridleway；'
      '无名 service/track/path/residential 保留', () {
    final json = jsonEncode({
      'elements': [
        _way([
          [32.0, 114.0],
          [32.001, 114.0]
        ], {'highway': 'service'}), // 无名内部路 → 保留
        _way([
          [32.0, 114.001],
          [32.001, 114.001]
        ], {'highway': 'track'}), // 无名 → 保留
        _way([
          [32.0, 114.002],
          [32.001, 114.002]
        ], {'highway': 'footway'}), // 无名 → 丢弃
        _way([
          [32.0, 114.003],
          [32.001, 114.003]
        ], {'highway': 'steps'}), // 无名 → 丢弃
        _way([
          [32.0, 114.004],
          [32.001, 114.004]
        ], {
          'highway': 'footway',
          'name': '小区步道'
        }), // 有名 → 保留
        _way([
          [32.0, 114.005],
          [32.001, 114.005]
        ], {'highway': 'primary', 'name': '人民路'}),
      ]
    });
    final roads = OverpassClient.parseRoads(json);
    expect(roads.length, 4);
    // service 与 track 均归 RoadGrade.service，且两者均为无名——必须保留（N1 修复）
    expect(roads.where((r) => r.grade == RoadGrade.service).length, 2,
        reason: '无名 service/track 内部路网应保留');
    expect(roads.any((r) => r.name == '人民路' && r.grade == RoadGrade.primary),
        isTrue);
    expect(roads.any((r) => r.name == '小区步道'), isTrue);
  });

  test('N1：gradeOf 分级映射（含 *_link）', () {
    expect(OverpassClient.gradeOf('motorway'), RoadGrade.trunk);
    expect(OverpassClient.gradeOf('trunk_link'), RoadGrade.trunk);
    expect(OverpassClient.gradeOf('primary'), RoadGrade.primary);
    expect(OverpassClient.gradeOf('secondary'), RoadGrade.secondary);
    expect(OverpassClient.gradeOf('tertiary_link'), RoadGrade.tertiary);
    expect(OverpassClient.gradeOf('living_street'), RoadGrade.residential);
    expect(OverpassClient.gradeOf('track'), RoadGrade.service);
    expect(OverpassClient.gradeOf('unclassified'), RoadGrade.residential);
    expect(OverpassClient.gradeOf('bridleway'), RoadGrade.other);
  });

  test('N2：way 单环 → 1 个 BuildingPoly；relation 按 role 缝合成环、'
      '每个外环一个 BuildingPoly（内环作孔）', () {
    // 一个外环（4 段）+ 一个内环（4 段）+ 另一个外环（4 段）
    List<Map<String, dynamic>> sq(double lat, double lon, double s, String role) {
      final a = [lat, lon];
      final b = [lat + s, lon];
      final c = [lat + s, lon + s];
      final d = [lat, lon + s];
      List<List<double>> seg(List<double> p, List<double> q) => [p, q];
      final segs = [seg(a, b), seg(b, c), seg(c, d), seg(d, a)];
      return [
        for (final g in segs)
          {
            'type': 'way',
            'role': role,
            'geometry': [
              for (final p in g) {'lat': p[0], 'lon': p[1]}
            ],
          }
      ];
    }

    final relation = {
      'type': 'relation',
      'tags': {'building': 'yes', 'name': '带院建筑'},
      'members': [
        ...sq(32.0000, 114.0000, 0.0010, 'outer'),
        ...sq(32.0002, 114.0002, 0.0004, 'inner'),
        ...sq(32.0020, 114.0020, 0.0010, 'outer'),
      ],
    };
    final way = _way([
      [32.0100, 114.0100],
      [32.0100, 114.0110],
      [32.0110, 114.0110]
    ], {'building': 'house', 'name': '单环'});

    final json = jsonEncode({
      'elements': [relation, way]
    });
    final buildings = OverpassClient.parseBuildings(json);

    // relation 两个外环 → 2 个 BuildingPoly；way → 1 个
    expect(buildings.length, 3);
    final withHole = buildings.firstWhere((b) => b.name == '带院建筑' && b.rings.length > 1,
        orElse: () => const BuildingPoly([], ''));
    expect(withHole.rings.length, 2, reason: '内环应作孔（rings[0]=外环, rings[1]=孔）');
    // 外环点序闭合且首尾不重复（缝合结果）
    expect(withHole.outer.length, greaterThanOrEqualTo(3));
    expect(withHole.rings.where((r) => r.length >= 3).length, greaterThanOrEqualTo(2));
  });

  test('parsePlaces：place=* 点/面 + 具名 landuse=residential', () {
    final json = jsonEncode({
      'elements': [
        {
          'type': 'node',
          'lat': 32.10,
          'lon': 114.10,
          'tags': {'place': 'village', 'name': '李庄村'}
        },
        {
          'type': 'node',
          'lat': 32.11,
          'lon': 114.11,
          'tags': {'place': 'city', 'name': '测试市'}
        },
        {
          'type': 'way',
          'center': {'lat': 32.12, 'lon': 114.12},
          'tags': {'landuse': 'residential', 'name': '和谐花园'}
        },
        {
          'type': 'node',
          'lat': 32.13,
          'lon': 114.13,
          'tags': {'landuse': 'residential'} // 无名 → 丢弃
        },
      ]
    });
    final places = OverpassClient.parsePlaces(json);
    expect(places.length, 3);
    expect(places.any((p) => p.name == '李庄村' && p.level == PlaceLevel.village),
        isTrue);
    expect(places.any((p) => p.name == '测试市' && p.level == PlaceLevel.city),
        isTrue);
    final garden = places.firstWhere((p) => p.name == '和谐花园');
    expect(garden.level, PlaceLevel.residential);
    expect(garden.isArea, isTrue);
  });

  test('OverpassEndpoints：内置含国内候选，自定义并入去重', () {
    final builtin = OverpassEndpoints.builtin();
    expect(builtin.length, greaterThanOrEqualTo(5));
    expect(builtin.any((e) => e.contains('overpass-api.de')), isTrue);
    final resolved = OverpassEndpoints.resolve(
        'https://my.example/api\nhttps://my.example/api\n,https://x.example/api');
    expect(resolved.where((e) => e == 'https://my.example/api').length, 1);
    expect(resolved.contains('https://x.example/api'), isTrue);
  });
}
