// ================= 图源 / 图层面板（定宽、紧凑、高密度）=================
//
// 【为什么固定 480】
// 旧实现用 `SizedBox(width: double.maxFinite)`，在普通 AlertDialog 里会被撑到接近整窗宽
// （1600px 窗口 ≈ 1520px 宽对话框）。但本面板只有一列「单选」语义的内容，行内只有一个
// RadioListTile——内容密度配不上容器宽度，大片留白、视线横扫距离过长。实测一屏能从容容纳
// 2 列卡片，480 是「不挤、不空、桌面/移动都能用」的经验下界：再窄塞不下 2 列卡片网格，
// 再宽又回到横扫过长的问题。故固定 480，最大高度限制为视口 70%（内容可滚动），绝不使用
// double.maxFinite。
//
// 【为什么用卡片网格而不是列表】
// 主图源本质是「互斥单选 + 需要一眼扫到名称/坐标系/级别」的短信息集合。列表（RadioListTile）
// 每行只占一行、信息密度低，且要纵向滚很久。改用 2 列卡片网格后：① 同等数量图源纵向长度
// 减半；② 卡片能并排展示「名称 + 坐标系徽标 + z最大级别」三层信息，密度合理；③ 选中态用
// 强调边框 + 右上角 ✓，比纯圆点更醒目，符合线路设计人员「换底图时快速认出当前源」的诉求。
//
// 【信息层级怎么排】
// 三段式，每段小标题 11px / kTextSub 灰字：
//   1) 主图源 —— 2 列卡片网格（名称一行省略号；第二行「坐标系徽标 · z级别」）
//   2) 注记叠加层 —— 紧凑单选列表（RadioListTile dense，首项「无」）
//   3) 自定义图源操作 —— 两个按钮 + 模板说明灰字
// 底部「完成」按钮保留，关闭即生效。
//
// 【线路设计人员在什么场景下打开它】
// 这个面板是「看图」的中枢，不是高频操作：换底图看整体走向、切到卫星影像核实地物（杆路/
// 机房是否与实景吻合）、加公司内网瓦片服务（{x}{y}{z} 模板）做内业比对。所以设计目标是
// 「一次打开、快速定位、少滚动」，而不是塞更多功能。互斥项（叠加层）必须用 Radio 而非
// Checkbox，避免用户误以为能多选。
//
// 所有行为语义与原 dialogs.showSourceDialog 完全一致：applySource / applyOverlay /
// addCustomSource / removeCustomSource / showAddCustomSource 调用方式不变，无新增网络/IO。
// AppState 读法照抄原实现（allSources.where(!overlay)、allOverlays、curSource.id、overlayId）。

import 'package:flutter/material.dart';

import '../../geo/geo_convert.dart';
import '../../models/map_source.dart';
import '../../state/app_state.dart';
import '../design_tokens.dart';
import '../dialogs.dart'
    show
        darkTextBtn,
        kAccent,
        kTextMain,
        kTextSub,
        showAddCustomSource,
        showDarkDialog,
        toast;

/// 叠加层「无」用哨兵值表达（Radio 的 value 不能为 null）。
const String _kNoneOverlay = '__none__';

/// 面板定宽（与 dialogs.showDarkDialog 的 width 保持一致）。改用常量而非 LayoutBuilder：
/// AlertDialog 会对 content 求固有尺寸，内层放 LayoutBuilder 会抛「不支持固有尺寸」异常；
/// 故卡片宽度由固定对话框宽度反推，不再依赖运行时约束查询。
const double kPanelWidth = 480;
const double kContentH = 16; // 面板内部左右留白
const double kCardGap = 8; // 卡片网格间距
const double kCardW = (kPanelWidth - 2 * kContentH - kCardGap) / 2;

/// 入口：供 dialogs.showSourceDialog 委托调用，外部调用方无感。
Future<void> showSourcePanel(BuildContext context, AppState st) {
  return showDarkDialog(
    context,
    title: '图源 / 图层',
    width: kPanelWidth, // 定宽：修复「对话框被撑到整窗宽」的核心参数
    maxHeightFactor: 0.7, // 最大高度 = 视口 70%，内容可滚动
    content: StatefulBuilder(
      builder: (ctx, setSt) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: kContentH, vertical: 12),
          child: _SourcePanelBody(
            context: ctx, // 用于「添加/删除自定义源」时 pop 当前面板
            st: st,
            refresh: () => setSt(() {}),
          ),
        ),
      ),
    ),
    actions: [darkTextBtn('完成', () => Navigator.pop(context))],
  );
}

class _SourcePanelBody extends StatelessWidget {
  final BuildContext context;
  final AppState st;
  final VoidCallback refresh;

  const _SourcePanelBody({
    required this.context,
    required this.st,
    required this.refresh,
  });

  /// 坐标系徽标颜色：WGS-84 青 / GCJ-02 橙 / BD-09 红，一眼区分基准。
  Color _datumColor(int d) {
    switch (d) {
      case 1:
        return TokC.warn; // GCJ-02
      case 2:
        return const Color(0xFFE57373); // BD-09
      default:
        return const Color(0xFF80DEEA); // WGS-84
    }
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(t, style: const TextStyle(color: kTextSub, fontSize: TokFs.caption)),
      );

  /// 主图源：2 列卡片网格。
  Widget _sourceCard(MapSourceEntry e, bool selected) {
    final dc = _datumColor(e.datum);
    return InkWell(
      key: Key('srcCard-${e.id}'), // 便于测试只统计主图源卡片（叠加层 RadioListTile 内部也用 InkWell）
      onTap: () {
        st.applySource(e);
        refresh();
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 62, // 卡片高度约 62
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: TokC.field,
          borderRadius: BorderRadius.circular(8), // 圆角 8
          border: Border.all(
            color: selected ? kAccent : TokC.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(e.name,
                          style: const TextStyle(
                              color: kTextMain,
                              fontSize: TokFs.body,
                              fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (e.custom) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: TokC.divider,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('自',
                            style:
                                TextStyle(color: kTextSub, fontSize: TokFs.micro)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(GeoConvert.datumName(e.datum),
                        style: TextStyle(color: dc, fontSize: TokFs.caption)),
                    const SizedBox(width: 6),
                    Text('z${e.maxZoom}',
                        style:
                            const TextStyle(color: kTextSub, fontSize: TokFs.caption)),
                  ],
                ),
              ],
            ),
            if (selected)
              const Positioned(
                top: 0,
                right: 0,
                child: Icon(Icons.check_circle,
                    color: kAccent, size: 18),
              ),
          ],
        ),
      ),
    );
  }

  /// 主图源区块。2 列卡片网格：卡片宽度由固定面板宽度反推（kCardW），
  /// 不用 LayoutBuilder，避免 AlertDialog 求固有尺寸时报错。
  Widget _sourceSection() {
    final sources = st.allSources.where((s) => !s.overlay).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('主图源'),
        Wrap(
          spacing: kCardGap,
          runSpacing: kCardGap,
          children: sources
              .map((e) => SizedBox(
                    width: kCardW,
                    child: _sourceCard(e, st.curSource.id == e.id),
                  ))
              .toList(),
        ),
      ],
    );
  }

  /// 注记叠加层：互斥单选（必须用 Radio，不用 Checkbox）。
  Widget _overlaySection() {
    final items = <MapSourceEntry?>[null, ...st.allOverlays];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('注记叠加层'),
        ...items.map((e) {
          final val = e?.id ?? _kNoneOverlay;
          final label = e == null ? '无' : e.name;
          return RadioListTile<String>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(label,
                style: const TextStyle(color: kTextMain, fontSize: TokFs.body)),
            value: val,
            groupValue: st.overlayId ?? _kNoneOverlay,
            activeColor: kAccent,
            onChanged: (v) {
              st.applyOverlay(v == _kNoneOverlay ? null : v);
              refresh();
            },
          );
        }).toList(),
      ],
    );
  }

  /// 自定义图源操作：添加 / 删除 + 模板说明。
  Widget _customSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('自定义图源操作'),
        Row(
          children: [
            darkTextBtn('＋ 添加自定义图源', () {
              Navigator.pop(context);
              showAddCustomSource(context, st);
            }),
            if (st.curSource.custom)
              darkTextBtn(
                '删除当前自定义源',
                () {
                  st.removeCustomSource(st.curSource.id);
                  Navigator.pop(context);
                  toast(context, '已删除');
                },
                color: TokC.danger,
              ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
            '自定义源支持 {x} {y} {z} 模板（也兼容 {\$x} 旧写法），可填高德/天地图/自建瓦片服务',
            style: TextStyle(color: kTextSub, fontSize: TokFs.caption)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sourceSection(),
        const Divider(color: TokC.divider),
        _overlaySection(),
        const Divider(color: TokC.divider),
        _customSection(),
      ],
    );
  }
}
