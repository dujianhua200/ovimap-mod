import 'package:ovimap/geo/geo_util.dart';
import 'package:ovimap/geo/route_segments.dart';
import 'package:ovimap/models/map_label.dart';

/// 出图前一键质检引擎：纯函数，不依赖 BuildContext / AppState / Flutter。
///
/// 设计原则：所有检查都基于 [RouteSegment]（唯一真源）与原始 [MapLabel] 列表，
/// 不在本文件里重算段距/分组；产生的问题按 [RouteIssue.code] 归类，UI 侧可据此
/// 分组展示。detail / fixHint 直接面向线路设计人员，带具体数字，可原样弹窗。

/// 问题等级。
enum IssueLevel {
  error,
  warn,
  info;

  /// 面向用户的中文名。
  String get label {
    switch (this) {
      case IssueLevel.error:
        return '错误';
      case IssueLevel.warn:
        return '警告';
      case IssueLevel.info:
        return '提示';
    }
  }
}

/// 一条质检问题。
class RouteIssue {
  final IssueLevel level;
  final String code;

  /// 短标题（如"段距过短"），UI 可当卡片标题。
  final String title;

  /// 人话详情，带具体数字，可直接给设计人员看。
  final String detail;

  /// 能定位到点的 id 列表：段类问题用 [from.id, to.id]，点类问题用 [label.id]。
  final List<String> labelIds;

  /// 处理建议（人话）。
  final String fixHint;

  const RouteIssue({
    required this.level,
    required this.code,
    required this.title,
    required this.detail,
    required this.labelIds,
    required this.fixHint,
  });
}

/// 质检选项（全部带合理默认，UI 可按工程类型调整）。
class RouteCheckOptions {
  /// 段距下限（米）；低于它视为漏点 / 误标。
  double minSegM;

  /// 段距上限（米）；架空档距经验值，超了需复核长杆档。
  double maxSegM;

  /// 是否要求填敷设方式（架空/埋地/管道）。
  bool requireKind;

  /// 是否要求填光缆型号。
  bool requireCable;

  /// 竣工模式：要求填盘留（接头预留）。
  bool completionMode;

  /// 段标注数字与实测距离允许的相对偏差（超过视为标注漂移）。
  double labelDriftRatio;

  RouteCheckOptions({
    this.minSegM = 5,
    this.maxSegM = 200,
    this.requireKind = true,
    this.requireCable = false,
    this.completionMode = false,
    this.labelDriftRatio = 0.05,
  });
}

/// 质检引擎。
class RouteChecker {
  /// 对 [segs]（段落真源）与 [labels]（原始点）做全量检查，返回按等级稳定排序的问题列表。
  ///
  /// 排序：error → warn → info；同级保持首次出现顺序（Dart 的 sort 稳定）。
  static List<RouteIssue> check(List<RouteSegment> segs, List<MapLabel> labels,
      {RouteCheckOptions? opt}) {
    final o = opt ?? RouteCheckOptions();
    final issues = <RouteIssue>[];

    // ============ 段级检查 ============
    for (final s in segs) {
      final from = s.from;
      final to = s.to;
      final segDesc = '第${s.segIndex}段（${_name(from)} → ${_name(to)}）';

      if (s.lengthM < o.minSegM) {
        issues.add(RouteIssue(
          level: IssueLevel.error,
          code: 'seg_too_short',
          title: '段距过短',
          detail: '$segDesc 段距 ${_m(s.lengthM)} 米，低于 ${_m(o.minSegM)} 米下限',
          fixHint: '确认是否漏点，或在属性面板修正"到上一点距离"',
          labelIds: [from.id, to.id],
        ));
      }

      if (s.lengthM > o.maxSegM) {
        issues.add(RouteIssue(
          level: IssueLevel.warn,
          code: 'seg_too_long',
          title: '段距过长',
          detail: '$segDesc 段距 ${_m(s.lengthM)} 米，高于 ${_m(o.maxSegM)} 米'
              '（架空档距经验上限）',
          fixHint: '复核是否长杆档 / 跨路 / 跨河，必要时补点',
          labelIds: [from.id, to.id],
        ));
      }

      if (o.requireKind && s.kind == 0) {
        issues.add(RouteIssue(
          level: IssueLevel.warn,
          code: 'seg_no_kind',
          title: '未填敷设方式',
          detail: '$segDesc 未填写敷设方式（架空/埋地/管道）',
          fixHint: '在属性面板选择敷设方式；导出 DXF 与统计将按方式着色',
          labelIds: [from.id, to.id],
        ));
      }

      if (o.requireCable && s.cable.trim().isEmpty) {
        issues.add(RouteIssue(
          level: IssueLevel.warn,
          code: 'seg_no_cable',
          title: '未填光缆型号',
          detail: '$segDesc 未填写光缆型号',
          fixHint: '在属性面板填写光缆型号（如 48芯GYTS），便于材料统计',
          labelIds: [from.id, to.id],
        ));
      }

      if (o.completionMode && s.slackM <= 0) {
        issues.add(RouteIssue(
          level: IssueLevel.warn,
          code: 'seg_slack_missing',
          title: '竣工未填盘留',
          detail: '$segDesc 竣工模式下未填写接头预留盘留长度（米）',
          fixHint: '填写本段盘留；竣工结算光缆用量 = 丈量长 + 盘留',
          labelIds: [from.id, to.id],
        ));
      }

      // 段标注漂移：distLabel 非空且能解析出数字，且与实测相对偏差超阈值才报；
      // 解析不出、或为 0/负/非有限（"."、".."、"0" 等无意义输入）直接跳过，不报错。
      if (to.distLabel.trim().isNotEmpty) {
        final parsed = _leadingNumber(to.distLabel);
        if (parsed != null &&
            parsed > 0 &&
            parsed.isFinite &&
            s.lengthM > 0) {
          final rel = (s.lengthM - parsed).abs() / s.lengthM;
          if (rel > o.labelDriftRatio) {
            issues.add(RouteIssue(
              level: IssueLevel.warn,
              code: 'seg_label_drift',
              title: '段标注与实测不符',
              detail: '$segDesc 段标注 ${_m(parsed)} 米，与实测 ${_m(s.lengthM)} 米'
                  '相对偏差 ${(rel * 100).toStringAsFixed(1)}%'
                  '（> ${(o.labelDriftRatio * 100).toStringAsFixed(0)}%）',
              fixHint: '确认段标注是否手误；如需修正请在属性面板改"段标注"',
              labelIds: [from.id, to.id],
            ));
          }
        }
      }
    }

    // ============ geo_jump：疑似打点错位 ============
    // 按链分组；链内只有 1 段时跳过（无法判断"相对于本链突兀"）。
    // 参照值用"排除自身后其余段的均值"：这样 3 段链也能判定（含自身的均值必然
    // 使 ">均值×3" 在数学上不可能），且不会被本段自身拉高均值而漏报。
    final byChain = <int, List<RouteSegment>>{};
    for (final s in segs) {
      byChain.putIfAbsent(s.chainIndex, () => []).add(s);
    }
    for (final group in byChain.values) {
      if (group.length <= 1) continue;
      final total = group.fold(0.0, (a, s) => a + s.lengthM);
      final n = group.length;
      for (final s in group) {
        // 参照值 = (总和 - 本段) / (段数 - 1)，即排除自身的其余段均值。
        final ref = (total - s.lengthM) / (n - 1);
        if (n >= 3 && s.lengthM > ref * 3 && s.lengthM > 50) {
          final segDesc = '第${s.segIndex}段（${_name(s.from)} → ${_name(s.to)}）';
          issues.add(RouteIssue(
            level: IssueLevel.warn,
            code: 'geo_jump',
            title: '疑似打点错位',
            detail: '$segDesc 段距 ${_m(s.lengthM)} 米，是链内其余段平均段长 ${_m(ref)} 米的'
                '${(s.lengthM / ref).toStringAsFixed(1)} 倍'
                '（>3 倍且 >50 米）',
            fixHint: '复核该点坐标是否误标，或确实需跨越大距离',
            labelIds: [s.from.id, s.to.id],
          ));
        }
      }
    }

    // ============ 点级检查 ============
    // 名称重复：同批内非空 name（trim 后）重复。
    final byName = <String, List<MapLabel>>{};
    for (final l in labels) {
      final n = l.name.trim();
      if (n.isEmpty) continue;
      byName.putIfAbsent(n, () => []).add(l);
    }
    for (final entry in byName.entries) {
      if (entry.value.length > 1) {
        issues.add(RouteIssue(
          level: IssueLevel.warn,
          code: 'label_dup_name',
          title: '名称重复',
          detail: '有 ${entry.value.length} 个点重名「${entry.key}」，出图易混淆',
          fixHint: '为各点设唯一名称；可在设置开启自动编号前缀',
          labelIds: entry.value.map((l) => l.id).toList(),
        ));
      }
    }

    // 未命名：seq>1 且 name 为空（链首点允许无名）。
    for (final l in labels) {
      if (l.name.trim().isEmpty && l.seq > 1) {
        issues.add(RouteIssue(
          level: IssueLevel.info,
          code: 'label_unnamed',
          title: '点未命名',
          detail: '第 ${l.seq} 点（seq=${l.seq}）未命名',
          fixHint: '在属性面板填写名称，或开启自动编号',
          labelIds: [l.id],
        ));
      }
    }

    // 链内序号不连续：相邻点 seq 差 ≠ 1（可能漏点）。
    for (final chain in buildLabelChains(labels)) {
      for (var i = 1; i < chain.length; i++) {
        final prev = chain[i - 1];
        final cur = chain[i];
        if (cur.seq - prev.seq != 1) {
          issues.add(RouteIssue(
            level: IssueLevel.info,
            code: 'label_seq_gap',
            title: '链内序号不连续',
            detail: '链内相邻点序号从 ${prev.seq} 跳到 ${cur.seq}'
                '（缺 ${prev.seq + 1}），可能漏点',
            fixHint: '检查是否漏打点；序号不连续不影响连线，但竣工资料需连续',
            labelIds: [prev.id, cur.id],
          ));
        }
      }
    }

    // 排序：error(0) → warn(1) → info(2)，稳定保持首次出现顺序。
    const rank = {IssueLevel.error: 0, IssueLevel.warn: 1, IssueLevel.info: 2};
    issues.sort((a, b) => rank[a.level]! - rank[b.level]!);
    return issues;
  }
}

/// 点的可读名：有 name 用 name，否则回退"第 N 点"。
String _name(MapLabel l) =>
    l.name.trim().isNotEmpty ? l.name.trim() : '第${l.seq}点';

/// 取字符串里第一段连续的 [0-9.] 子串并解析为 double；解析不出返回 null。
double? _leadingNumber(String s) {
  final m = RegExp(r'[0-9.]+').firstMatch(s);
  if (m == null) return null;
  return double.tryParse(m.group(0)!);
}

/// 距离文字：委托 [GeoUtil.segDistText]（米、整数不留 ".0"）。
///
/// 体检报告里的数字要和图上段标**字面一致**——用户看到"实测 42 米"，去图上找到的
/// 也应该是「埋42」，而不是「埋42.0」。曾经这里自己写 `toStringAsFixed(1)`。
String _m(double m) => GeoUtil.segDistText(m);
