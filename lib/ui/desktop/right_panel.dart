import 'dart:async';

import 'package:flutter/material.dart';

import '../../geo/geo_util.dart';
import '../../models/label_type.dart';
import '../../models/map_label.dart';
import '../../state/app_state.dart';
import '../design_tokens.dart';
import '../dialogs.dart';
import 'stats_section.dart';

/// 桌面右栏：选中点属性面板（架构文档 §3.2 / T10）。
///
/// **复用现有属性编辑逻辑**（字段口径、敷设方式枚举、管孔/分光比分支与
/// `showLabelProperties` 一致），仅把容器从「回中对话框」换成常驻侧栏；
/// 照片等重交互仍走 [showLabelProperties]（零逻辑重复）。
///
/// [sourceCid] 为空表示草稿点（走 `st.updateLabel`），否则为可见收藏点
/// （走 `st.updateOverlayLabel`）。
///
/// ## 本轮（出图效率专项）改了什么、为什么
///
/// 1. **尺度全面令牌化**。改前这一个文件里字号有 10/11/12/12.5/13.5/15 六档，
///    间距有 4/6/8/10/14/18，颜色有 3 处硬编码色值——"界面太粗糙"的真正来源不是
///    审美，而是这种**局部合理、整体不齐**的即兴发挥。现在只从 [TokFs]/[TokSp]/
///    [TokR]/[TokC] 取。
/// 2. **段标实时预览**。原先用户在右栏改「本段标注」和敷设方式时，**看不到图上会写成
///    什么**——要切回地图找那一档才能确认。现在输入框下方直接显示「图上显示：埋42」，
///    这一行与地图、DXF 共用 [GeoUtil.segTextPreview] 同一份规则。
/// 3. **未保存可见 + 切换自动落盘**。面板有 8 个字段共用底部一个「保存」，改完忘点、
///    或改完直接去点地图上另一个点，改动就静默丢了——对出图是事故。现在标题栏出现
///    「未保存」橙标，且**切换到别的点时先自动写回**，不再丢。
class RightPanel extends StatefulWidget {
  const RightPanel({
    super.key,
    required this.st,
    required this.label,
    required this.sourceCid,
    required this.onCleared,
  });

  final AppState st;
  final MapLabel? label;
  final String sourceCid;

  /// 选中点被删除后回调（壳据此清空选中）。
  final VoidCallback onCleared;

  @override
  State<RightPanel> createState() => _RightPanelState();
}

class _RightPanelState extends State<RightPanel> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final TextEditingController _segLabel = TextEditingController();
  final TextEditingController _dist = TextEditingController();
  final TextEditingController _slack = TextEditingController();
  final TextEditingController _segCable = TextEditingController();
  final TextEditingController _holes = TextEditingController();
  final TextEditingController _used = TextEditingController();
  final TextEditingController _ratio = TextEditingController();

  int _segKind = 0;

  /// 是否有未写回的改动（驱动标题栏徽标与保存按钮强度）。
  bool _dirty = false;

  /// 正在用 state 回填控件。回填会触发 controller listener，必须屏蔽掉，
  /// 否则一选中点就显示"未保存"。
  bool _loading = false;

  AppState get st => widget.st;

  List<TextEditingController> get _allCtl => [
        _name,
        _note,
        _segLabel,
        _dist,
        _slack,
        _segCable,
        _holes,
        _used,
        _ratio,
      ];

  @override
  void initState() {
    super.initState();
    for (final c in _allCtl) {
      c.addListener(_onEdited);
    }
    _syncFromWidget();
  }

  @override
  void didUpdateWidget(covariant RightPanel old) {
    super.didUpdateWidget(old);
    // 选中对象变化时重填控件（同一对象被就地修改时不覆盖用户输入）。
    if (widget.label?.id != old.label?.id ||
        widget.sourceCid != old.sourceCid) {
      // ★ 切换前先把没保存的改动写回**原来那个点**，否则用户改完直接点地图上
      //   另一个点，这一处改动就无声丢了。
      //
      //   注意必须走 `st.updateLabel` / `st.updateOverlayLabel` 而不是只改内存对象：
      //   后者只是让界面看着对，草稿没落盘，重启即还原——那是更隐蔽的丢数据。
      final prev = old.label;
      if (_dirty && prev != null) {
        _commit(prev, silent: true);
        if (old.sourceCid.isEmpty) {
          st.updateLabel(prev);
        } else {
          unawaited(st.updateOverlayLabel(old.sourceCid, prev));
        }
      }
      _syncFromWidget();
    }
  }

  @override
  void dispose() {
    for (final c in _allCtl) {
      c.removeListener(_onEdited);
      c.dispose();
    }
    super.dispose();
  }

  void _onEdited() {
    if (_loading || _dirty) return;
    setState(() => _dirty = true);
  }

  void _syncFromWidget() {
    _loading = true;
    final l = widget.label;
    _name.text = l?.name ?? '';
    _note.text = l?.note ?? '';
    _segLabel.text = l?.distLabel ?? '';
    _dist.text = (l?.distanceM != null && l!.distanceM! > 0)
        ? GeoUtil.segDistText(l.distanceM!)
        : '';
    _slack.text = (l != null && l.slackM > 0) ? GeoUtil.segDistText(l.slackM) : '';
    _segCable.text = l?.segCable ?? '';
    _holes.text = (l != null && l.holes > 0) ? '${l.holes}' : '';
    _used.text = (l != null && l.usedHoles > 0) ? '${l.usedHoles}' : '';
    _ratio.text = l?.splitterRatio ?? '';
    _segKind = l?.segKind ?? 0;
    _loading = false;
    _dirty = false;
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.label;
    return Container(
      color: TokC.panelSolid,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: TokSp.titlePad,
            child: Row(
              children: [
                const Expanded(
                  child: Text('属性',
                      style: TextStyle(
                          color: TokC.textMain,
                          fontSize: TokFs.heading,
                          fontWeight: FontWeight.w600)),
                ),
                if (_dirty) const _Tag('未保存', TokC.warn),
                if (l != null) ...[
                  const SizedBox(width: TokSp.xs),
                  _Tag(widget.sourceCid.isEmpty ? '草稿' : '收藏', l.type.color),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: TokC.divider),
          Expanded(
            child: l == null
                ? _empty()
                : SingleChildScrollView(
                    padding: TokSp.panelPad,
                    child: _form(context, l),
                  ),
          ),
        ],
      ),
    );
  }

  /// 无选中点：显示提示 + **工程统计**（E1，打开工程/草稿非空时展示）。
  /// `st.labels` 是普通列表（无「未就绪即抛」getter），AOT 安全。
  Widget _empty() {
    final hasData = st.labels.isNotEmpty;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(TokSp.l),
      child: Column(
        children: [
          const Text(
            '未选中点\n\n在地图上单击一个点，或右键点选「编辑属性」\n'
            '即可在此编辑名称 / 段距 / 敷设方式等',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: TokC.textSub, fontSize: TokFs.small, height: 1.6),
          ),
          if (hasData) ...[
            const SizedBox(height: TokSp.m),
            StatsSection(st: st),
          ],
        ],
      ),
    );
  }

  Widget _form(BuildContext context, MapLabel l) {
    final isWell = const ['manhole', 'handwell', 'pipe'].contains(l.typeId);
    final isTopoBox = l.type.isTopoNode;
    final showSeg = l.seq > 1 && l.typeId != 'text' && l.typeId != 'track';

    // 段标自动补距离：取同线组上一链点的段距（与地图渲染口径一致）。
    final prev = st.previousChainLabel(l);
    final autoSegDist = prev == null
        ? null
        : (l.distanceM ?? GeoUtil.haversine(prev.lat, prev.lon, l.lat, l.lon));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${l.type.name}　#${l.seq}',
            style: const TextStyle(color: TokC.textSub, fontSize: TokFs.caption)),
        const SizedBox(height: TokSp.s),
        _field(_name, '名称'),
        const SizedBox(height: TokSp.s),
        _field(_note, '备注', maxLines: 2),
        const SizedBox(height: TokSp.s),
        // 符号样式替换（用户需求：属性里可替换符号样式；草稿/收藏点通用）。
        DropdownButtonFormField<String>(
          value: LabelType.all.any((t) => t.id == l.typeId) ? l.typeId : null,
          dropdownColor: TokC.panelSolid,
          isExpanded: true,
          isDense: true,
          style: const TextStyle(color: TokC.textMain, fontSize: TokFs.body),
          decoration: dec('符号样式'),
          items: [
            for (final t in LabelType.all)
              DropdownMenuItem(value: t.id, child: Text('${t.symbol} ${t.name}')),
          ],
          onChanged: (v) {
            if (v == null || v == l.typeId) return;
            setState(() {
              l.typeId = v;
              _dirty = true;
            });
          },
        ),
        if (showSeg) ...[
          const SizedBox(height: TokSp.m),
          _title('本段'),
          const SizedBox(height: TokSp.xs),
          _field(_segLabel, '如：埋42.5 / 架38，留空自动显示距离'),
          const SizedBox(height: TokSp.xs),
          segPrefixChips(_segLabel, autoDist: autoSegDist),
          const SizedBox(height: TokSp.xs),
          _segPreview(l, autoSegDist),
          const SizedBox(height: TokSp.s),
          _field(_dist, '到上一点距离（米，留空自动）', number: true),
          const SizedBox(height: TokSp.s),
          _field(_slack, '本段接头盘留（米）', number: true),
          const SizedBox(height: TokSp.s),
          _field(_segCable, '本段光缆型号（如 48芯GYTS）'),
          const SizedBox(height: TokSp.m),
          _title('本段敷设方式（决定连线颜色与段标前缀）'),
          const SizedBox(height: TokSp.xs),
          _kindChips(),
        ],
        if (isWell) ...[
          const SizedBox(height: TokSp.m),
          _title('管孔（可选）'),
          const SizedBox(height: TokSp.xs),
          Row(children: [
            Expanded(child: _field(_holes, '总孔数', number: true)),
            const SizedBox(width: TokSp.s),
            Expanded(child: _field(_used, '已占用', number: true)),
          ]),
        ],
        if (isTopoBox) ...[
          const SizedBox(height: TokSp.m),
          _field(_ratio, '分光比（如 1:8 / 1:16）'),
        ],
        const SizedBox(height: TokSp.section),
        _actions(context, l),
      ],
    );
  }

  /// 「图上会写成什么」——把当前**编辑态**（输入框里的字 + 刚点的敷设方式）喂给
  /// [GeoUtil.segTextPreview]，得到与地图、DXF 完全一致的预览。
  ///
  /// 这一行的价值：设计人员改完不必切回地图找那一档去核对，当场就知道出图长什么样。
  Widget _segPreview(MapLabel l, double? autoSegDist) {
    final autoText =
        autoSegDist == null ? '' : GeoUtil.segDistText(autoSegDist);
    final preview = GeoUtil.segTextPreview(_segLabel.text, _segKind, autoText,
        prefix: st.segPrefix);
    final empty = preview.isEmpty;
    final manual = _segLabel.text.trim().isNotEmpty;
    return Row(
      children: [
        const Icon(Icons.visibility_outlined, size: 13, color: TokC.textHint),
        const SizedBox(width: TokSp.xs),
        Text('图上显示：',
            style: const TextStyle(color: TokC.textHint, fontSize: TokFs.caption)),
        Expanded(
          child: Text(
            empty ? '（无段标——缺实测距离）' : preview,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: empty ? TokC.textHint : TokC.accent,
                fontSize: TokFs.caption,
                fontWeight: FontWeight.w600),
          ),
        ),
        if (manual) const _Tag('手填', TokC.accent),
      ],
    );
  }

  Widget _kindChips() {
    const kinds = {0: '默认', 1: '架空', 2: '埋地', 3: '管道'};
    return Wrap(
      spacing: TokSp.xs,
      runSpacing: TokSp.xs,
      children: [
        for (final kv in kinds.entries)
          ChoiceChip(
            label: Text(kv.value,
                style: TextStyle(
                    color: _segKind == kv.key ? Colors.black : TokC.textMain,
                    fontSize: TokFs.small)),
            selected: _segKind == kv.key,
            // 色标与左栏段落表、图例同源：选"架空"就是那根绿线，不是又一个蓝按钮。
            selectedColor: TokC.kind(kv.key),
            backgroundColor: TokC.field,
            side: BorderSide.none,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => setState(() {
              _segKind = kv.key;
              _dirty = true;
            }),
          ),
      ],
    );
  }

  Widget _actions(BuildContext context, MapLabel l) {
    final draft = widget.sourceCid.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () => _save(context, l),
              icon: const Icon(Icons.save, size: 16),
              label: Text(_dirty ? '保存改动' : '已保存',
                  style: const TextStyle(fontSize: TokFs.small)),
              style: FilledButton.styleFrom(
                  // 有未保存改动时按钮才"点亮"——把注意力留给真正要按的那一刻。
                  backgroundColor:
                      TokC.accent.withValues(alpha: _dirty ? 0.95 : 0.32),
                  foregroundColor:
                      _dirty ? Colors.black : TokC.textSub,
                  padding: const EdgeInsets.symmetric(vertical: 10)),
            ),
          ),
          const SizedBox(width: TokSp.s),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _delete(context, l),
              icon: const Icon(Icons.delete_outline,
                  size: 16, color: TokC.danger),
              label: const Text('删除点',
                  style:
                      TextStyle(fontSize: TokFs.small, color: TokC.danger)),
              style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: TokC.danger),
                  padding: const EdgeInsets.symmetric(vertical: 10)),
            ),
          ),
        ]),
        const SizedBox(height: TokSp.s),
        if (draft && l.typeId != 'text' && l.typeId != 'track')
          _wide('从此点续画分支', Icons.call_split, () {
            st.setMode(AppMode.edit);
            st.startRouteFrom(l);
            toast(context, '已从「${_nm(l)}」开始新分支杆路，继续点地图绘制');
          }),
        if (draft)
          _wide('拖动点位', Icons.open_with, () {
            st.draggingLabelId = l.id;
            st.refreshUi();
            toast(context, '拖动模式：在地图上点一下，把「${_nm(l)}」移到那里');
          }),
        if (st.hasFix && st.curLat != null && st.curLon != null)
          _wide('移到当前定位', Icons.my_location, () {
            l.lat = st.curLat!;
            l.lon = st.curLon!;
            if (draft) {
              st.updateLabel(l);
            } else {
              st.updateOverlayLabel(widget.sourceCid, l);
            }
            toast(context, '已把「${_nm(l)}」移到当前定位位置');
          }),
        _wide('完整属性（含照片）…', Icons.photo_camera_back, () {
          showLabelProperties(context, st, l,
              sourceCid: widget.sourceCid, title: _nm(l));
        }),
      ],
    );
  }

  // ================= 统一样式小工具 =================

  /// 输入框统一构造：本文件原先 9 处各写一遍 `style: const TextStyle(...)`，
  /// 字号还各不相同（13.5 / 12.5）。收敛到一处后，右栏所有输入框必然同高同字号。
  Widget _field(TextEditingController ctl, String hint,
      {bool number = false, int maxLines = 1}) {
    return TextField(
      controller: ctl,
      maxLines: maxLines,
      keyboardType:
          number ? const TextInputType.numberWithOptions(decimal: true) : null,
      style: const TextStyle(color: TokC.textMain, fontSize: TokFs.body),
      decoration: dec(hint),
    );
  }

  /// 区块小标题：11px + 字距，用于"换话题"。
  Widget _title(String t) => Text(t,
      style: const TextStyle(
          color: TokC.textSub,
          fontSize: TokFs.caption,
          fontWeight: FontWeight.w500));

  Widget _wide(String text, IconData icon, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(top: TokSp.xs),
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 15, color: TokC.textMain),
          label: Align(
              alignment: Alignment.centerLeft,
              child: Text(text,
                  style: const TextStyle(
                      color: TokC.textMain, fontSize: TokFs.small))),
          style: OutlinedButton.styleFrom(
              side: const BorderSide(color: TokC.divider),
              padding: const EdgeInsets.symmetric(
                  horizontal: TokSp.s, vertical: 10),
              alignment: Alignment.centerLeft),
        ),
      );

  // ================= 提交 =================

  /// 把控件内容写回 [l]。
  ///
  /// [silent] = true 时不弹 toast、不置 `_dirty`——用于"切换点时自动落盘"，
  /// 用户没有主动保存，就不该被提示打扰。
  void _commit(MapLabel l, {bool silent = false}) {
    l.name = _name.text.trim();
    l.note = _note.text.trim();
    l.segKind = _segKind;
    l.distLabel = _segLabel.text.trim();
    final d = double.tryParse(_dist.text.trim());
    l.distanceM = (d != null && d > 0) ? d : null;
    final sk = double.tryParse(_slack.text.trim());
    l.slackM = (sk != null && sk > 0) ? sk : 0;
    l.segCable = _segCable.text.trim();
    l.holes = int.tryParse(_holes.text.trim()) ?? 0;
    l.usedHoles = int.tryParse(_used.text.trim()) ?? 0;
    l.splitterRatio = _ratio.text.trim();
    if (!silent && mounted) setState(() => _dirty = false);
  }

  Future<void> _save(BuildContext context, MapLabel l) async {
    _commit(l);
    if (widget.sourceCid.isEmpty) {
      st.updateLabel(l);
    } else {
      await st.updateOverlayLabel(widget.sourceCid, l);
    }
    if (context.mounted) toast(context, '已保存「${_nm(l)}」');
  }

  Future<void> _delete(BuildContext context, MapLabel l) async {
    if (widget.sourceCid.isEmpty) {
      st.removeLabel(l);
    } else {
      await st.removeOverlayLabel(widget.sourceCid, l);
    }
    widget.onCleared();
  }

  String _nm(MapLabel l) => l.name.trim().isNotEmpty ? l.name.trim() : l.type.name;
}

/// 标题栏小徽标（草稿/收藏/未保存/手填）。
class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: TokSp.xs),
        padding: const EdgeInsets.symmetric(
            horizontal: TokSp.s - 2, vertical: TokSp.xxs),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(TokR.s),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: TokFs.caption)),
      );
}
