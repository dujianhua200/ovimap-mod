import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import 'platform_caps.dart';

/// 定位 + 电子罗盘服务：GPS 流 + 航向平滑。
///
/// 桌面端（[PlatformCaps.isDesktop]）无 GPS / 无罗盘：`ensureGranted()` 直接返回
/// false、`start()` 不订阅任何流。**不删任何方法**，移动端行为不变。
class LocService {
  LocService._();
  static final LocService instance = LocService._();

  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _cmpSub;

  Position? lastPos;
  double bearing = 0;
  bool hasBearing = false;
  bool _running = false;

  void Function(Position pos)? onPosition;
  void Function(double headingDeg)? onHeading;

  /// 确保定位权限，返回是否已授权。
  /// 桌面端无 GPS：直接返回 false（不触发任何系统定位调用）。
  Future<bool> ensureGranted() async {
    if (PlatformCaps.isDesktop) return false;
    var serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // 尝试请求开启（Android 会弹系统开关）
      serviceEnabled = await Geolocator.openLocationSettings();
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  bool get running => _running;

  void start() {
    // 桌面端无 GPS：不订阅位置流（也不订阅罗盘）。
    if (PlatformCaps.isDesktop) {
      _running = false;
      return;
    }
    if (_running) return;
    _running = true;
    const settings = LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
    );
    _posSub = Geolocator.getPositionStream(locationSettings: settings)
        .listen((pos) {
      lastPos = pos;
      onPosition?.call(pos);
    }, onError: (_) {});

    // flutter_compass 无 Windows 实现，桌面端订阅会抛 MissingPluginException，
    // 故按能力开关跳过（绝不订阅）。
    if (!PlatformCaps.hasCompass) return;
    final events = FlutterCompass.events;
    if (events != null) {
      _cmpSub = events.listen((e) {
        final h = e.heading;
        if (h == null) return;
        bearing = hasBearing ? _smoothBearing(bearing, h) : h;
        hasBearing = true;
        onHeading?.call(bearing);
      }, onError: (_) {});
    }
  }

  void stop() {
    _running = false;
    _posSub?.cancel();
    _posSub = null;
    _cmpSub?.cancel();
    _cmpSub = null;
  }

  Future<Position?> lastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  /// 圆周航向平滑（指数移动平均，跨 0/360 接缝安全）。
  /// 系数取 0.55：既压掉罗盘抖动，又能在转动机身时快速跟上（不滞后）。
  static double _smoothBearing(double oldB, double newB) {
    var d = (newB - oldB) % 360;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    final r = (oldB + d * 0.55) % 360;
    return r < 0 ? r + 360 : r;
  }

  static double distanceM(double la1, double lo1, double la2, double lo2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(la2 - la1);
    final dLon = rad(lo2 - lo1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(la1)) * math.cos(rad(la2)) *
            math.sin(dLon / 2) * math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}
