import 'package:flutter/material.dart';

import '../models/diff_report.dart';
import '../state/app_state.dart';
import 'dialogs.dart';
import 'design_tokens.dart';

/// 批量属性编辑对话框：预览选中数；表单每项含"不改"选项
/// （敷设方式 / 光缆型号 / 盘留 / 命名前缀 / 段标注前缀）。
/// 确定 → `AppState.applyBatch`（内部一次 `pushUndoSnapshot`，可**一次撤销**）。
Future<void> showBatchEditDialog(BuildContext context, AppState st) async {
  final n = st.selectedIds.length;
  if (n == 0) {
    toast(context, '没有选中的点');
    return;
  }

  final cableCtl = TextEditingController();
  final slackCtl = TextEditingController();
  final nameCtl = TextEditingController();
  final distPrefixCtl = TextEditingController();
  int? segKindSel;
  var clearCable = false;
  var renumber = false;

  await showDarkDialog(
    context,
    title: '批量设置属性（$n 点）',
    content: StatefulBuilder(
      builder: (ctx, setSt) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('留空 / 选「不改」的项不会被修改；修改后可一次「撤销」整批回退。',
                style: TextStyle(color: kTextSub, fontSize: 11)),
            const SizedBox(height: 10),
            const Text('敷设方式', style: TextStyle(color: kTextSub, fontSize: 11)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final kv in const <int?, String>{
                  null: '不改',
                  0: '默认',
                  1: '架空',
                  2: '埋地',
                  3: '管道',
                }.entries)
                  ChoiceChip(
                    label: Text(kv.value,
                        style: TextStyle(
                            fontSize: 12,
                            color: segKindSel == kv.key
                                ? Colors.black
                                : kTextMain)),
                    selected: segKindSel == kv.key,
                    selectedColor: kAccent,
                    backgroundColor: TokC.field,
                    side: BorderSide.none,
                    onSelected: (_) => setSt(() => segKindSel = kv.key),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
                controller: cableCtl,
                style: const TextStyle(color: kTextMain, fontSize: 14),
                decoration: dec('光缆型号（留空=不改，如 48芯GYTS）')),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('清空光缆型号',
                  style: TextStyle(color: kTextMain, fontSize: 13)),
              value: clearCable,
              activeColor: kAccent,
              onChanged: (v) => setSt(() => clearCable = v ?? false),
            ),
            const SizedBox(height: 4),
            TextField(
                controller: slackCtl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: kTextMain, fontSize: 14),
                decoration: dec('接头盘留（米，留空=不改；填 0=清零）')),
            const SizedBox(height: 10),
            TextField(
                controller: nameCtl,
                style: const TextStyle(color: kTextMain, fontSize: 14),
                decoration: dec('命名前缀（留空=不改，如 GK）')),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('按前缀重编号（前缀-1、前缀-2…）',
                  style: TextStyle(color: kTextMain, fontSize: 13)),
              value: renumber,
              activeColor: kAccent,
              onChanged: (v) => setSt(() => renumber = v ?? false),
            ),
            const SizedBox(height: 4),
            TextField(
                controller: distPrefixCtl,
                style: const TextStyle(color: kTextMain, fontSize: 14),
                decoration: dec('段标注前缀（留空=不改，如 埋 / 管，保留原数字）')),
          ],
        ),
      ),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('确定', () {
        final cable = cableCtl.text.trim();
        final slack = slackCtl.text.trim();
        final nameP = nameCtl.text.trim();
        final distP = distPrefixCtl.text.trim();
        final edit = BatchEdit(
          segKind: segKindSel,
          segCable: clearCable ? '' : (cable.isEmpty ? null : cable),
          slackM: slack.isEmpty ? null : double.tryParse(slack),
          namePrefix: nameP.isEmpty ? null : nameP,
          distLabelPrefix: distP.isEmpty ? null : distP,
          renumber: renumber,
        );
        if (edit.isEmpty && !edit.renumber) {
          toast(context, '没有要修改的项');
          return;
        }
        Navigator.pop(context);
        final changed = st.applyBatch(edit);
        toast(context, '已批量修改 $changed 点（可点「撤销」一次回退）');
      }),
    ],
  );
}
