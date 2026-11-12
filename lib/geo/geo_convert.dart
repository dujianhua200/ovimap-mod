import 'dart:math' as math;

/// WGS-84 (GPS) <-> GCJ-02 (火星坐标) <-> BD-09 转换。
/// 中国境内在线地图瓦片（高德/谷歌中国/奥维导出的卫星源）多为 GCJ-02 偏移
/// 坐标系，而手机 GPS 返回 WGS-84。两者偏差约 300~500 米，必须转换。
class GeoConvert {
  GeoConvert._();

  static const double _pi = 3.1415926535897932384626;
  static const double _a = 6378245.0; // 长半轴
  static const double _ee = 0.00669342162296594323; // 偏心率平方

  /// 坐标基准：0 WGS84 / 1 GCJ02 / 2 BD09
  static const int wgs84 = 0;
  static const int gcj02 = 1;
  static const int bd09 = 2;

  /// WGS-84 -> GCJ-02，返回 [lat, lon]。中国境外不做偏移。
  static List<double> wgs84ToGcj02(double lat, double lon) {
    if (_outOfChina(lat, lon)) return [lat, lon];
    var dLat = _transformLat(lon - 105.0, lat - 35.0);
    var dLon = _transformLon(lon - 105.0, lat - 35.0);
    final radLat = lat / 180.0 * _pi;
    var magic = math.sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = math.sqrt(magic);
    dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * _pi);
    dLon = (dLon * 180.0) / (_a / sqrtMagic * math.cos(radLat) * _pi);
    return [lat + dLat, lon + dLon];
  }

  /// GCJ-02 -> WGS-84（迭代反算，误差 < 1e-6 度，约厘米级）。
  static List<double> gcj02ToWgs84(double lat, double lon) {
    if (_outOfChina(lat, lon)) return [lat, lon];
    var wLat = lat, wLon = lon;
    for (var i = 0; i < 10; i++) {
      final g = wgs84ToGcj02(wLat, wLon);
      final dLat = g[0] - lat;
      final dLon = g[1] - lon;
      if (dLat.abs() < 1e-7 && dLon.abs() < 1e-7) break;
      wLat -= dLat;
      wLon -= dLon;
    }
    return [wLat, wLon];
  }

  /// GCJ-02 -> BD-09。
  static List<double> gcj02ToBd09(double lat, double lon) {
    final x = lon, y = lat;
    final z = math.sqrt(x * x + y * y) + 0.00002 * math.sin(y * _pi);
    final theta = math.atan2(y, x) + 0.000003 * math.cos(x * _pi);
    return [z * math.sin(theta) + 0.006, z * math.cos(theta) + 0.0065];
  }

  /// BD-09 -> GCJ-02。
  static List<double> bd09ToGcj02(double lat, double lon) {
    final x = lon - 0.0065, y = lat - 0.006;
    final z = math.sqrt(x * x + y * y) - 0.00002 * math.sin(y * _pi);
    final theta = math.atan2(y, x) - 0.000003 * math.cos(x * _pi);
    return [z * math.sin(theta), z * math.cos(theta)];
  }

  /// WGS-84 -> BD-09。
  static List<double> wgs84ToBd09(double lat, double lon) {
    final g = wgs84ToGcj02(lat, lon);
    return gcj02ToBd09(g[0], g[1]);
  }

  /// BD-09 -> WGS-84。
  static List<double> bd09ToWgs84(double lat, double lon) {
    final g = bd09ToGcj02(lat, lon);
    return gcj02ToWgs84(g[0], g[1]);
  }

  // ---- 通用入口 ----

  /// WGS-84 -> 指定基准（用于地图显示）。
  static List<double> wgs84To(double lat, double lon, int datum) {
    switch (datum) {
      case gcj02:
        return wgs84ToGcj02(lat, lon);
      case bd09:
        return wgs84ToBd09(lat, lon);
      default:
        return [lat, lon];
    }
  }

  /// 指定基准 -> WGS-84（地图点击反算存储）。
  static List<double> toWgs84(double lat, double lon, int datum) {
    switch (datum) {
      case gcj02:
        return gcj02ToWgs84(lat, lon);
      case bd09:
        return bd09ToWgs84(lat, lon);
      default:
        return [lat, lon];
    }
  }

  static String datumName(int datum) {
    switch (datum) {
      case gcj02:
        return 'GCJ-02';
      case bd09:
        return 'BD-09';
      default:
        return 'WGS-84';
    }
  }

  static bool _outOfChina(double lat, double lon) =>
      lon < 72.004 || lon > 137.8347 || lat < 0.8293 || lat > 55.8271;

  static double _transformLat(double x, double y) {
    var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * _pi) + 20.0 * math.sin(2.0 * x * _pi)) *
        2.0 / 3.0;
    ret +=
        (20.0 * math.sin(y * _pi) + 40.0 * math.sin(y / 3.0 * _pi)) * 2.0 / 3.0;
    ret += (160.0 * math.sin(y / 12.0 * _pi) +
            320 * math.sin(y * _pi / 30.0)) *
        2.0 / 3.0;
    return ret;
  }

  static double _transformLon(double x, double y) {
    var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y +
        0.1 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * _pi) + 20.0 * math.sin(2.0 * x * _pi)) *
        2.0 / 3.0;
    ret +=
        (20.0 * math.sin(x * _pi) + 40.0 * math.sin(x / 3.0 * _pi)) * 2.0 / 3.0;
    ret += (150.0 * math.sin(x / 12.0 * _pi) +
            300.0 * math.sin(x / 30.0 * _pi)) *
        2.0 / 3.0;
    return ret;
  }
}
