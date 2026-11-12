import 'package:flutter/material.dart';

import '../export/archive_book.dart';
import '../export/csv.dart';
import '../models/diff_report.dart';
import '../models/map_label.dart';
import '../services/store.dart';
import '../state/app_state.dart';
import 'dialogs.dart';
import 'design_tokens.dart';

/// 成果中心（P0-1/P0-3/P0-4）：上下文感知导出 + 一键成册 + 变更对照。
///
/// · [openExportCenter]：编辑时导出草稿、拓扑时导出配线，收敛 4 个导出出口为 1；
/// · [showArchiveBookDialog]：竣工资料一键成册（ZIP，严格 4 项）；
/// · [showDesignDiffDialog]：设计 ↔ 竣工可读变更清单（可导出 CSV）。

/// 上下文感知导出中心：把"谁在什么上下文调 showExportDialog"收敛到一个包装函数。
/// 内部**原样调用** `showExportDialog`（7 种导出一个不动）。
Future<void> openExportCenter(BuildContext context, AppState st) async {
  List<MapLabel> labels;
  String name;
  if (st.mode == AppMode.topoLink) {
    labels = st.topoColl;
    final nm = await st.store.loadCollectionName(st.topoCid);
    name = nm.isEmpty ? '配线' : nm;
  } else if (st.labels.isNotEmpty) {
    labels = st.labels;
    name = st.projectName.isEmpty ? '当前草稿' : st.projectName;
  } else {
    toast(context, '没有可导出的数据');
    return;
  }
  if (!context.mounted) return;
  await showExportDialog(context, labels, name, segPrefix: st.segPrefix);
}

/// 成册对象：当前草稿（[draft]=true）或某个收藏工程。
class _BookOption {
  final String label;
  final String cid;
  final bool draft;
  const _BookOption({required this.label, this.cid = '', this.draft = false});
}

/// 竣工资料一键成册对话框：选工程 → 生成 ZIP → 分享。缺项在说明页标注。
Future<void> showArchiveBookDialog(BuildContext context, AppState st) async {
  final options = <_BookOption>[];
  if (st.labels.isNotEmpty) {
    options.add(_BookOption(
      label: st.projectName.isEmpty ? '当前草稿' : '当前草稿 · ${st.projectName}',
      draft: true,
    ));
  }
  for (final m in st.collections) {
    options.add(
        _BookOption(label: m.name.isEmpty ? '未命名' : m.name, cid: m.id));
  }
  if (options.isEmpty) {
    toast(context, '没有可成册的工程');
    return;
  }
  await showDarkDialog(
    context,
    title: '竣工资料一键成册',
    content: SizedBox(
      width: double.maxFinite,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text(
            '选择工程，一键生成 ZIP：路由图 DXF + 工程量清单 + 材料统计 + 照片册（缺项自动跳过）',
            style: TextStyle(color: kTextSub, fontSize: 12)),
        const SizedBox(height: 10),
        Flexible(
          child: ListView(shrinkWrap: true, children: [
            for (final o in options)
              ListTile(
                dense: true,
                leading: const Icon(Icons.folder_zip_outlined,
                    color: kAccent, size: 20),
                title: Text(o.label,
                    style: const TextStyle(color: kTextMain, fontSize: 13.5)),
                onTap: () {
                  Navigator.pop(context);
                  _runArchiveBook(context, st, o);
                },
              ),
          ]),
        ),
      ]),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
    ],
  );
}

Future<void> _runArchiveBook(
    BuildContext context, AppState st, _BookOption o) async {
  List<MapLabel> labels;
  String name;
  var pointCount = 0;
  String editMode = st.editModeName;
  if (o.draft) {
    labels = st.labels;
    name = st.projectName.isEmpty ? '当前草稿' : st.projectName;
  } else {
    labels = await st.store.loadCollection(o.cid);
    final meta = st.collections.firstWhere(
      (m) => m.id == o.cid,
      orElse: () => CollectionMeta(id: o.cid),
    );
    name = meta.name.isEmpty ? '未命名项目' : meta.name;
    pointCount = meta.count;
    editMode = meta.editMode;
  }
  if (!context.mounted) return;
  if (labels.isEmpty) {
    toast(context, '该工程没有点位');
    return;
  }
  toast(context, '正在生成竣工资料成册…');
  try {
    final r = await ArchiveBookExporter.export(
      name: name,
      labels: labels,
      pointCount: pointCount,
      editMode: editMode,
      segPrefix: st.segPrefix,
    );
    if (!context.mounted) return;
    if (r.skipped.isNotEmpty) {
      toast(context, '成册完成，缺项：${r.skipped.join('、')}');
    } else {
      toast(context, '成册完成：含 ${r.included.length} 项');
    }
    await shareFile(context, r.zip);
  } catch (e) {
    if (context.mounted) toast(context, '成册失败：$e');
  }
}

/// 变更对照对话框：选设计工程 → 可读清单（汇总 + 变更项 + 阈值 + 仅看变更项）
/// → 导出 CSV（复用 `CsvExporter.exportDesignDiff` 口径）。
Future<void> showDesignDiffDialog(
    BuildContext context, AppState st, CollectionMeta completionMeta) async {
  final others =
      st.collections.where((c) => c.id != completionMeta.id).toList();
  if (others.isEmpty) {
    toast(context, '没有可对比的设计工程');
    return;
  }
  await showDarkDialog(
    context,
    title:
        '与「${completionMeta.name.isEmpty ? '未命名' : completionMeta.name}」对比的设计工程',
    content: SizedBox(
      width: double.maxFinite,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('选设计版工程，生成本工程（竣工）与它的杆位/段距差异清单',
            style: TextStyle(color: kTextSub, fontSize: 12)),
        const SizedBox(height: 8),
        Flexible(
          child: ListView(shrinkWrap: true, children: [
            for (final c in others)
              ListTile(
                dense: true,
                leading: const Icon(Icons.compare_arrows,
                    color: kAccent, size: 20),
                title: Text(c.name.isEmpty ? '未命名' : c.name,
                    style: const TextStyle(color: kTextMain, fontSize: 13.5)),
                subtitle: Text('${c.count} 点',
                    style: const TextStyle(color: kTextSub, fontSize: 11)),
                onTap: () async {
                  Navigator.pop(context);
                  final comp = await st.store.loadCollection(completionMeta.id);
                  final des = await st.store.loadCollection(c.id);
                  if (!context.mounted) return;
                  await _showDiffReport(
                      context, completionMeta, c, des, comp);
                },
              ),
          ]),
        ),
      ]),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
    ],
  );
}

Future<void> _showDiffReport(
  BuildContext context,
  CollectionMeta completionMeta,
  CollectionMeta designMeta,
  List<MapLabel> design,
  List<MapLabel> comp,
) async {
  var threshold = 1.0;
  var onlyChanged = false;
  final thCtl = TextEditingController(text: '1.0');
  final name =
      completionMeta.name.isEmpty ? '未命名项目' : completionMeta.name;

  await showDarkDialog(
    context,
    title: '变更对照：$name',
    content: StatefulBuilder(
      builder: (ctx, setSt) {
        final report = CsvExporter.buildDesignDiff(design, comp,
            offsetThreshold: threshold);
        final poles = onlyChanged ? report.changedPoles : report.poles;
        final s = report.summary;
        final maxH = MediaQuery.of(ctx).size.height * 0.58;
        return SizedBox(
          width: double.maxFinite,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('设计：${designMeta.name.isEmpty ? '未命名' : designMeta.name}',
                      style: const TextStyle(color: kTextSub, fontSize: 11.5)),
                  const SizedBox(height: 6),
                  _sumRow('新增杆位', '${s.added}', TokC.ok),
                  _sumRow('缺失杆位', '${s.removed}', TokC.danger),
                  _sumRow('偏移杆位', '${s.moved}', TokC.warn),
                  _sumRow('一致杆位', '${s.kept}', kTextSub),
                  _sumRow('净长度差', '${s.netLenDiffM.toStringAsFixed(1)} m',
                      kTextMain),
                  const Divider(color: TokC.divider),
                  Row(children: [
                    const Text('偏移阈值(米)',
                        style: TextStyle(color: kTextMain, fontSize: 12.5)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: thCtl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        style:
                            const TextStyle(color: kTextMain, fontSize: 13),
                        decoration: dec('1.0'),
                        onSubmitted: (v) {
                          final d = double.tryParse(v.trim());
                          if (d != null && d >= 0) setSt(() => threshold = d);
                        },
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        final d = double.tryParse(thCtl.text.trim());
                        if (d != null && d >= 0) {
                          setSt(() => threshold = d);
                        } else {
                          toast(ctx, '阈值无效');
                        }
                      },
                      child: const Text('应用',
                          style: TextStyle(color: kAccent)),
                    ),
                  ]),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('仅看变更项',
                        style: TextStyle(color: kTextMain, fontSize: 13)),
                    value: onlyChanged,
                    onChanged: (v) => setSt(() => onlyChanged = v),
                  ),
                  const SizedBox(height: 4),
                  Text('杆位对照（${poles.length}/${report.poles.length}）',
                      style: const TextStyle(color: kAccent, fontSize: 12.5)),
                  for (final p in poles) _poleRow(p),
                  const SizedBox(height: 10),
                  Text('段距对比（${report.segs.length}）',
                      style: const TextStyle(color: kAccent, fontSize: 12.5)),
                  if (report.segs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(report.notes.join('；'),
                          style: const TextStyle(
                              color: kTextSub, fontSize: 11.5)),
                    )
                  else
                    for (final seg in report.segs) _segRow(seg),
                ],
              ),
            ),
          ),
        );
      },
    ),
    actions: [
      darkTextBtn('导出 CSV', () async {
        try {
          final f = await CsvExporter.exportDesignDiff(name, design, comp,
              offsetThreshold: threshold);
          if (context.mounted) shareFile(context, f);
        } catch (e) {
          if (context.mounted) toast(context, '导出失败：$e');
        }
      }),
      darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
    ],
  );
}

Widget _sumRow(String label, String value, Color color) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(children: [
        SizedBox(
            width: 88,
            child: Text(label,
                style: const TextStyle(color: kTextSub, fontSize: 12.5))),
        Text(value,
            style: TextStyle(
                color: color, fontSize: 12.5, fontWeight: FontWeight.bold)),
      ]),
    );

Widget _poleRow(DiffPoleItem p) {
  final label = switch (p.status) {
    DiffStatus.added => '新增',
    DiffStatus.removed => '缺失',
    DiffStatus.moved => '偏移',
    DiffStatus.same => '一致',
  };
  final color = switch (p.status) {
    DiffStatus.added => TokC.ok,
    DiffStatus.removed => TokC.danger,
    DiffStatus.moved => TokC.warn,
    DiffStatus.same => kTextSub,
  };
  final extra = switch (p.status) {
    DiffStatus.moved || DiffStatus.same =>
      '　偏移 ${p.offsetM.toStringAsFixed(1)}m',
    _ => '',
  };
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 1.5),
    child: Row(children: [
      SizedBox(
          width: 40,
          child: Text(label,
              style: TextStyle(color: color, fontSize: 12))),
      Expanded(
        child: Text('${p.key}$extra',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: kTextMain, fontSize: 12.5)),
      ),
    ]),
  );
}

Widget _segRow(DiffSegItem seg) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(children: [
        Expanded(
          child: Text(seg.seg,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kTextMain, fontSize: 12.5)),
        ),
        Text(
            '${seg.designM.toStringAsFixed(1)} → ${seg.compM.toStringAsFixed(1)} '
            '(${seg.deltaM >= 0 ? '+' : ''}${seg.deltaM.toStringAsFixed(1)})',
            style: TextStyle(
                color: seg.deltaM.abs() > 0.05
                    ? TokC.warn
                    : kTextSub,
                fontSize: 12)),
      ]),
    );
