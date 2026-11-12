import 'dart:math' as math;

import '../models/map_label.dart';

/// 几何与格式化工具：距离/面积/比例尺/坐标格式化。
class GeoUtil {
  GeoUtil._();

  static const int tile = 256;
  static const double earthR = 6371000.0;

  /// 坐标格式：0=十进制度 1=度分秒 2=度.分
  static const int fmtDec = 0;
  static const int fmtDms = 1;
  static const int fmtDm = 2;

  /// 大圆距离（米）。
  static double haversine(double la1, double lo1, double la2, double lo2) {
    final dLat = _rad(la2 - la1);
    final dLon = _rad(lo2 - lo1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(la1)) * math.cos(_rad(la2)) *
            math.sin(dLon / 2) * math.sin(dLon / 2);
    return earthR * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// 球面多边形面积（平方米，取绝对值）。
  static double polygonArea(List<double> lats, List<double> lons, int count) {
    if (count < 3) return 0;
    var total = 0.0;
    for (var i = 0; i < count; i++) {
      final j = (i + 1) % count;
      final lon1 = _rad(lons[i]);
      final lon2 = _rad(lons[j]);
      final lat1 = _rad(lats[i]);
      final lat2 = _rad(lats[j]);
      total += (lon2 - lon1) * (2 + math.sin(lat1) + math.sin(lat2));
    }
    return (total * earthR * earthR / 2.0).abs();
  }

  /// 某纬度处每像素对应的地面距离（米），z 为连续浮点级别。
  static double metersPerPixel(double lat, double z) {
    return 2 * math.pi * earthR * math.cos(_rad(lat)) /
        (tile * math.pow(2, z));
  }

  /// 把米数格式化为 <1km 显示 m，否则 km 保留两位。
  static String fmtDist(double m) {
    if (m.isNaN) return '-';
    if (m < 1000) return '${m.toStringAsFixed(0)}米';
    return '${(m / 1000).toStringAsFixed(2)}公里';
  }

  /// 线段上的距离标签：米保留一位小数；>999 显示公里两位。
  static String fmtSegLen(double m) {
    if (m < 1000) return m.toStringAsFixed(1);
    return '${(m / 1000).toStringAsFixed(2)}km';
  }

  /// 敷设方式 → 段标前缀（架空→架 / 埋地→埋 / 管道→管）；0 或其他 → null。
  ///
  /// 词表与 UI 的 segPrefixChips 保持一致。前缀**不落地成字符串**，始终从
  /// [MapLabel.segKind] 实时推导——这正是修掉"把前缀写死进 distLabel、挪点后图上
  /// 焊死旧数字"出图事故的关键：距离变了，段标自动跟着变。
  static String? kindPrefixOf(int kind) =>
      const {1: '架', 2: '埋', 3: '管'}[kind];

  /// 段标注显示口径（地图 / 导出唯一真源，旧名 [segLabelFor] 的同义委托）。
  ///
  /// 旧出口用 [segLabelFor]（[autoKindPrefix]=false，只看全局 [prefix]）行为完全不变；
  /// 新出口请用 [segTextFor]，让敷设方式前缀从 [MapLabel.segKind] 实时带出。
  ///
  /// 注意：渲染/导出一律走这里，不要把"前缀 + 距离"写死进 [MapLabel.distLabel]
  /// （距离是动态的，落点写死会随段长变化而失真；要的是"设一次前缀、所有段自动带"）。
  static String segLabelFor(MapLabel b, String autoDistText,
      {String prefix = ''}) {
    return segTextFor(b, autoDistText, prefix: prefix, autoKindPrefix: false);
  }

  /// 段标最终文字（**新的唯一真源**）。
  ///
  /// 优先级：
  /// 1. [b.distLabel] 非空 → 原样返回（用户手写，优先级最高）；
  /// 2. 自动前缀：[autoKindPrefix] 为真且该段有敷设方式 → 用 [kindPrefixOf]；
  ///    否则用全局 [prefix]；
  /// 3. 拼 [autoDistText]；两者都空则只返回距离。
  ///
  /// 前缀始终从 [MapLabel.segKind] 实时推导，不写进 distLabel——
  /// 距离变了段标自动跟着变，杜绝"图上焊死旧数字"的出图事故。
  ///
  /// 实现全权交给 [segTextPreview]（同一份规则，避免出现第二种拼法）。
  static String segTextFor(MapLabel b, String autoDistText,
          {String prefix = '', bool autoKindPrefix = true}) =>
      segTextPreview(b.distLabel, autoKindPrefix ? b.segKind : 0, autoDistText,
          prefix: prefix);

  /// 段标注**未落盘**时的预览文字：把"输入框里正打着的字 + 刚点的敷设方式"喂进来，
  /// 就能算出图上将显示什么。
  ///
  /// 存在的理由：属性面板的「本段标注」输入框、敷设方式 chip 都是**编辑态**，
  /// 此刻 `MapLabel` 上还是旧值。若预览另写一套拼法，就会出现"预览写 埋42、出图写 架42"
  /// 这种最伤人的不一致。规则只此一处。
  static String segTextPreview(String typedLabel, int segKind, String autoDistText,
      {String prefix = ''}) {
    final t = typedLabel.trim();
    if (t.isNotEmpty) return t;
    final kp = kindPrefixOf(segKind) ?? '';
    final eff = kp.isNotEmpty ? kp : prefix;
    return eff.isEmpty ? autoDistText : '$eff$autoDistText';
  }

  /// 去掉整数后的小数尾巴：`"42.0"` → `"42"`，`"42.5"` 原样，`"1.23km"` 原样。
  ///
  /// 抽成独立方法是为了让**所有**距离文字出口共用同一条规则 —— 原先地图段标、
  /// DXF 标注、UI 编辑框各自处理这个毛刺（有的去、有的不去），于是同一段路在
  /// 屏幕上写 42、在图上写 42.0，出图对不上账。规则收敛到这一处。
  static String stripDotZero(String s) =>
      s.endsWith('.0') ? s.substring(0, s.length - 2) : s;

  /// 段标注距离文字：**一律用米**，整数去掉 ".0" 毛刺。
  ///
  /// `42.0 → "42"`、`42.5 → "42.5"`、`1050.0 → "1050"`、`1050.5 → "1050.5"`。
  ///
  /// ## 为什么段标不用 [fmtSegLen] 的 "km"
  /// 段标是屏上与图纸**共用**的一个数字（screen 段标、DXF 标注、左侧段落表、编辑框
  /// 自动补距都是它）。[fmtSegLen] 超过 1km 会切成 "1.05km"，而 DXF 的标注图层单位
  /// 就是米——于是同一条长杆档在屏幕上写「埋1.05km」、在图上写「埋1050」，审图时
  /// 对不上账。通信线路的档距/段距行业口径本来就是米，段标统一用米既合规又不分叉。
  ///
  /// 需要"米 + 公里"混合单位的**概览文字**（如"总长 1.23 公里"）请用 [fmtSegLen]/
  /// [fmtDist]，不要拿本方法当通用距离格式化用。
  static String segDistText(double m) =>
      m.isFinite ? stripDotZero(m.toStringAsFixed(1)) : '-';

  /// 段长（**标注优先**口径）：先解析 [b.distLabel] 里的数字，其次 [MapLabel.distanceM]，
  /// 最后回退到 [haversine] 计算值。
  ///
  /// ## 为什么"标注优先"
  /// 图上写的数字就是审图与结算读到的数字。标注、里程表、材料表必须引用同一个数，
  /// 否则同一个段落在屏幕上是 42、在 CSV 里是 43，审图时对不上账。
  ///
  /// ## 与 [RouteSegment.lengthM] 的分工（别互相替换）
  /// - `RouteSegment.lengthM` 是**几何段长**：只看 `distanceM` 与坐标。标注只是"图上写
  ///   什么"，不该反过来推动几何与桩号（否则用户在标注里手写一句备注就能挪动里程桩）。
  /// - 本函数是**结算/里程口径**：标注文字优先。
  /// 两者服务不同用途，各有其位。
  ///
  /// ## 为什么要有这个方法
  /// 原先 `dxf.dart` / `csv.dart` / `archive_book.dart` 各有一份**逐字相同**的私有实现。
  /// 三份拷贝各自演化，任何一处被改动都会让同一段路在不同导出里得出不同数字。此处
  /// 收敛为唯一实现，那三处一律委托过来。
  static double segLenLabelFirst(MapLabel a, MapLabel b) {
    final t = b.distLabel.trim();
    if (t.isNotEmpty) {
      final m = RegExp(r'[\d.]+').firstMatch(t);
      final v = m == null ? null : double.tryParse(m.group(0) ?? '');
      if (v != null && v > 0) return v;
    }
    final dm = b.distanceM;
    if (dm != null && dm > 0) return dm;
    return haversine(a.lat, a.lon, b.lat, b.lon);
  }

  /// 面积显示：平方米/公顷/平方公里自动切换，附亩。
  static String fmtArea(double sqm) {
    final sb = StringBuffer();
    if (sqm < 10000) {
      sb.write('${sqm.toStringAsFixed(0)} ㎡');
    } else if (sqm < 1000000) {
      sb.write('${(sqm / 10000).toStringAsFixed(2)} 公顷');
    } else {
      sb.write('${(sqm / 1000000).toStringAsFixed(2)} 平方公里');
    }
    sb.write('（${(sqm / 666.6667).toStringAsFixed(2)}亩）');
    return sb.toString();
  }

  static String fmtScaleLabel(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(0)} km';
    return '${meters.toStringAsFixed(0)} m';
  }

  /// 坐标格式化。
  static String formatCoord(double lat, double lon, int fmt) =>
      '${formatLat(lat, fmt)}, ${formatLon(lon, fmt)}';

  static String formatLat(double lat, int fmt) =>
      '${lat >= 0 ? 'N' : 'S'} ${_formatAngle(lat.abs(), fmt)}';

  static String formatLon(double lon, int fmt) =>
      '${lon >= 0 ? 'E' : 'W'} ${_formatAngle(lon.abs(), fmt)}';

  static String _formatAngle(double deg, int fmt) {
    if (fmt == fmtDec) return '${deg.toStringAsFixed(6)}°';
    final d = deg.floor();
    final rem = (deg - d) * 60;
    if (fmt == fmtDm) return "$d°${rem.toStringAsFixed(6)}′";
    final m = rem.floor();
    final s = (rem - m) * 60;
    return "$d°$m′${s.toStringAsFixed(2)}″";
  }

  static String fmtName(int fmt) {
    switch (fmt) {
      case fmtDms:
        return '度分秒';
      case fmtDm:
        return '度.分';
      default:
        return '十进制';
    }
  }

  /// 解析用户输入的坐标：
  /// · 十进制："114.08,32.13" / "32.13 114.08" / "32.13°,114.08°"
  /// · 度分秒："32°07'48"N 114°05'24"E"（°/度、′/分、″/秒 混排均可）
  /// 返回 [lat, lon]，解析失败返回 null。
  static List<double>? parseCoordInput(String? text) {
    if (text == null) return null;
    var s = text.trim()
        .replaceAll('，', ',')
        .replaceAll('、', ',')
        .replaceAll(';', ',')
        .replaceAll('；', ',');
    if (s.isEmpty) return null;

    // 度分秒：输入里带 ° 且能抽出两组"度分秒"
    if (s.contains('°') || s.contains('度')) {
      final dms = parseDmsInput(s);
      if (dms != null) return dms;
    }

    List<String> parts;
    if (s.contains(',')) {
      parts = s.split(RegExp(r'\s*,\s*'));
    } else {
      parts = s.split(RegExp(r'\s+'));
    }
    if (parts.length != 2) return null;
    final a = double.tryParse(parts[0].replaceAll('°', ''));
    final b = double.tryParse(parts[1].replaceAll('°', ''));
    if (a == null || b == null) return null;
    var lat = a, lon = b;
    if (lat.abs() > 90 && lon.abs() <= 90) {
      final t = lat;
      lat = lon;
      lon = t;
    }
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    return [lat, lon];
  }

  /// 度分秒解析："32°07'48"N 114°05'24"E"。
  /// 半球字母（N/S/E/W）优先判定经纬；无字母时按"先纬后经"惯例。
  static List<double>? parseDmsInput(String s) {
    final re = RegExp(
        r'''([NSEW])?\s*(\d{1,3})(?:[°度]\s*(\d{1,2}(?:\.\d+)?)[′分']?\s*(?:(\d{1,2}(?:\.\d+)?)[″秒"]?)?)?\s*([NSEW])?''',
        caseSensitive: false);
    final ms = re.allMatches(s).where((m) => m.group(2) != null).toList();
    if (ms.length != 2) return null;
    double val(Match m) {
      final d = double.parse(m.group(2)!);
      final mi = double.tryParse(m.group(3) ?? '') ?? 0;
      final sec = double.tryParse(m.group(4) ?? '') ?? 0;
      return d + mi / 60 + sec / 3600;
    }

    String? hemi(Match m) =>
        (m.group(1) ?? m.group(5))?.toUpperCase();
    final v1 = val(ms[0]), v2 = val(ms[1]);
    final h1 = hemi(ms[0]), h2 = hemi(ms[1]);
    var lat = v1, lon = v2;
    if (h1 == 'E' || h1 == 'W' || h2 == 'N' || h2 == 'S') {
      lon = v1;
      lat = v2;
    }
    if (h1 == 'S' || h2 == 'S') lat = -lat;
    if (h1 == 'W' || h2 == 'W') lon = -lon;
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    return [lat, lon];
  }

  /// 米/秒 -> 公里/时。
  static String fmtSpeed(double mps) =>
      '${(mps * 3.6).toStringAsFixed(1)} km/h';

  static double _rad(double deg) => deg * math.pi / 180.0;
}
