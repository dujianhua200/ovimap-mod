import 'package:ovimap/geo/geo_util.dart';
import 'package:ovimap/models/map_label.dart';

/// 段落单一真源：在 [buildLabelChains] 之上再包一层"段视图"。
///
/// 为什么要这层：此前段距在地图连线、DXF 导出、属性面板各算一遍，同一段可能
/// 显示不同数字——这是出图事故的源头。这里把"段"收敛成唯一对象，所有功能都
/// 读 [RouteSegment]，不再各自计算。
///
/// 关键不变量（务必守住，否则又会出现口径漂移）：
/// · 段总数恒等于 Σ(每条链长度-1)，即 [buildLabelChains] 的段口径；本类**绝不**
///   自己重新分组，只调 [buildLabelChains]，复用同一个真源；
/// · 段距 [lengthM] 口径（to.distanceM 优先 / 否则两点 haversine）与地图连线完全一致；
/// · 显示文字 [text] 一律走 [GeoUtil.segLabelFor]，**不在此处二次拼前缀**——
///   前缀口径已在 segLabelFor 收敛，重拼一遍就会让上轮统一成果失效。
class RouteSegment {
  /// 第几条链（同 [buildLabelChains] 的返回顺序，0-based）。
  final int chainIndex;

  /// 本链内 1-based 段号：第 1 段 = 链首点 → 第 2 点。
  final int segIndex;

  /// 段起点（链上前一杆）。
  final MapLabel from;

  /// 段终点（链上后一杆；本段的敷设方式/盘留/型号都挂在终点上）。
  final MapLabel to;

  /// 段距（米）：to.distanceM 优先（用户手填确认值），否则 haversine(from,to)。
  final double lengthM;

  /// 是否使用了人工确认距离（to.distanceM != null）。
  final bool manualLength;

  /// 敷设方式：to.segKind（0默认/1架空/2埋地/3管道）。
  final int kind;

  /// 接头预留盘留长度（米）：to.slackM。
  final double slackM;

  /// 光缆型号：to.segCable。
  final String cable;

  /// 显示文字：实时推导，恒等于
  /// GeoUtil.segTextFor(to, GeoUtil.segDistText(lengthM), prefix)——
  /// 即"手填段标注优先，否则 敷设方式前缀(从 segKind 实时算)+段距(去.0毛刺)"。
  final String text;

  /// 本段所属线组编号：to.lineGroupId。
  final String groupId;

  const RouteSegment({
    required this.chainIndex,
    required this.segIndex,
    required this.from,
    required this.to,
    required this.lengthM,
    required this.manualLength,
    required this.kind,
    required this.slackM,
    required this.cable,
    required this.text,
    required this.groupId,
  });

  /// 敷设方式中文名（0 / 未知 → '默认'）。UI 与外部统计复用，避免再散落映射表。
  static String kindName(int k) {
    switch (k) {
      case 1:
        return '架空';
      case 2:
        return '埋地';
      case 3:
        return '管道';
      default:
        return '默认';
    }
  }

  /// 敷设方式 → 段标前缀：仅 1/2/3 有映射；0 不在表内（表示"回退到全局段标前缀"）。
  static const Map<int, String> kindPrefix = {
    1: '架',
    2: '埋',
    3: '管',
  };

  /// 本段敷设方式前缀（实时从 [kind] 推导，UI 的 chip 用）。默认方式(0) → null。
  String? get autoPrefix => GeoUtil.kindPrefixOf(kind);

  /// 由点集构建全部段。内部必须走 [buildLabelChains]，不得自己分组。
  ///
  /// [prefix] 透传给 [GeoUtil.segLabelFor] 作为段标注前缀（与地图渲染/导出一致）。
  /// 单点链（长度 1）产出 0 段，不报错。
  static List<RouteSegment> build(List<MapLabel> labels, {String prefix = ''}) {
    final chains = buildLabelChains(labels);
    final out = <RouteSegment>[];
    for (var ci = 0; ci < chains.length; ci++) {
      final chain = chains[ci];
      // 段号从 1 开始：si=1 对应 链首点→第2点。
      for (var si = 1; si < chain.length; si++) {
        final from = chain[si - 1];
        final to = chain[si];
        // 段距口径：to.distanceM 优先（用户现场确认值），否则两点大圆距离。
        final lengthM =
            to.distanceM ?? GeoUtil.haversine(from.lat, from.lon, to.lat, to.lon);
        out.add(RouteSegment(
          chainIndex: ci,
          segIndex: si,
          from: from,
          to: to,
          lengthM: lengthM,
          manualLength: to.distanceM != null,
          kind: to.segKind,
          slackM: to.slackM,
          cable: to.segCable,
          // 显示口径唯一收敛在 segTextFor：前缀实时从 segKind 推导，距离去 .0 毛刺，
          // 绝不把"前缀+距离"写死进 distLabel（挪点后段标自动跟随）。
          text:
              GeoUtil.segTextFor(to, GeoUtil.segDistText(lengthM), prefix: prefix),
          groupId: to.lineGroupId,
        ));
      }
    }
    return out;
  }

  /// 值相等（便于测试断言）；from/to 用 identical 比较（同一真源点对象）。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RouteSegment &&
          chainIndex == other.chainIndex &&
          segIndex == other.segIndex &&
          lengthM == other.lengthM &&
          manualLength == other.manualLength &&
          kind == other.kind &&
          slackM == other.slackM &&
          cable == other.cable &&
          text == other.text &&
          groupId == other.groupId &&
          identical(from, other.from) &&
          identical(to, other.to);

  @override
  int get hashCode => Object.hash(
        chainIndex,
        segIndex,
        lengthM,
        manualLength,
        kind,
        slackM,
        cable,
        text,
        groupId,
        from,
        to,
      );
}
