import 'dart:math' as math;

/// GCJ-02（火星坐标，国测局加密）↔ WGS-84（GPS 原始坐标）转换。
///
/// 背景（第十九批实测结论）：天地图 v2/search 的 POI 检索数据实际是 GCJ-02
/// 火星坐标（信阳地区偏移约 300~600 米），与天地图 CGCS2000 ≈ WGS-84 的
/// 瓦片不同系——这就是"地名跑到矢量图外"的根因。
///
/// GCJ-02 加密不可逆，本实现采用标准近似逆变换（初始猜测 + 迭代回减），
/// 精度 1~2 米内，满足地名落图需求。
class Gcj02Converter {
  Gcj02Converter._();

  /// 克拉索夫斯基椭球长半轴（GCJ-02 标准算法参数）。
  static const double _a = 6378245.0;

  /// 第一偏心率平方（GCJ-02 标准算法参数）。
  static const double _ee = 0.00669342162296594323;

  /// 判断是否在中国境外（境外不做 GCJ 偏移，原样返回）。
  ///
  /// 采用 GCJ-02 算法惯用的粗略矩形判定（含海域），与业界实现一致。
  static bool outOfChina(double lat, double lon) {
    return lon < 72.004 || lon > 137.8347 || lat < 0.8293 || lat > 55.8271;
  }

  /// 纬度偏移多项式（GCJ-02 标准算法公开实现）。
  static double _transformLat(double x, double y) {
    var ret = -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) *
        2.0 /
        3.0;
    ret += (20.0 * math.sin(y * math.pi) +
            40.0 * math.sin(y / 3.0 * math.pi)) *
        2.0 /
        3.0;
    ret += (160.0 * math.sin(y / 12.0 * math.pi) +
            320.0 * math.sin(y * math.pi / 30.0)) *
        2.0 /
        3.0;
    return ret;
  }

  /// 经度偏移多项式（GCJ-02 标准算法公开实现）。
  static double _transformLon(double x, double y) {
    var ret = 300.0 +
        x +
        2.0 * y +
        0.1 * x * x +
        0.1 * x * y +
        0.1 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) *
        2.0 /
        3.0;
    ret += (20.0 * math.sin(x * math.pi) +
            40.0 * math.sin(x / 3.0 * math.pi)) *
        2.0 /
        3.0;
    ret += (150.0 * math.sin(x / 12.0 * math.pi) +
            300.0 * math.sin(x / 30.0 * math.pi)) *
        2.0 /
        3.0;
    return ret;
  }

  /// WGS-84 → GCJ-02（正向加密）。
  /// 返回 `[lat, lon]`；中国境外原样返回。
  static List<double> wgs84ToGcj02(double lat, double lon) {
    if (outOfChina(lat, lon)) return [lat, lon];
    var dLat = _transformLat(lon - 105.0, lat - 35.0);
    var dLon = _transformLon(lon - 105.0, lat - 35.0);
    final radLat = lat / 180.0 * math.pi;
    var magic = math.sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = math.sqrt(magic);
    dLat = (dLat * 180.0) /
        ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
    dLon = (dLon * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
    return [lat + dLat, lon + dLon];
  }

  /// GCJ-02 → WGS-84（近似逆变换，精度 1~2 米内）。
  ///
  /// 标准做法：以输入坐标为初始猜测，迭代"正向加密回减偏差"收敛。
  /// 返回 `[lat, lon]`；中国境外原样返回。
  static List<double> gcj02ToWgs84(double lat, double lon) {
    if (outOfChina(lat, lon)) return [lat, lon];
    var wLat = lat, wLon = lon;
    for (var i = 0; i < 2; i++) {
      final gcj = wgs84ToGcj02(wLat, wLon);
      wLat += lat - gcj[0];
      wLon += lon - gcj[1];
    }
    return [wLat, wLon];
  }
}
