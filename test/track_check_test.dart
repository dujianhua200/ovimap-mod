import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/track_check.dart';

void main() {
  // 一条东西向轨迹：114.000→114.003（约 281m），纬度 32.10
  List<MapLabel> track() => [
        MapLabel(typeId: 'track', lat: 32.10, lon: 114.0000),
        MapLabel(typeId: 'track', lat: 32.10, lon: 114.0015),
        MapLabel(typeId: 'track', lat: 32.10, lon: 114.0030),
      ];

  test('轨迹核查：线上杆偏移≈0，不报异常', () {
    final poles = [
      MapLabel(typeId: 'pipe', name: 'GK-1', lat: 32.10, lon: 114.0005),
      MapLabel(typeId: 'pipe', name: 'GK-2', lat: 32.10, lon: 114.0020),
    ];
    final r = TrackChecker.check(track(), poles);
    expect(r.poleCount, 2);
    expect(r.outliers, isEmpty);
    expect(r.avgOffset, lessThan(2));
  });

  test('轨迹核查：偏离杆（>30m）被识别并按偏移降序', () {
    final poles = [
      // 32.10 纬度上 0.001 lon ≈ 94m
      MapLabel(typeId: 'pipe', name: '偏北杆', lat: 32.1010, lon: 114.0010),
      MapLabel(typeId: 'pipe', name: '严重偏杆', lat: 32.1030, lon: 114.0010),
      MapLabel(typeId: 'pipe', name: '线上杆', lat: 32.10, lon: 114.0020),
    ];
    final r = TrackChecker.check(track(), poles);
    expect(r.outliers.length, 2);
    // 严重偏杆（约 333m）排第一
    expect(r.outliers.first.$1.name, '严重偏杆');
    expect(r.outliers.first.$2, greaterThan(300));
    expect(r.outliers.last.$1.name, '偏北杆');
    expect(r.outliers.last.$2, greaterThan(100));
  });

  test('轨迹核查：轨迹太短或无杆时安全返回', () {
    final one = [MapLabel(typeId: 'track', lat: 32.10, lon: 114.0)];
    final r1 = TrackChecker.check(one, track());
    expect(r1.trackLen, 0);
    final r2 = TrackChecker.check(track(), []);
    expect(r2.poleCount, 0);
  });
}
