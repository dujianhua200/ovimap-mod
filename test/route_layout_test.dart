import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/geo/route_layout.dart';

void main() {
  test('autoPoles：杆数 = ceil(总长/档距)+1，且首=起点、末=终点', () {
    final poles = RouteLayout.autoPoles(
      startLat: 0,
      startLon: 0,
      endLat: 0,
      endLon: 0.01,
      spacingM: 50,
    );
    final total = RouteLayout.haversineM(0, 0, 0, 0.01);
    final expected = (total / 50).ceil() + 1;
    expect(poles.length, expected,
        reason: '杆数应等于 ceil(总长/50)+1（含起点与终点）');
    expect(poles.first[0], closeTo(0, 1e-9));
    expect(poles.first[1], closeTo(0, 1e-9));
    expect(poles.last[0], closeTo(0, 1e-9));
    expect(poles.last[1], closeTo(0.01, 1e-9));
  });

  test('autoPoles：中间各档间距约等于档距（末段除外）', () {
    final poles = RouteLayout.autoPoles(
      startLat: 32.10,
      startLon: 114.00,
      endLat: 32.10,
      endLon: 114.03,
      spacingM: 50,
    );
    expect(poles.length, greaterThan(3));
    for (var i = 1; i < poles.length - 1; i++) {
      final d = RouteLayout.haversineM(
          poles[i - 1][0], poles[i - 1][1], poles[i][0], poles[i][1]);
      expect(d, closeTo(50, 1.0), reason: '第 $i 档应约 50m');
    }
  });

  test('destination/bearing：按方位角前进的距离与目标一致', () {
    final b = RouteLayout.bearingDeg(32.10, 114.00, 32.11, 114.02);
    final p = RouteLayout.destination(32.10, 114.00, b, 1000);
    final d = RouteLayout.haversineM(32.10, 114.00, p[0], p[1]);
    expect(d, closeTo(1000, 2));
  });

  test('autoPoles：起止重合返回单点', () {
    final poles = RouteLayout.autoPoles(
      startLat: 32.1,
      startLon: 114.0,
      endLat: 32.1,
      endLon: 114.0,
      spacingM: 50,
    );
    expect(poles.length, 1);
  });
}
