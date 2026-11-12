import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../export/archive_book.dart';
import '../export/kml.dart';
import '../export/topo_png.dart';
import '../state/app_state.dart';
import '../services/store.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_models.dart';
import 'dialogs.dart';
import 'export_center.dart';
import 'sync/sync_panel.dart';
import 'design_tokens.dart';

/// 收藏夹抽屉：文件夹 + 收藏项目（显示/打开/拓扑/导出/管理）。
/// 支持按工程名/备注跨文件夹搜索（奥维标签管理器式）。
class FavoritesDrawer extends StatefulWidget {
  final AppState st;
  const FavoritesDrawer({super.key, required this.st});

  @override
  State<FavoritesDrawer> createState() => _FavoritesDrawerState();
}

class _FavoritesDrawerState extends State<FavoritesDrawer> {
  AppState get st => widget.st;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: TokC.panelSolid,
      child: SafeArea(
        child: Column(
          children: [
            _header(context),
            _searchBar(context),
            _folderChips(context),
            const Divider(height: 1, color: TokC.divider),
            Expanded(child: _list(context)),
          ],
        ),
      ),
    );
  }

  Widget _searchBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: TextField(
        onChanged: (v) => setState(() => _query = v.trim()),
        style: const TextStyle(color: kTextMain, fontSize: 13),
        decoration: dec('搜索工程名/备注（跨文件夹）').copyWith(
          prefixIcon:
              const Icon(Icons.search, color: kTextSub, size: 18),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      child: Row(
        children: [
          const Expanded(
            child: Text('收藏夹',
                style: TextStyle(
                    color: kTextMain,
                    fontSize: 17,
                    fontWeight: FontWeight.bold)),
          ),
          TextButton.icon(
            onPressed: () async {
              // 导出全部收藏 KML
              final all = <dynamic>[];
              for (final m in st.collections) {
                all.addAll(await st.store.loadCollection(m.id));
              }
              if (all.isEmpty) {
                toast(context, '还没有任何收藏');
                return;
              }
              try {
                final f = await KmlExporter.export(
                    '滑洲云图全部收藏', all.cast(), KmlExporter.all);
                if (context.mounted) shareFile(context, f);
              } catch (e) {
                if (context.mounted) toast(context, '导出失败：$e');
              }
            },
            icon: const Icon(Icons.share, size: 16, color: kAccent),
            label: const Text('全部KML',
                style: TextStyle(color: kAccent, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _folderChips(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final f in st.folders)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GestureDetector(
                onLongPress: f.id.isEmpty
                    ? null
                    : () => _folderMenu(context, f),
                child: ChoiceChip(
                  label: Text(f.name,
                      style: TextStyle(
                          fontSize: 12,
                          color: st.folderId == f.id
                              ? Colors.black
                              : kTextMain)),
                  selected: st.folderId == f.id,
                  selectedColor: kAccent,
                  backgroundColor: TokC.field,
                  side: BorderSide.none,
                  onSelected: (_) {
                    st.folderId = f.id;
                    st.refreshUi();
                  },
                ),
              ),
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '新建文件夹',
            onPressed: () => _addFolder(context),
            icon: const Icon(Icons.create_new_folder_outlined,
                color: kAccent, size: 20),
          ),
        ],
      ),
    );
  }

  Future<void> _addFolder(BuildContext context) async {
    final ctl = TextEditingController();
    await showDarkDialog(context,
        title: '新建文件夹',
        content: TextField(
            controller: ctl,
            autofocus: true,
            style: const TextStyle(color: kTextMain),
            decoration: dec('文件夹名称')),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
          darkTextBtn('创建', () async {
            await st.store.addFolder(ctl.text.trim());
            Navigator.pop(context);
            await st.refreshCollections();
          }),
        ]);
  }

  Future<void> _folderMenu(BuildContext context, Folder f) async {
    await showDarkDialog(context, title: '文件夹：${f.name}', actions: [
      darkTextBtn('重命名', () async {
        Navigator.pop(context);
        final ctl = TextEditingController(text: f.name);
        await showDarkDialog(context,
            title: '重命名文件夹',
            content: TextField(
                controller: ctl,
                autofocus: true,
                style: const TextStyle(color: kTextMain),
                decoration: dec('文件夹名称')),
            actions: [
              darkTextBtn('取消', () => Navigator.pop(context),
                  color: kTextSub),
              darkTextBtn('保存', () async {
                await st.store.renameFolder(
                    f.id, ctl.text.trim().isEmpty ? f.name : ctl.text.trim());
                Navigator.pop(context);
                await st.refreshCollections();
              }),
            ]);
      }),
      darkTextBtn('删除', () async {
        Navigator.pop(context);
        final (nF, nP) = await st.store.deleteFolder(f.id);
        if (st.folderId == f.id) st.folderId = '';
        await st.refreshCollections();
        if (context.mounted) {
          toast(context,
              '已删除 $nF 个文件夹${nP > 0 ? '（$nP 个工程移到上级）' : ''}');
        }
      }, color: TokC.danger),
      darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
    ]);
  }

  Widget _list(BuildContext context) {
    final q = _query.toLowerCase();
    final items = st.collections.where((m) {
      // 搜索模式：跨文件夹按名称/备注匹配
      if (q.isNotEmpty) {
        return m.name.toLowerCase().contains(q) ||
            m.desc.toLowerCase().contains(q);
      }
      if (st.folderId.isEmpty) return m.folder.isEmpty;
      return m.folder == st.folderId;
    }).toList();

    if (items.isEmpty) {
      if (q.isNotEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('没有匹配「$_query」的工程。\n搜索范围：全部文件夹的名称与备注。',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: kTextSub, fontSize: 13, height: 1.6)),
          ),
        );
      }
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('本文件夹暂无收藏。\n画好杆路后点「保存收藏」即可归档。',
              textAlign: TextAlign.center,
              style: TextStyle(color: kTextSub, fontSize: 13, height: 1.6)),
        ),
      );
    }

    return Column(
      children: [
        // 文件夹级批量显隐（奥维图层管理式）：一键显隐当前文件夹全部工程
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
          child: Row(children: [
            Text('共 ${items.length} 项',
                style: const TextStyle(color: kTextSub, fontSize: 11)),
            const Spacer(),
            TextButton(
              onPressed: () =>
                  st.setVisibleBulk(items.map((m) => m.id), true),
              child: const Text('全部显示',
                  style: TextStyle(color: kAccent, fontSize: 12)),
            ),
            TextButton(
              onPressed: () =>
                  st.setVisibleBulk(items.map((m) => m.id), false),
              child: const Text('全部隐藏',
                  style: TextStyle(color: kTextSub, fontSize: 12)),
            ),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: items.length,
            itemBuilder: (ctx, i) => _item(ctx, items[i]),
          ),
        ),
      ],
    );
  }

  Widget _item(BuildContext context, CollectionMeta m) {
    final visible = st.visibleCids.contains(m.id);
    // 同步状态取自可空快照（未接入同步 → 仅本地）。
    final sync = context.watch<SyncController?>();
    final status = sync?.statusFor(m.id) ?? SyncStatus.localOnly;
    final kindTag = m.kind == 'track'
        ? '轨迹'
        : m.kind == 'data'
            ? '数据'
            : m.editMode == 'completion'
                ? '竣工'
                : '设计';
    final tagColor = m.editMode == 'completion'
        ? TokC.warn
        : m.kind == 'track'
            ? const Color(0xFFFFD54F)
            : const Color(0xFF81C784);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: TokC.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: visible ? kAccent.withValues(alpha: 0.6) : Colors.transparent),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () async {
          Navigator.pop(context); // 关抽屉
          await st.openCollection(m);
          if (context.mounted) toast(context, '已打开「${m.name}」，可继续编辑');
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.name.isEmpty ? '未命名' : m.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: kTextMain, fontSize: 14)),
                    const SizedBox(height: 2),
                    Row(children: [
                      _tag(kindTag, tagColor),
                      const SizedBox(width: 6),
                      Text('${m.count} 点',
                          style: const TextStyle(
                              color: kTextSub, fontSize: 11)),
                      const SizedBox(width: 6),
                      SyncBadge(status: status),
                      if (m.desc.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(m.desc,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: kTextSub, fontSize: 11)),
                        ),
                      ],
                    ]),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: visible ? '从地图隐藏' : '叠加显示到地图',
                onPressed: () => st.toggleVisible(m.id),
                icon: Icon(visible ? Icons.visibility : Icons.visibility_off,
                    color: visible ? kAccent : kTextSub, size: 20),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '拓扑连线',
                onPressed: () async {
                  Navigator.pop(context);
                  final ok = await st.startTopoLink(m);
                  if (context.mounted) {
                    toast(context,
                        ok ? '点起点箱体→点终点箱体进行连线' : '该收藏没有可连线的箱体节点');
                  }
                },
                icon: const Icon(Icons.account_tree_outlined,
                    color: Color(0xFFCE93D8), size: 20),
              ),
              PopupMenuButton<String>(
                tooltip: '更多操作',
                icon: const Icon(Icons.more_vert, color: kTextSub, size: 20),
                color: kPanelBg,
                onSelected: (v) => _onAction(context, m, v),
                itemBuilder: (ctx) => const [
                  PopupMenuItem(
                      value: 'sync_project',
                      child: _mi(Icons.cloud_sync, '同步该工程')),
                  PopupMenuItem(
                      value: 'history',
                      child: _mi(Icons.history, '历史版本')),
                  PopupMenuItem(value: 'export', child: _mi(Icons.share, '导出成果')),
                  PopupMenuItem(value: 'topo_png', child: _mi(Icons.image, '配线图 PNG')),
                  PopupMenuItem(
                      value: 'archive',
                      child: _mi(Icons.folder_zip_outlined, '竣工资料一键成册')),
                  PopupMenuItem(
                      value: 'import_boxes',
                      child: _mi(Icons.call_received, '导入箱体节点')),
                  PopupMenuItem(
                      value: 'diff_design',
                      child: _mi(Icons.compare_arrows, '竣工对比设计')),
                  PopupMenuItem(value: 'rename', child: _mi(Icons.edit, '重命名')),
                  PopupMenuItem(value: 'move', child: _mi(Icons.folder_open, '移动到文件夹')),
                  PopupMenuItem(value: 'style', child: _mi(Icons.palette, '线条样式')),
                  PopupMenuItem(value: 'desc', child: _mi(Icons.notes, '描述')),
                  PopupMenuItem(value: 'delete', child: _mi(Icons.delete_outline, '删除')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onAction(
      BuildContext context, CollectionMeta m, String action) async {
    switch (action) {
      case 'sync_project':
        final sync = context.read<SyncController?>();
        if (sync == null || !sync.configured) {
          if (context.mounted) {
            toast(context, '未配置云同步，请在「同步设置」里填入令牌');
          }
          return;
        }
        if (context.mounted) toast(context, '正在同步「${m.name}」…');
        await sync.syncProject(m.id);
        if (context.mounted) toast(context, '已同步「${m.name}」');
        break;
      case 'history':
        // 版本历史与恢复（T20）。未配置令牌时对话框内给中文提示，不崩。
        await showVersionHistoryDialog(
            context, context.read<SyncController?>(), m.id, m.name);
        break;
      case 'export':
        final ls = await st.store.loadCollection(m.id);
        if (context.mounted)
          showExportDialog(context, ls, m.name, segPrefix: st.segPrefix);
        break;
      case 'import_boxes':
        if (!context.mounted) return;
        _showImportBoxesDialog(context, m);
        break;
      case 'archive':
        if (!context.mounted) return;
        await _archiveBook(context, m);
        break;
      case 'diff_design':
        if (!context.mounted) return;
        showDesignDiffDialog(context, st, m);
        break;
      case 'topo_png':
        final ls = await st.store.loadCollection(m.id);
        try {
          final f = await TopoPngExporter.render(ls, m.name, 1400);
          if (context.mounted) shareFile(context, f);
        } catch (e) {
          if (context.mounted) toast(context, '$e');
        }
        break;
      case 'rename':
        final ctl = TextEditingController(text: m.name);
        if (!context.mounted) return;
        await showDarkDialog(context,
            title: '重命名',
            content: TextField(
                controller: ctl,
                autofocus: true,
                style: const TextStyle(color: kTextMain),
                decoration: dec('项目名称')),
            actions: [
              darkTextBtn('取消', () => Navigator.pop(context),
                  color: kTextSub),
              darkTextBtn('保存', () async {
                await st.store.renameCollection(m.id, ctl.text.trim());
                Navigator.pop(context);
                await st.refreshCollections();
              }),
            ]);
        break;
      case 'move':
        if (!context.mounted) return;
        final folders = st.folders;
        await showDarkDialog(context, title: '移动到文件夹', actions: [
          for (final f in folders)
            darkTextBtn(f.name, () async {
              await st.store.moveCollection(m.id, f.id);
              Navigator.pop(context);
              await st.refreshCollections();
            }),
        ]);
        break;
      case 'style':
        if (!context.mounted) return;
        var color = m.color == 0 ? 0xFFFFC107 : m.color;
        var width = m.width <= 0 ? 3.0 : m.width;
        await showDarkDialog(context,
            title: '线条样式（仅显示）',
            content: StatefulBuilder(
              builder: (ctx, setSt) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(spacing: 8, children: [
                    for (final c in const [
                      0xFFFFC107, 0xFFE53935, 0xFF0288D1,
                      0xFF2E7D32, 0xFFCE93D8, 0xFFFFFFFF,
                    ])
                      GestureDetector(
                        onTap: () => setSt(() => color = c),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: Color(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: color == c
                                    ? Colors.white
                                    : Colors.transparent,
                                width: 2.5),
                          ),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    const Text('线宽 ',
                        style: TextStyle(color: kTextMain, fontSize: 13)),
                    Expanded(
                      child: Slider(
                        value: width,
                        min: 1,
                        max: 8,
                        divisions: 14,
                        activeColor: kAccent,
                        label: width.toStringAsFixed(1),
                        onChanged: (v) => setSt(() => width = v),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
            actions: [
              darkTextBtn('取消', () => Navigator.pop(context),
                  color: kTextSub),
              darkTextBtn('应用', () async {
                await st.store.setCollectionStyle(m.id, color, width);
                if (st.visibleCids.contains(m.id)) {
                  final ls = await st.store.loadCollection(m.id);
                  for (final l in ls) {
                    l.styleColor = color;
                    l.styleWidth = width;
                  }
                  st.overlayLabels[m.id] = ls;
                }
                Navigator.pop(context);
                await st.refreshCollections();
                st.refreshUi();
              }),
            ]);
        break;
      case 'desc':
        if (!context.mounted) return;
        final ctl = TextEditingController(text: m.desc);
        await showDarkDialog(context,
            title: '项目描述',
            content: TextField(
                controller: ctl,
                autofocus: true,
                maxLines: 3,
                style: const TextStyle(color: kTextMain, fontSize: 13),
                decoration: dec('如：XX 路 48 芯改造')),
            actions: [
              darkTextBtn('取消', () => Navigator.pop(context),
                  color: kTextSub),
              darkTextBtn('保存', () async {
                await st.store.setCollectionDesc(m.id, ctl.text.trim());
                Navigator.pop(context);
                await st.refreshCollections();
              }),
            ]);
        break;
      case 'delete':
        if (!context.mounted) return;
        await showDarkDialog(context,
            title: '删除收藏',
            content: Text('确定删除「${m.name}」（${m.count} 点）？',
                style: const TextStyle(color: kTextMain, fontSize: 13)),
            actions: [
              darkTextBtn('取消', () => Navigator.pop(context),
                  color: kTextSub),
              darkTextBtn('删除', () async {
                // 统一入口：清理可见集合 + 刷新 + 通知同步器（服务端软删除）。
                await st.deleteCollection(m.id);
                Navigator.pop(context);
                st.refreshUi();
              }, color: TokC.danger),
            ]);
        break;
    }
  }

  /// 导入箱体节点：选择来源工程 → 把其光交/分光箱/分纤盒/ONU/机房/基站/引上并入本工程
  Future<void> _showImportBoxesDialog(
      BuildContext context, CollectionMeta target) async {
    final sources =
        st.collections.where((c) => c.id != target.id).toList();
    if (sources.isEmpty) {
      if (context.mounted) toast(context, '没有其他工程可导入');
      return;
    }
    // 统计每个来源工程的箱体数量，列表项显示"其中箱体 M 个"
    final boxCounts = <String, int>{};
    for (final c in sources) {
      try {
        final ls = await st.store.loadCollection(c.id);
        boxCounts[c.id] = ls.where((l) => l.type.isTopoLinkable).length;
      } catch (_) {
        boxCounts[c.id] = 0;
      }
    }
    if (!context.mounted) return;
    await showDarkDialog(
      context,
      title: '导入箱体到「${target.name}」',
      content: SizedBox(
        width: double.maxFinite,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
              '选择来源工程，将其中的光交箱/分纤盒/分光器箱/ONU箱/机房/基站/引上节点并入当前工程（同位置同类型自动去重）',
              style: TextStyle(color: kTextSub, fontSize: 12)),
          const SizedBox(height: 10),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in sources)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.call_received,
                        color: kAccent, size: 20),
                    title: Text(c.name.isEmpty ? '未命名' : c.name,
                        style: const TextStyle(
                            color: kTextMain, fontSize: 13.5)),
                    subtitle: Text(
                        '${c.count} 点 · 其中箱体 ${boxCounts[c.id] ?? 0} 个',
                        style: const TextStyle(
                            color: kTextSub, fontSize: 11)),
                       onTap: () async {
                           Navigator.pop(context);
                           bool overwrite = false;
                           final result = await showDialog<bool>(
                             context: context,
                             builder: (ctx) => StatefulBuilder(
                               builder: (ctx, setState) => AlertDialog(
                                 title: const Text('导入箱体节点'),
                                 content: Column(
                                   mainAxisSize: MainAxisSize.min,
                                   children: [
                                     const Text('是否覆盖目标工程中同位置同类型的箱体节点的属性？'),
                                     CheckboxListTile(
                                       title: const Text('覆盖已有同位置同类型的属性'),
                                       value: overwrite,
                                       onChanged: (bool? value) {
                                         setState(() {
                                           overwrite = value ?? false;
                                         });
                                       },
                                       controlAffinity: ListTileControlAffinity.leading,
                                     ),
                                   ],
                                 ),
                                 actions: [
                                   TextButton(
                                     onPressed: () => Navigator.of(ctx).pop(),
                                     child: const Text('取消'),
                                   ),
                                   TextButton(
                                     onPressed: () => Navigator.of(ctx).pop(overwrite),
                                     child: const Text('确定'),
                                   ),
                                 ],
                               ),
                             ),
                           );
                           if (result == null) return; // 取消/关闭：不导入
                           overwrite = result;
                           final n = await st.importBoxesToCollection(
                               target.id, c.id, overwriteSame: overwrite);
                           if (context.mounted) {
                             toast(context,
                                 n == 0 ? '没有可导入的箱体节点（或已全部导入）' : '已导入 $n 个箱体节点');
                           }
                         },
                  ),      // ListTile
                ]),       // ListView children + ListView
              ),          // Flexible
            ],            // Column children
          ),              // Column
        ),                // SizedBox
      actions: [
        darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      ],
    );
  }

  /// 竣工资料一键成册：把本工程的 4 项成果打成一个 ZIP（缺项自动跳过）。
  Future<void> _archiveBook(BuildContext context, CollectionMeta m) async {
    final ls = await st.store.loadCollection(m.id);
    if (!context.mounted) return;
    if (ls.isEmpty) {
      toast(context, '该工程没有点位');
      return;
    }
    toast(context, '正在生成竣工资料成册…');
    try {
      final r = await ArchiveBookExporter.export(
        name: m.name.isEmpty ? '未命名项目' : m.name,
        labels: ls,
        pointCount: m.count,
        editMode: m.editMode,
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

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: TextStyle(color: color, fontSize: 10)),
      );
}

class _mi extends StatelessWidget {
  final IconData icon;
  final String text;
  const _mi(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 16, color: kTextSub),
      const SizedBox(width: 10),
      Text(text, style: const TextStyle(color: kTextMain, fontSize: 13)),
    ]);
  }
}
