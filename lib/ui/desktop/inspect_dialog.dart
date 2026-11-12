// ================= 出图体检（Drawing QA）=================
//
// 【为什么要有这个面板】
// 线路设计的交付物是图纸，图纸要拿去施工。出图前最贵的成本不是画图，而是**返工**：
// 漏了一基杆、某一档标了 3 米、两基杆重名、某段忘了填敷设方式——这些问题在图上肉眼
// 找要一档一档看，几十档的线路能看半小时，还容易漏。本面板把这件事变成一次点击：
// 打开即列出全部可疑项，按严重度排好，点一下就能跳到图上那一档。
//
// 【设计取舍】
// · **不自动改图**。除了「清除漂移段标」这一个明确无副作用的动作（它只是把手填的、
//   与几何不符的数字清掉，让段标回到实时生成），其余一律只报告不修改。出图是责任
//   行为，机器不该替设计人员决定"这档 3 米是不是漏点"。
// · **严重度分色**：错误(红) / 警告(橙) / 提示(灰)，与工程习惯一致，扫一眼就知道先看哪条。
// · **每条都带数字与人话**，不写"存在异常"这种没法行动的话；每条都给一条 fixHint。
// · 宽度 560：一屏能容纳"标题+详情+建议+定位按钮"而不折行折得难看，又不到整窗宽。
//
// 引擎逻辑全在 `lib/analysis/route_check.dart`（纯函数、可单测），本文件只管呈现与跳转。

import 'package:flutter/material.dart';

import '../../analysis/route_check.dart';
import '../../models/map_label.dart';
import '../../state/app_state.dart';
import '../dialogs.dart';
import '../design_tokens.dart';

/// 打开出图体检面板。
///
/// [onLocate] 由外壳注入：把相关点选中并把地图移过去（桌面壳里就是 `_mc.move` +
/// 设置选中）。为空时「定位」按钮不显示（纯报告模式，便于测试与复用）。
Future<void> showRouteInspectDialog(
  BuildContext context,
  AppState st, {
  void Function(List<String> labelIds)? onLocate,
}) async {
  final opt = RouteCheckOptions(
    // 竣工模式要求填盘留：竣工资料的用途就是结算，缺盘留算不出光缆用量。
    completionMode: st.editModeName == 'completion',
    // 竣工阶段才卡光缆型号；设计阶段常按型号统一，不必逐段填。
    requireCable: st.editModeName == 'completion',
  );

  await showDarkDialog(
    context,
    title: '出图体检',
    width: 560,
    maxHeightFactor: 0.8,
    content: _InspectBody(st: st, opt: opt, onLocate: onLocate),
    actions: [darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub)],
  );
}

class _InspectBody extends StatefulWidget {
  const _InspectBody({required this.st, required this.opt, this.onLocate});

  final AppState st;
  final RouteCheckOptions opt;
  final void Function(List<String> labelIds)? onLocate;

  @override
  State<_InspectBody> createState() => _InspectBodyState();
}

class _InspectBodyState extends State<_InspectBody> {
  /// 三个等级各自是否显示（默认全开）。
  final Set<IssueLevel> _shown = {
    IssueLevel.error,
    IssueLevel.warn,
    IssueLevel.info,
  };

  List<RouteIssue> get _all => RouteChecker.check(
        widget.st.segments,
        widget.st.labels,
        opt: widget.opt,
      );

  Color _levelColor(IssueLevel l) => switch (l) {
        IssueLevel.error => kDanger,
        IssueLevel.warn => kWarn,
        IssueLevel.info => kTextSub,
      };

  @override
  Widget build(BuildContext context) {
    final all = _all;
    final shown = all.where((i) => _shown.contains(i.level)).toList();

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _summary(all),
          const SizedBox(height: TokSp.s),
          _filterRow(all),
          const SizedBox(height: TokSp.s),
          const Divider(height: 1, color: TokC.divider),
          if (all.isEmpty)
            _allClear()
          else if (shown.isEmpty)
            _emptyFiltered()
          else
            ...shown.map(_issueTile),
          if (all.any((i) => i.code == 'seg_label_drift')) ...[
            const SizedBox(height: TokSp.s),
            const Divider(height: 1, color: TokC.divider),
            _driftFixRow(all),
          ],
        ],
      ),
    );
  }

  /// 顶部概要：一行把"有多少问题、严重到什么程度"讲清。
  Widget _summary(List<RouteIssue> all) {
    int n(IssueLevel l) => all.where((i) => i.level == l).length;
    if (all.isEmpty) {
      return Row(
        children: [
          const Icon(Icons.verified, color: kGreen, size: 18),
          const SizedBox(width: TokSp.s),
          Text('未发现问题，可以出图',
              style: TextStyle(
                  color: kGreen, fontSize: TokFs.body, fontWeight: FontWeight.w500)),
        ],
      );
    }
    return Wrap(
      spacing: TokSp.m,
      runSpacing: TokSp.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('共 ${all.length} 项待确认',
            style: const TextStyle(color: kTextMain, fontSize: TokFs.body)),
        for (final l in IssueLevel.values)
          if (n(l) > 0)
            _countChip(l, n(l)),
      ],
    );
  }

  Widget _countChip(IssueLevel l, int n) {
    final c = _levelColor(l);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(TokR.s),
        border: Border.all(color: c.withValues(alpha: 0.6), width: 0.5),
      ),
      child: Text('${l.label} $n',
          style: TextStyle(color: c, fontSize: TokFs.caption)),
    );
  }

  /// 筛选：多选，点一下切换某一等级是否显示。
  Widget _filterRow(List<RouteIssue> all) {
    int n(IssueLevel l) => all.where((i) => i.level == l).length;
    return Wrap(
      spacing: TokSp.s,
      runSpacing: TokSp.xs,
      children: [
        for (final l in IssueLevel.values)
          FilterChip(
            label: Text('${l.label}（${n(l)}）',
                style: TextStyle(
                    fontSize: TokFs.small,
                    color: _shown.contains(l) ? Colors.black : kTextMain)),
            selected: _shown.contains(l),
            selectedColor: _levelColor(l),
            backgroundColor: kFieldBg,
            showCheckmark: false,
            side: BorderSide.none,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => setState(() {
              if (!_shown.remove(l)) _shown.add(l);
            }),
          ),
      ],
    );
  }

  Widget _allClear() => Padding(
        padding: const EdgeInsets.symmetric(vertical: TokSp.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('这一版可以交付',
                style: TextStyle(
                    color: kTextMain,
                    fontSize: TokFs.title,
                    fontWeight: FontWeight.w500)),
            SizedBox(height: TokSp.xs),
            Text('段距、敷设方式、编号、标注一致性都通过检查。\n'
                '导出前建议再用「工程 → 导出成果」核对一次图框与分层。',
                style: TextStyle(
                    color: kTextSub, fontSize: TokFs.small, height: 1.6)),
          ],
        ),
      );

  Widget _emptyFiltered() => Padding(
        padding: const EdgeInsets.symmetric(vertical: TokSp.l),
        child: Text('当前筛选下没有问题（勾上上方等级可查看其它）',
            style: const TextStyle(color: kTextSub, fontSize: TokFs.small)),
      );

  /// 单条问题：左侧等级色条 + 标题 + 详情 + 建议 + 定位按钮。
  Widget _issueTile(RouteIssue i) {
    final c = _levelColor(i.level);
    return Container(
      margin: const EdgeInsets.only(top: TokSp.s),
      padding: const EdgeInsets.fromLTRB(TokSp.s, TokSp.s, TokSp.s, TokSp.s),
      decoration: BoxDecoration(
        color: kCardBg,
        borderRadius: BorderRadius.circular(TokR.m),
        border: Border(left: BorderSide(color: c, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(i.title,
                    style: TextStyle(
                        color: c,
                        fontSize: TokFs.body,
                        fontWeight: FontWeight.w500)),
              ),
              if (widget.onLocate != null)
                _locateBtn(i),
            ],
          ),
          const SizedBox(height: TokSp.xs),
          Text(i.detail,
              style: const TextStyle(
                  color: kTextMain, fontSize: TokFs.small, height: 1.5)),
          const SizedBox(height: TokSp.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lightbulb_outline, size: 13, color: kTextHint),
              const SizedBox(width: TokSp.xs),
              Expanded(
                child: Text(i.fixHint,
                    style: const TextStyle(
                        color: kTextHint, fontSize: TokFs.caption, height: 1.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _locateBtn(RouteIssue i) => TextButton.icon(
        onPressed: () {
          // 先关面板再定位：否则遮罩挡住地图，用户看不到"跳过去了"。
          Navigator.pop(context);
          widget.onLocate!(i.labelIds);
        },
        icon: const Icon(Icons.my_location, size: 15, color: kAccent),
        label: const Text('定位', style: TextStyle(color: kAccent, fontSize: TokFs.small)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: TokSp.s),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );

  /// 「清除漂移段标」：唯一的一键修动作 —— 把手填的、与实测不符的数字清掉，
  /// 让段标回到由敷设方式 + 实测距离实时生成。不替用户改几何、不动敷设方式。
  Widget _driftFixRow(List<RouteIssue> all) {
    final drift = all.where((i) => i.code == 'seg_label_drift').toList();
    if (drift.isEmpty) return const SizedBox.shrink();
    final ids = <String>{for (final d in drift) ...d.labelIds};
    return Row(
      children: [
        Expanded(
          child: Text(
            '有 ${drift.length} 段的手填标注与实测段距不符',
            style: const TextStyle(color: kTextSub, fontSize: TokFs.caption),
          ),
        ),
        TextButton(
          onPressed: () {
            final targets = widget.st.labels
                .where((l) => ids.contains(l.id))
                .toList(growable: false);
            final n = widget.st.clearSegLabels(targets);
            setState(() {});
            toast(context, n > 0
                ? '已清除 $n 段漂移标注，段标改由敷设方式 + 实测距离自动生成'
                : '没有需要清除的标注');
          },
          child: Text('清除漂移段标（${drift.length}）',
              style: const TextStyle(color: kWarn, fontSize: TokFs.small)),
        ),
      ],
    );
  }
}

/// 供外壳复用的定位辅助：把一串 id 落到草稿点上（保持调用侧不重复写查找逻辑）。
List<MapLabel> labelsByIds(AppState st, List<String> ids) =>
    st.labels.where((l) => ids.contains(l.id)).toList(growable: false);
