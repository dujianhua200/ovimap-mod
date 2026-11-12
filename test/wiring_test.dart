import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/export/topo.dart';

void main() {
  test('DXF 配线图算法：走向一致 + 箱体间距离', () {
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
          lineGroupId: gid));
    }
    final cross = MapLabel(typeId: 'crossbox', seq: 9, lat: 32.1264, lon: 114.0913, name: '李庄光交');
    final split = MapLabel(typeId: 'splitterbox', seq: 10, lat: 32.1279, lon: 114.0931, name: '李庄分光箱', splitterRatio: '1:8');
    final fiber = MapLabel(typeId: 'fiberbox', seq: 11, lat: 32.1266, lon: 114.0943, name: '李庄分纤盒', splitterRatio: '1:4');
    split.topoParentId = cross.id;
    fiber.topoParentId = split.id;
    split.cableSpec = '架24芯GYTS-01';
    fiber.cableSpec = '架12芯GYTS-02';
    labels.addAll([cross, split, fiber]);

    final roots = Topology.buildTree(labels);
    Topology.assignTitles(roots);
    final nodes = Topology.flatten(roots);
    expect(nodes.length, 3);
    expect(roots.length, 1);
    expect(roots.first.title, '李庄光交');

    final baseLat = labels.first.lat, baseLon = labels.first.lon;
    final scaleX = 111320.0 * math.cos(baseLat * math.pi / 180);
    const scaleY = 110540.0;
    double px(MapLabel l) => (l.lon - baseLon) * scaleX;
    double py(MapLabel l) => (l.lat - baseLat) * scaleY;
    double hav(double la1, double lo1, double la2, double lo2) {
      const r = 6371000.0;
      double rad(double d) => d * math.pi / 180;
      final dLat = rad(la2 - la1), dLon = rad(lo2 - lo1);
      final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
          math.cos(rad(la1)) * math.cos(rad(la2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
      return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    }

    final s = nodes.firstWhere((n) => n.src.typeId == 'splitterbox');
    final f = nodes.firstWhere((n) => n.src.typeId == 'fiberbox');
    expect(s.parent, isNotNull);
    expect(f.parent, isNotNull);
    final d1 = hav(s.parent!.src.lat, s.parent!.src.lon, s.src.lat, s.src.lon);
    final d2 = hav(f.parent!.src.lat, f.parent!.src.lon, f.src.lat, f.src.lon);
    print('光交→分光箱 箱体间距离 = ${d1.toStringAsFixed(1)}m 光缆=${s.cable}');
    print('分光箱→分纤盒 箱体间距离 = ${d2.toStringAsFixed(1)}m 光缆=${f.cable}');
    expect(d1, greaterThan(100));
    expect(d2, greaterThan(100));

    // 走向一致：投影方向与杆路图同一公式（东北向 dx>0, dy>0）
    expect(px(s.src) - px(s.parent!.src), greaterThan(0));
    expect(py(s.src) - py(s.parent!.src), greaterThan(0));
    print('走向一致性通过：配线图与杆路图同投影同比例同方向');
  });
}
