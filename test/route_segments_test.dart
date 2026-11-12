import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/geo/geo_util.dart';
import 'package:ovimap/geo/route_segments.dart';
import 'package:ovimap/models/map_label.dart';

void main() {
  // 工具：构造一个参与连线的点。
  MapLabel mk(String gid,
      {int seq = 1,
      String name = '',
      double lat = 32.0,
      double lon = 114.0,
      double? distanceM,
      String distLabel = '',
      int segKind = 0,
      double slackM = 0,
      String segCable = ''}) {
    return MapLabel(
      typeId: 'pipe',
      seq: seq,
      name: name,
      lat: lat,
      lon: lon,
      lineGroupId: gid,
      distanceM: distanceM,
      distLabel: distLabel,
      segKind: segKind,
      slackM: slackM,
      segCable: segCable,
    );
  }

  test('链分组正确：复用 buildLabelChains，箱体不剪断杆路', () {
    final p1 = mk('g1', seq: 1, name: 'GK-1', lat: 32.0, lon: 114.0);
    final box = MapLabel(
        typeId: 'fiberbox', lat: 32.0005, lon: 114.0005, name: '分纤盒');
    final p2 = mk('g1', seq: 2, name: 'GK-2', lat: 32.001, lon: 114.001);
    final segs = RouteSegment.build([p1, box, p2]);
    // 箱体不连线 → 只有 1 段（p1→p2），且段终点就是 p2。
    expect(segs.length, 1);
    expect(identical(segs.first.from, p1), isTrue);
    expect(identical(segs.first.to, p2), isTrue);
    expect(segs.first.chainIndex, 0);
    expect(segs.first.segIndex, 1);
  });

  test('段数 = Σ(每条链长度-1)', () {
    final gA = [mk('A', seq: 1), mk('A', seq: 2), mk('A', seq: 3)]; // 2 段
    final gB = [mk('B', seq: 4), mk('B', seq: 5)]; // 1 段
    final gC = [mk('C', seq: 6)]; // 单点链 → 0 段
    final segs = RouteSegment.build([...gA, ...gB, ...gC]);
    expect(segs.length, 3);
    // 每段都能定位回对应链首尾点
    expect(identical(segs[0].from, gA[0]) && identical(segs[0].to, gA[1]), isTrue);
    expect(identical(segs[1].from, gA[1]) && identical(segs[1].to, gA[2]), isTrue);
    expect(identical(segs[2].from, gB[0]) && identical(segs[2].to, gB[1]), isTrue);
  });

  test('lengthM：distanceM 优先，否则 haversine；manualLength 准确反映', () {
    final from = mk('g', seq: 1, lat: 32.0, lon: 114.0);
    // to1 手填 distanceM=42 → 取 42，manualLength=true
    final to1 = mk('g', seq: 2, lat: 32.001, lon: 114.001, distanceM: 42);
    // to2 不填 → 取 haversine，manualLength=false
    final to2 = mk('g', seq: 3, lat: 32.002, lon: 114.002);
    final segs = RouteSegment.build([from, to1, to2]);

    expect(segs[0].lengthM, 42);
    expect(segs[0].manualLength, isTrue);

    final expectHav = GeoUtil.haversine(to1.lat, to1.lon, to2.lat, to2.lon);
    expect(segs[1].lengthM, closeTo(expectHav, 1e-9));
    expect(segs[1].manualLength, isFalse);
  });

  test('text 走 segTextFor：实时从 segKind 推导前缀，去 .0 毛刺', () {
    final from = mk('g', seq: 1, lat: 32.0, lon: 114.0);
    final toK1 = mk('g', seq: 2, lat: 32.001, lon: 114.001,
        distanceM: 38, segKind: 1); // 架空
    final toK2 = mk('g', seq: 3, lat: 32.002, lon: 114.002,
        distanceM: 38, segKind: 2); // 埋地（证明按 segKind 实时推导，非写死）
    final toHand = mk('g', seq: 4, lat: 32.003, lon: 114.003,
        distanceM: 38, segKind: 1, distLabel: '手填99'); // 手填优先
    final toHalf = mk('g', seq: 5, lat: 32.004, lon: 114.004,
        distanceM: 42.5, segKind: 3); // 管道 + 非整数

    final labels = [from, toK1, toK2, toHand, toHalf];
    for (final prefix in ['', 'G']) {
      final segs = RouteSegment.build(labels, prefix: prefix);
      for (final s in segs) {
        // 每个段的 text 必须与 segTextFor 口径一致（实时推导真源）
        expect(s.text,
            GeoUtil.segTextFor(s.to, GeoUtil.segDistText(s.lengthM), prefix: prefix));
      }
    }
    // 具体值（无全局前缀）
    final segs = RouteSegment.build(labels, prefix: '');
    expect(segs[0].text, '架38'); // 架空 → 架 + 38（无 .0）
    expect(segs[1].text, '埋38'); // 改 segKind=2 → 埋 + 38（同一距离，前缀随 kind 变）
    expect(segs[2].text, '手填99'); // distLabel 优先级最高
    expect(segs[3].text, '管42.5'); // 管道 + 42.5（小数保留）
    // 带全局前缀 G 时：有敷设方式仍用 kind 前缀（autoKindPrefix 优先于全局前缀）
    final segsG = RouteSegment.build(labels, prefix: 'G');
    expect(segsG[0].text, '架38');
    expect(segsG[3].text, '管42.5');
  });

  test('autoPrefix getter：实时从 kind 推导', () {
    final from = mk('g', seq: 1, lat: 32.0, lon: 114.0);
    final to = mk('g', seq: 2, lat: 32.001, lon: 114.0, segKind: 1);
    expect(RouteSegment.build([from, to]).first.autoPrefix, '架');
    to.segKind = 2;
    expect(RouteSegment.build([from, to]).first.autoPrefix, '埋');
    to.segKind = 0; // 默认方式 → null
    expect(RouteSegment.build([from, to]).first.autoPrefix, isNull);
  });

  test('回归：移动终点坐标使段距变化，text 实时跟随（不写死失真）', () {
    final from = mk('g', seq: 1, lat: 32.0, lon: 114.0);
    // 无 distanceM、无 distLabel：段距完全由坐标实时算，前缀由 segKind 实时推导
    final to = mk('g', seq: 2, lat: 32.001, lon: 114.0, segKind: 1);
    var segs = RouteSegment.build([from, to], prefix: '');
    final before = segs.first.text;
    expect(before, startsWith('架'));

    // 移动终点使段距≈55m（不碰 distLabel），text 必须自动跟随
    to.lat = 32.000495;
    segs = RouteSegment.build([from, to], prefix: '');
    final after = segs.first.text;
    expect(after, isNot(equals(before)), reason: '挪点后 text 应变化');
    expect(after, '架55', reason: '实时从 segKind(1) 推导前缀 + 实时 haversine 距离');
    expect(segs.first.lengthM, closeTo(55.0, 0.5));
  });

  test('kindName / kindPrefix 映射', () {
    expect(RouteSegment.kindName(0), '默认');
    expect(RouteSegment.kindName(1), '架空');
    expect(RouteSegment.kindName(2), '埋地');
    expect(RouteSegment.kindName(3), '管道');
    expect(RouteSegment.kindName(99), '默认'); // 未知 → 默认

    expect(RouteSegment.kindPrefix, const <int, String>{1: '架', 2: '埋', 3: '管'});
    expect(RouteSegment.kindPrefix.containsKey(0), isFalse); // 0 不在表内
    expect(RouteSegment.kindPrefix[1], '架');
  });

  test('单点链产出 0 段，不报错', () {
    final only = mk('g', seq: 1, lat: 32.0, lon: 114.0);
    expect(RouteSegment.build([only]), isEmpty);
    // 无线组的点也不参与
    final noGroup = MapLabel(typeId: 'pipe', seq: 1);
    expect(RouteSegment.build([noGroup]), isEmpty);
  });

  test('段字段透传：kind/slackM/cable/groupId', () {
    final from = mk('g', seq: 1, lat: 32.0, lon: 114.0);
    final to = mk('g', seq: 2, lat: 32.001, lon: 114.001,
        distanceM: 10, segKind: 2, slackM: 3.5, segCable: '48芯GYTS');
    final s = RouteSegment.build([from, to]).first;
    expect(s.kind, 2);
    expect(s.slackM, 3.5);
    expect(s.cable, '48芯GYTS');
    expect(s.groupId, 'g');
  });
}
