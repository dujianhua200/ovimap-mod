// 设计 ↔ 竣工变更对照的数据结构（纯数据，可单测）。
//
// 由 `CsvExporter.buildDesignDiff` 生成，`exportDesignDiff` 负责序列化；
// UI 层 `showDesignDiffDialog` 消费本结构渲染可读清单。

/// 单个杆位相对设计版的状态。
enum DiffStatus {
  /// 竣工有、设计无。
  added,

  /// 设计有、竣工无。
  removed,

  /// 双方都有，但位置偏移超过阈值。
  moved,

  /// 双方都有且偏移在阈值内（一致）。
  same,
}

/// 单个杆位对照项。[d*] 为设计坐标，[c*] 为竣工坐标（缺失侧为 null）。
class DiffPoleItem {
  final String key;
  final DiffStatus status;
  final double? dLat;
  final double? dLon;
  final double? cLat;
  final double? cLon;

  /// 位置偏移（米）；added/removed 为 0。
  final double offsetM;

  const DiffPoleItem({
    required this.key,
    required this.status,
    this.dLat,
    this.dLon,
    this.cLat,
    this.cLon,
    this.offsetM = 0,
  });
}

/// 同名相邻杆段距对照项。
class DiffSegItem {
  /// 段键：`设计起点名>设计终点名`（取名称，空名段不参与）。
  final String seg;
  final double designM;
  final double compM;
  final double deltaM;

  const DiffSegItem({
    required this.seg,
    required this.designM,
    required this.compM,
    required this.deltaM,
  });
}

/// 变更量汇总。
class DiffSummary {
  final int added;
  final int removed;
  final int moved;
  final int kept;

  /// 净长度差 = 竣工总段距 − 设计总段距（不含盘留）。
  final double netLenDiffM;

  const DiffSummary({
    required this.added,
    required this.removed,
    required this.moved,
    required this.kept,
    required this.netLenDiffM,
  });
}

/// 变更对照报告：全部杆位（含一致项）+ 段距对照 + 汇总 + 备注。
class DesignDiffReport {
  final List<DiffPoleItem> poles;
  final List<DiffSegItem> segs;
  final DiffSummary summary;

  /// 非致命提示，如"无同名相邻杆段可对比"。
  final List<String> notes;

  const DesignDiffReport({
    required this.poles,
    required this.segs,
    required this.summary,
    required this.notes,
  });

  /// 仅变更项（added/removed/moved），供"仅看变更项"过滤。
  List<DiffPoleItem> get changedPoles =>
      poles.where((p) => p.status != DiffStatus.same).toList();
}

/// 批量属性编辑指令：可空字段 = 不改。
///
/// · [segKind] null=不改；
/// · [segCable] ''=清空，null=不改；
/// · [slackM] null=不改；
/// · [namePrefix] 命名前缀，null=不改；配合 [renumber] 决定是否重编号；
/// · [distLabelPrefix] 段标注（桩号）前缀，null=不改（保留原数字，仅换前缀）；
/// · [renumber] true=按前缀重编号 `前缀-n`（按选中顺序），false=仅换前缀保留原编号。
class BatchEdit {
  final int? segKind;
  final String? segCable;
  final double? slackM;
  final String? namePrefix;
  final String? distLabelPrefix;
  final bool renumber;

  const BatchEdit({
    this.segKind,
    this.segCable,
    this.slackM,
    this.namePrefix,
    this.distLabelPrefix,
    this.renumber = false,
  });

  bool get isEmpty =>
      segKind == null &&
      segCable == null &&
      slackM == null &&
      namePrefix == null &&
      distLabelPrefix == null;
}
