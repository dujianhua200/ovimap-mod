import 'package:flutter/material.dart';

import '../geo/geo_util.dart';
import '../models/label_type.dart';
import '../models/map_label.dart';
import '../models/project_template.dart';
import '../state/app_state.dart';
import 'dialogs.dart';
import 'design_tokens.dart';

/// 常用档距自动布杆对话框：起止点默认取草稿末链首尾（可手输经纬度），
/// 档距默认 50m，前缀默认当前编号前缀，杆型默认取当前符号/模板。
/// 布杆结果可一次撤销，落点可再拖动微调。
Future<void> showAutoPoleDialog(BuildContext context, AppState st) async {
  final chains = buildLabelChains(st.labels);
  var defStart = '';
  var defEnd = '';
  if (chains.isNotEmpty) {
    final c = chains.last;
    defStart =
        '${c.first.lat.toStringAsFixed(6)},${c.first.lon.toStringAsFixed(6)}';
    defEnd = '${c.last.lat.toStringAsFixed(6)},${c.last.lon.toStringAsFixed(6)}';
  }
  final startCtl = TextEditingController(text: defStart);
  final endCtl = TextEditingController(text: defEnd);
  final spaceCtl = TextEditingController(text: '50');
  final prefixCtl = TextEditingController(text: st.numPrefix);
  var typeId = st.curType.id;

  await showDarkDialog(
    context,
    title: '自动布杆（等距）',
    content: StatefulBuilder(
      builder: (ctx, setSt) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('两点直线等距布杆，含起点与终点；结果可「撤销」，落点可再拖动微调。',
                style: TextStyle(color: kTextSub, fontSize: 11)),
            const SizedBox(height: 8),
            TextField(
                controller: startCtl,
                style: const TextStyle(color: kTextMain, fontSize: 13),
                decoration: dec('起点 纬度,经度（如 32.10,114.08）')),
            const SizedBox(height: 8),
            TextField(
                controller: endCtl,
                style: const TextStyle(color: kTextMain, fontSize: 13),
                decoration: dec('终点 纬度,经度')),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                    controller: spaceCtl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    style: const TextStyle(color: kTextMain, fontSize: 14),
                    decoration: dec('平均档距(米)')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                    controller: prefixCtl,
                    style: const TextStyle(color: kTextMain, fontSize: 14),
                    decoration: dec('编号前缀')),
              ),
            ]),
            const SizedBox(height: 10),
            const Text('杆型', style: TextStyle(color: kTextSub, fontSize: 11)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in LabelType.all.where((t) =>
                    !const ['text', 'track', 'none', 'area'].contains(t.id)))
                  ChoiceChip(
                    label: Text(t.name,
                        style: TextStyle(
                            fontSize: 12,
                            color: typeId == t.id ? Colors.black : kTextMain)),
                    selected: typeId == t.id,
                    selectedColor: kAccent,
                    backgroundColor: TokC.field,
                    side: BorderSide.none,
                    onSelected: (_) => setSt(() => typeId = t.id),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('布杆', () {
        final s = GeoUtil.parseCoordInput(startCtl.text);
        final e = GeoUtil.parseCoordInput(endCtl.text);
        if (s == null || e == null) {
          toast(context, '起止坐标格式不对（纬度,经度）');
          return;
        }
        final sp = double.tryParse(spaceCtl.text.trim()) ?? 50;
        // 防御 NaN / Infinity / 非正档距（NaN<=0 为 false，单靠 <=0 拦不住）。
        if (!sp.isFinite || sp <= 0) {
          toast(context, '档距需为正数');
          return;
        }
        final pfx = prefixCtl.text.trim();
        Navigator.pop(context);
        final cnt = st.autoPlacePoles(
          sLat: s[0],
          sLon: s[1],
          eLat: e[0],
          eLon: e[1],
          spacingM: sp,
          typeId: typeId,
          prefix: pfx.isEmpty ? st.numPrefix : pfx,
        );
        toast(context, '已布 $cnt 基杆（可点「撤销」回退）');
      }),
    ],
  );
}

/// 工程模板对话框：预置"架空光缆 / 管道光缆 / 箱体配线"，点选即套用。
/// 模板只设置"默认值"（新增点沿用），不回溯已有点。
Future<void> showTemplateDialog(BuildContext context, AppState st) async {
  await showDarkDialog(
    context,
    title: '工程模板',
    content: StatefulBuilder(
      builder: (ctx, setSt) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('套用后，此后新增点沿用模板的默认符号 / 敷设方式 / 型号 / 盘留（不回溯已有点）。',
              style: TextStyle(color: kTextSub, fontSize: 11)),
          const SizedBox(height: 8),
          for (final t in ProjectTemplate.presets)
            ListTile(
              dense: true,
              leading: Icon(
                st.templateId == t.id
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: st.templateId == t.id ? kGreen : kTextSub,
                size: 20,
              ),
              title: Text(t.name,
                  style: const TextStyle(color: kTextMain, fontSize: 13.5)),
              subtitle: Text(
                '符号 ${LabelType.fromId(t.defTypeId).name} · '
                '敷设 ${_kindName(t.defSegKind)}'
                '${t.defSegCable.isNotEmpty ? ' · ${t.defSegCable}' : ''}'
                '${t.defSlackM > 0 ? ' · 盘留${_slack(t.defSlackM)}m' : ''}',
                style: const TextStyle(color: kTextSub, fontSize: 11),
              ),
              onTap: () {
                st.applyTemplate(t);
                setSt(() {});
                toast(context, '已套用模板「${t.name}」');
              },
            ),
        ],
      ),
    ),
    actions: [
      darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
    ],
  );
}

String _kindName(int k) =>
    const {0: '默认', 1: '架空', 2: '埋地', 3: '管道'}[k] ?? '默认';

String _slack(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
