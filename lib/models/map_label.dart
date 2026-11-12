import 'dart:math';

import 'label_type.dart';

/// 地图上的一句话标签（通信基础设施点）。一律以 WGS-84 存储。
class MapLabel {
  String id;
  String typeId;
  int seq;
  double lat;
  double lon;
  String note;

  /// 用户自定义标签名称，空值时回退到类型名称。
  String name;

  /// 本点到上一个点的人工确认距离，单位米；null 表示使用计算值。
  double? distanceM;

  /// 本段自定义标注文字（如"埋42.5""架38"）；非空时地图与导出优先显示。
  String distLabel;

  /// 轨迹绘制组编号；相邻点组不同则不连线。
  String lineGroupId;

  /// 收藏项目自定义线颜色（0=默认），仅显示用，不落盘。
  int styleColor;

  /// 收藏项目自定义线宽（逻辑像素，0=默认），仅显示用。
  double styleWidth;

  /// 区域（闭合多边形）标记，仅显示用。
  bool closedArea;

  /// 本段敷设方式：0=默认，1=架空，2=埋地，3=管道（决定连线颜色）。
  int segKind;

  /// 本段光缆接头预留盘留长度（米，0=未填）；竣工结算光缆用量 = 丈量长 + 盘留。
  double slackM;

  /// 本段光缆型号规格（如 "48芯GYTS"）；非空时路由图沿线标注并计入材料统计。
  String segCable;

  /// 人孔/手井总孔数（0=未设）。
  int holes;

  /// 人孔/手井已占用孔数（0=未设）。
  int usedHoles;

  /// 光分路器分光比（如 "1:8"），拓扑图用。
  String splitterRatio;

  /// 拓扑图手工指定的上级节点 id（空=按 ODN 层级自动推断）。
  String topoParentId;

  /// 本节点上级连接光缆规格（如 "架空48芯GYTS-01"），拓扑图边标注。
  String cableSpec;

  /// 上级连接光缆芯数（0=未填），芯线占用表校验用。
  int cableCores;

  /// 现场取证照片（相对文件名列表，存于应用文档目录 photos/ 下）。
  /// 竣工结算常用：杆位/箱体/隐患点拍照挂接，随点导出可溯源。
  List<String> photoPaths;

  MapLabel({
    String? id,
    this.typeId = 'pipe',
    this.seq = 1,
    this.lat = 0,
    this.lon = 0,
    this.note = '',
    this.name = '',
    this.distanceM,
    this.distLabel = '',
    this.lineGroupId = '',
    this.styleColor = 0,
    this.styleWidth = 0,
    this.closedArea = false,
    this.segKind = 0,
    this.slackM = 0,
    this.segCable = '',
    this.holes = 0,
    this.usedHoles = 0,
    this.splitterRatio = '',
    this.topoParentId = '',
    this.cableSpec = '',
    this.cableCores = 0,
    List<String>? photoPaths,
  })  : id = id ?? _uuid(),
        photoPaths = photoPaths ?? [];

  LabelType get type => LabelType.fromId(typeId);

  static String _uuid() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final h = bytes.map(hex).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  MapLabel clone() => MapLabel(
        id: id,
        typeId: typeId,
        seq: seq,
        lat: lat,
        lon: lon,
        note: note,
        name: name,
        distanceM: distanceM,
        distLabel: distLabel,
        lineGroupId: lineGroupId,
        styleColor: styleColor,
        styleWidth: styleWidth,
        closedArea: closedArea,
        segKind: segKind,
        slackM: slackM,
        segCable: segCable,
        holes: holes,
        usedHoles: usedHoles,
        splitterRatio: splitterRatio,
        topoParentId: topoParentId,
        cableSpec: cableSpec,
        cableCores: cableCores,
        photoPaths: List<String>.from(photoPaths),
      );

  // ---- JSON（与旧版 Java 数据格式完全兼容） ----

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'typeId': typeId,
      'seq': seq,
      'lat': lat,
      'lon': lon,
      'note': note,
      'name': name,
      'lineGroupId': lineGroupId,
      'distLabel': distLabel,
      'segKind': segKind,
      'segCable': segCable,
      'holes': holes,
      'usedHoles': usedHoles,
      'splitterRatio': splitterRatio,
      'topoParentId': topoParentId,
      'cableSpec': cableSpec,
      'cableCores': cableCores,
    };
    if (distanceM != null) m['distanceM'] = distanceM;
    if (slackM > 0) m['slackM'] = slackM;
    if (photoPaths.isNotEmpty) m['photoPaths'] = photoPaths;
    return m;
  }

  factory MapLabel.fromJson(Map<String, dynamic> jo) {
    return MapLabel(
      id: jo['id'] as String?,
      typeId: (jo['typeId'] as String?) ?? 'pipe',
      seq: (jo['seq'] as num?)?.toInt() ?? 1,
      lat: (jo['lat'] as num?)?.toDouble() ?? 0,
      lon: (jo['lon'] as num?)?.toDouble() ?? 0,
      note: (jo['note'] as String?) ?? '',
      name: (jo['name'] as String?) ?? '',
      lineGroupId: (jo['lineGroupId'] as String?) ?? '',
      distLabel: (jo['distLabel'] as String?) ?? '',
      segKind: (jo['segKind'] as num?)?.toInt() ?? 0,
      slackM: (jo['slackM'] as num?)?.toDouble() ?? 0,
      segCable: (jo['segCable'] as String?) ?? '',
      holes: (jo['holes'] as num?)?.toInt() ?? 0,
      usedHoles: (jo['usedHoles'] as num?)?.toInt() ?? 0,
      splitterRatio: (jo['splitterRatio'] as String?) ?? '',
      topoParentId: (jo['topoParentId'] as String?) ?? '',
      cableSpec: (jo['cableSpec'] as String?) ?? '',
      cableCores: (jo['cableCores'] as num?)?.toInt() ?? 0,
      distanceM: jo.containsKey('distanceM')
          ? (jo['distanceM'] as num?)?.toDouble()
          : null,
      photoPaths: (jo['photoPaths'] as List?)
          ?.map((e) => e.toString())
          .toList(),
    );
  }
}

/// 该点是否参与连线（非文字、非独立个体；'none' 作为隐形连接点参与）。
bool isLineMember(MapLabel l) =>
    l.typeId != 'text' && !l.type.isStandalone;

/// 把点集按线组拆成连线链——地图连线与全部导出（DXF/KML/CSV）的统一口径。
///
/// 规则：
/// · 只有带 lineGroupId 的连线参与点成链；
/// · 独立个体（箱体/引上/文字）天然不带线组、不打断链——链上相邻点直接相连，
///   与地图连线行为一致（旧导出用"相邻两点同组"判定，箱体插两杆之间会把
///   杆路剪断，现已统一修复）；
/// · 不同线组各自成链，按首次出现顺序输出。
List<List<MapLabel>> buildLabelChains(List<MapLabel> labels) {
  final chains = <String, List<MapLabel>>{};
  final order = <String>[];
  for (final l in labels) {
    final g = l.lineGroupId;
    if (g.isEmpty || !isLineMember(l)) continue;
    if (!chains.containsKey(g)) {
      chains[g] = <MapLabel>[];
      order.add(g);
    }
    chains[g]!.add(l);
  }
  return [for (final g in order) chains[g]!];
}
