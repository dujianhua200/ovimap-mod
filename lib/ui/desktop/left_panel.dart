import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/map_label.dart';
import '../../services/store.dart';
import '../../state/app_state.dart';
import '../../sync/sync_controller.dart';
import '../../sync/sync_models.dart';
import '../design_tokens.dart';
import '../dialogs.dart';
import '../export_center.dart';
import '../sync/sync_panel.dart';
import 'batch_export.dart';

/// 桌面左栏（架构文档 §3.2 / T09）。
///
/// 内容自上而下：标题 + 新建工程 → 搜索框 → 文件夹树 → 工程列表（每项带
/// **同步徽标** ✓/↑/⚠/●；支持 **Ctrl/Shift 多选** → 右键「批量导出 DXF」）→
/// **本工程段落 / 点位表**（可就地改段标，见 [LeftPanel.onLocate]）→
/// 底部「导入区」（点击选文件 / 应用内拖拽 → `.ovimap`/`.geojson` 分派，T21）。
///
/// ## 为什么左栏要有「段落表」
///
/// 线路设计人员最高频的修改动作是「改某一档的标注」——现场量了 42.5 米，要把图上
/// 那一段改成「埋42.5」。原先只能在图上点中该点、再去右栏属性面板找「本段标注」，
/// 一档一档来；几十档的线路就是几十次「地图找点 → 点中 → 右栏改」。左栏段落表把
/// 全线的段按顺序铺出来，**在哪一档改哪一档**，还能一眼看到整条线路的段距分布。
class LeftPanel extends StatefulWidget {
  const LeftPanel({
    super.key,
    required this.st,
    this.searchFocus,
    required this.onNewProject,
    this.onLocate,
    this.onClose,
  });

  final AppState st;
  final FocusNode? searchFocus;

  /// 新建工程（清空草稿进入空白编辑态）。
  final VoidCallback onNewProject;

  /// 点击段落/点位行 → 外壳把地图移过去并选中该点（相机归壳，左栏不持 `MapController`）。
  final void Function(MapLabel l)? onLocate;

  /// 面板以叠加方式悬浮在地图上时，标题栏出现「收起」按钮（见 workspace_page）。
  final VoidCallback? onClose;

  @override
  State<LeftPanel> createState() => _LeftPanelState();
}

class _LeftPanelState extends State<LeftPanel> {
  AppState get st => widget.st;
  String _query = '';

  /// 多选集合（Ctrl/Shift 点击维护）；普通点击会清空后打开工程。
  final Set<String> _selected = <String>{};

  /// Shift 范围选择的锚点（上一次 Ctrl/普通点击的工程 id）。
  String _anchor = '';

  /// 正在拖拽的条目组（多选拖拽：拖一个带整组）；空 = 单拖。
  Set<String> _dragGroup = <String>{};

  @override
  Widget build(BuildContext context) {
    // Delete / Backspace 删除所选（奥维同款）；批量选择必须**看得见**——
    // 工具条按钮 + 右键菜单 + 快捷键三条路都给（用户反馈只靠 Ctrl 找不到）。
    // ⚠️ 面板必须监听 AppState：拖拽/移动/删除改的是 st 里的数据，
    // 不监听就**不重绘**——「拖进去了但打不开 / 标记还在外面」的根因（v3.9.0）。
    // 地图拖动时 st 也可能 notify，面板行数少，全量重建开销可忽略。
    return ListenableBuilder(
      listenable: st,
      builder: (ctx, _) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.delete): _deleteSelected,
          const SingleActivator(LogicalKeyboardKey.backspace): _deleteSelected,
          const SingleActivator(LogicalKeyboardKey.keyA, control: true):
              _selectAll,
        },
        child: Focus(
          autofocus: true, // 让 Delete/Ctrl+A 快捷键真正生效（此前无焦点不触发）
          child: Container(
            color: TokC.panelSolid,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context),
                _searchBar(),
                _selectBar(),
                const Divider(height: 1, color: TokC.divider),
                Expanded(child: _favoritesTree(context)),
                const Divider(height: 1, color: TokC.divider),
                _dropZone(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 条目工具条（奥维式）：全选 / 取消 / 删除所选(N) / 新建文件夹。
  Widget _selectBar() {
    final n = _selected.length;
    Widget mini(IconData icon, String tip, VoidCallback onTap,
        {Color color = kTextSub, bool enabled = true}) {
      return Tooltip(
        message: tip,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Icon(icon,
                size: 17, color: enabled ? color : kTextHint.withValues(alpha: 0.5)),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 6, 4),
      child: Row(children: [
        Text(n > 0 ? '已选 $n 项' : '全部条目',
            style: TextStyle(
                color: n > 0 ? kAccent : kTextSub,
                fontSize: TokFs.caption,
                fontWeight: n > 0 ? FontWeight.w600 : FontWeight.normal)),
        const Spacer(),
        mini(Icons.select_all, '全选（Ctrl+A）', _selectAll),
        mini(Icons.deselect, '取消选择', () => setState(() => _selected.clear()),
            enabled: n > 0),
        mini(Icons.ios_share, '导出所选工程（DXF）', _batchExportSelected,
            color: kAccent, enabled: n > 0),
        mini(Icons.delete_outline, '删除所选（Delete）', _deleteSelected,
            color: kDanger, enabled: n > 0),
        mini(Icons.create_new_folder_outlined, '新建文件夹（根目录）',
            () => _addFolder(parentId: ''),
            color: kAccent),
      ]),
    );
  }

  /// 收藏夹树（**唯一视图**，奥维口径）：根 → 文件夹 → 工程 → 点，层层缩进。
  /// 树里所有行都可选中（单击/Ctrl 多选/Shift 范围选），配合工具条批量删。
  Widget _favoritesTree(BuildContext context) {
    final rows = <Widget>[];
    if (_query.isNotEmpty) {
      rows.addAll(_searchRows(context));
      if (rows.isEmpty) {
        rows.add(Padding(
          padding: const EdgeInsets.all(18),
          child: Text('没有匹配「$_query」的条目',
              textAlign: TextAlign.center,
              style: const TextStyle(color: kTextSub, fontSize: TokFs.body)),
        ));
      }
    } else {
      rows.add(_rootRow());
      rows.addAll(_levelRows('', 1));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: rows,
    );
  }

  /// 某一层的全部条目：子文件夹 → 工程 → （标记收藏的）点。
  List<Widget> _levelRows(String fid, int depth) {
    final out = <Widget>[];
    for (final f in st.folders) {
      if (f.id.isEmpty || f.parentId != fid) continue;
      out.add(_folderRow(f, depth));
      if (!_collapsed.contains(f.id)) out.addAll(_levelRows(f.id, depth + 1));
    }
    for (final m in st.collections) {
      if (m.folder != fid) continue;
      final isMark = m.kind == 'mark' || m.name == '标记';
      if (isMark) {
        // 标记收藏：直接列出它的点（奥维截图口径：点挂在文件夹下），
        // 收藏本身不单独占一行。
        for (final l in (st.overlayLabels[m.id] ?? const <MapLabel>[])) {
          out.add(_markRow(m.id, l, depth));
        }
      } else {
        out.add(_item(context, m, depth));
      }
    }
    return out;
  }

  /// 搜索：跨全库平铺匹配的工程与标记点（带所属文件夹提示）。
  List<Widget> _searchRows(BuildContext context) {
    final q = _query.toLowerCase();
    final out = <Widget>[];
    for (final m in st.collections) {
      if (m.kind != 'mark' && (m.name.toLowerCase().contains(q) || m.desc.toLowerCase().contains(q))) {
        out.add(_item(context, m, 0));
      }
    }
    for (final m in st.collections) {
      if (!(m.kind == 'mark' || m.name == '标记')) continue;
      for (final l in (st.overlayLabels[m.id] ?? const <MapLabel>[])) {
        if (l.name.toLowerCase().contains(q) || l.note.toLowerCase().contains(q)) {
          out.add(_markRow(m.id, l, 0));
        }
      }
    }
    return out;
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
      child: Row(
        children: [
          const Icon(Icons.bookmarks, size: 18, color: kAccent),
          const SizedBox(width: 6),
          const Expanded(
            child: Text('收藏夹',
                style: TextStyle(
                    color: kTextMain,
                    fontSize: TokFs.heading,
                    fontWeight: FontWeight.bold)),
          ),
          // 新建工程入口（v3.4.0 改轨道时曾丢失，用户点名要回来）。
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '新建工程',
            onPressed: widget.onNewProject,
            icon: const Icon(Icons.note_add, color: kAccent, size: 20),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '新建文件夹（建在收藏夹根目录）',
            onPressed: () => _addFolder(parentId: ''),
            icon: const Icon(Icons.create_new_folder_outlined,
                color: kAccent, size: 20),
          ),
          if (widget.onClose != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '收起',
              onPressed: widget.onClose,
              icon: const Icon(Icons.close, color: kTextSub, size: 20),
            ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: TextField(
        focusNode: widget.searchFocus,
        onChanged: (v) => setState(() => _query = v.trim()),
        style: const TextStyle(color: kTextMain, fontSize: TokFs.body),
        decoration: dec('搜索工程名 / 标记名 / 备注（跨文件夹）').copyWith(
          prefixIcon: const Icon(Icons.search, color: kTextSub, size: 18),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }

  // ---- 收藏夹树（奥维桌面版样式） ----
  //
  // 用户给了奥维截图定版：**整树平铺**——根「收藏夹[n]」+ 各级文件夹缩进排列，
  // 每行 +/− 折叠、黄色文件夹图标、名称后 [工程数]；点名称选中该层，下方
  // 工程列表随之过滤；搜索时跨全库。v3.4 的悬浮叠加与逐级钻入按用户截图
  // 口径废弃（deletion over addition）。

  /// 当前选中的文件夹（'' = 根目录）；工程列表与保存对话框默认层都跟随它。
  String _selFolder = '';

  /// 被手动收起（−）的文件夹 id 集；'' 代表根。**未记录 = 展开**，
  /// 新建的文件夹天然展开，不用逐个同步。
  final Set<String> _collapsed = <String>{};

  /// 根行「收藏夹[n]」：选中 = 看全部根目录工程；有顶级文件夹时可折叠。
  Widget _rootRow() {
    final hasKids = st.folders.any((f) => f.id.isNotEmpty && f.parentId.isEmpty);
    return _treeRow(
      depth: 0,
      hasKids: hasKids,
      expanded: !_collapsed.contains(''),
      onToggle: hasKids
          ? () => setState(() {
                _collapsed.contains('') ? _collapsed.remove('') : _collapsed.add('');
              })
          : null,
      icon: Icons.bookmarks,
      iconColor: kAccent,
      name: '收藏夹',
      count: st.collections.where((m) => m.kind != 'mark').length,
      selected: _selFolder.isEmpty,
      onTap: () => _selectFolder(''),
      dropTargetId: '',
    );
  }

  void _selectFolder(String fid) {
    setState(() => _selFolder = fid);
    st.folderId = fid; // 保存对话框「所属文件夹」默认落这层
    st.refreshUi();
  }

  /// 树行通用骨架：[+/-] 图标 名称[n]；右键出文件夹菜单。
  Widget _treeRow({
    required int depth,
    required bool hasKids,
    required bool expanded,
    VoidCallback? onToggle,
    required IconData icon,
    required Color iconColor,
    required String name,
    required int count,
    required bool selected,
    VoidCallback? onTap,
    void Function(Offset pos)? onSecondary,
    String? dropTargetId,
    Folder? dragFolder,
  }) {
    Widget row = InkWell(
      onTap: onTap,
      onSecondaryTapUp:
          onSecondary == null ? null : (d) => onSecondary(d.globalPosition),
      onLongPress: onSecondary == null
          ? null
          : () {
              final box = context.findRenderObject() as RenderBox?;
              onSecondary.call(box != null &&
                      box.localToGlobal(Offset.zero).dy >= 0
                  ? box.localToGlobal(const Offset(80, 40))
                  : Offset.zero);
            },
      child: Container(
        height: 30,
        padding: EdgeInsets.only(left: 8.0 + depth * 16.0, right: 10),
        color: selected ? kAccent.withValues(alpha: 0.14) : null,
        child: Row(children: [
          if (hasKids)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
                child: Icon(expanded ? Icons.remove : Icons.add,
                    size: 13, color: kTextSub),
              ),
            )
          else
            const SizedBox(width: 23),
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 5),
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: selected ? kAccent : kTextMain,
                    fontSize: TokFs.body,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal)),
          ),
          Text('[$count]',
              style:
                  const TextStyle(color: kTextHint, fontSize: TokFs.micro)),
        ]),
      ),
    );
    // 可拖拽（用户指定：收藏夹下所有东西都能拖进文件夹——文件夹/工程/标记）。
    final dragF = dragFolder;
    if (dragF != null && dragF.id.isNotEmpty) {
      final f = dragF;
      row = Draggable<Folder>(
        data: f,
        feedback: Material(
          color: TokC.card,
          elevation: 4,
          borderRadius: BorderRadius.circular(TokR.s),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(f.name,
                style:
                    const TextStyle(color: kTextMain, fontSize: TokFs.small)),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: row),
        child: row,
      );
    }
    if (dropTargetId == null) return row;
    // 拖放目标（用户指定：收藏夹下所有东西都可拖进文件夹——文件夹/工程/标记都收）。
    return DragTarget<Object>(
      onWillAcceptWithDetails: (d) {
        final data = d.data;
        if (data is CollectionMeta) return data.folder != dropTargetId;
        if (data is MapLabel) return true;
        if (data is Folder) {
          if (data.id == dropTargetId) return false;
          // 防止拖进自己的后代（成环）。
          var p = dropTargetId;
          final seen = <String>{};
          while (p.isNotEmpty && seen.add(p)) {
            if (p == data.id) return false;
            final hit = st.folders.where((e) => e.id == p).toList();
            p = hit.isEmpty ? '' : hit.first.parentId;
          }
          return data.parentId != dropTargetId;
        }
        return false;
      },
      onAcceptWithDetails: (d) {
        final data = d.data;
        if (data is CollectionMeta) {
          if (_dragGroup.contains(data.id) && _dragGroup.length > 1) {
            _moveGroupToFolder(_dragGroup, dropTargetId);
          } else {
            _moveToFolder(data, dropTargetId);
          }
        } else if (data is MapLabel) {
          if (_dragGroup.contains(data.id) && _dragGroup.length > 1) {
            _moveGroupToFolder(_dragGroup, dropTargetId);
          } else {
            _moveMarkInto(data, dropTargetId);
          }
        } else if (data is Folder) {
          _moveFolderInto(data, dropTargetId);
        }
      },
      builder: (ctx, cand, _) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(TokR.s),
          border: cand.isNotEmpty
              ? Border.all(color: kAccent, width: 1.5)
              : null,
        ),
        child: row,
      ),
    );
  }

  /// 多选拖拽：把整组（工程 + 标记）一起移入目标文件夹。
  Future<void> _moveGroupToFolder(Set<String> ids, String fid) async {
    var nP = 0, nM = 0;
    for (final m in st.collections.where((c) => ids.contains(c.id))) {
      await st.store.moveCollection(m.id, fid);
      nP++;
    }
    for (final e in Map.of(st.overlayLabels).entries) {
      for (final l in List.of(e.value)) {
        if (!ids.contains(l.id)) continue;
        final meta = st.collections.where((c) => c.id == e.key).toList();
        if (meta.isNotEmpty && meta.first.folder == fid) continue; // 同层跳过
        await st.moveMarkToFolder(e.key, l, fid);
        nM++;
      }
    }
    setState(() => _selected.clear());
    if (mounted) {
      toast(context, '已移动 $nP 个工程、$nM 个标记到'
          '「${fid.isEmpty ? '收藏夹根目录' : _folderName(fid)}」');
    }
  }

  /// 把拖来的文件夹移入目标文件夹（拖拽路径；防成环在 DragTarget 与 store 双层校验）。
  Future<void> _moveFolderInto(Folder f, String fid) async {
    await st.store.setFolderParent(f.id, fid);
    await st.refreshCollections();
    if (mounted) {
      toast(context, '已把「${f.name}」移入「${fid.isEmpty ? '收藏夹根目录' : _folderName(fid)}」');
    }
  }

  /// 把拖来的标记点并入目标层的「标记」收藏（拖拽路径，等价于菜单「移动」）。
  Future<void> _moveMarkInto(MapLabel l, String fid) async {
    // 找到该标记当前所属的收藏。
    String fromCid = '';
    for (final e in st.overlayLabels.entries) {
      if (e.value.any((x) => x.id == l.id)) {
        fromCid = e.key;
        break;
      }
    }
    if (fromCid.isEmpty) return;
    final meta = st.collections.where((m) => m.id == fromCid).toList();
    if (meta.isNotEmpty && meta.first.folder == fid) return; // 同层无需移动
    await st.moveMarkToFolder(fromCid, l, fid);
    if (mounted) {
      toast(context, '已移入「${fid.isEmpty ? '收藏夹根目录' : _folderName(fid)}」');
    }
  }

  /// 把工程 [m] 移入文件夹 [fid]（'' = 根目录）。
  Future<void> _moveToFolder(CollectionMeta m, String fid) async {
    if (m.folder == fid) return;
    await st.store.moveCollection(m.id, fid);
    await st.refreshCollections();
    if (mounted) {
      toast(context, '已移入「${fid.isEmpty ? '收藏夹根目录' : _folderName(fid)}」');
    }
  }

  /// 文件夹行：+/− 折叠、黄色文件夹图标（奥维同款观感）、名称[工程数]；
  /// 点名称选中（下方列表过滤到该层），右键出操作菜单。
  Widget _folderRow(Folder f, int depth) {
    final count = st.collections
        .where((m) => m.folder == f.id && m.kind != 'mark')
        .length;
    final hasKids =
        st.folders.any((c) => c.id.isNotEmpty && c.parentId == f.id);
    return _treeRow(
      depth: depth,
      hasKids: hasKids,
      expanded: !_collapsed.contains(f.id),
      onToggle: () => setState(() {
        _collapsed.contains(f.id)
            ? _collapsed.remove(f.id)
            : _collapsed.add(f.id);
      }),
      icon: Icons.folder,
      iconColor: const Color(0xFFE6A23C),
      name: f.name,
      count: count,
      selected: _selFolder == f.id || _selected.contains(f.id),
      onTap: () {
        final kb = HardwareKeyboard.instance;
        if (kb.isControlPressed || kb.isMetaPressed) {
          setState(() {
            if (!_selected.remove(f.id)) _selected.add(f.id);
            _anchor = f.id;
          });
          return;
        }
        if (kb.isShiftPressed && _anchor.isNotEmpty) {
          _selectRangeTo(f.id);
          return;
        }
        setState(() {
          _selected.clear();
          _anchor = f.id;
          _collapsed.remove(f.id); // 单击即展开（奥维手感）
        });
        _selectFolder(f.id);
      },
      onSecondary: (pos) => _showFolderMenu(f, pos),
      dropTargetId: f.id,
      dragFolder: f,
    );
  }

  /// 标记点行（树内，奥维式）：图钉 + 名字 + 备注，点击**只定位**（不弹窗），
  /// 右键出属性/移动/删除菜单；可拖拽、可选中。
  Widget _markRow(String cid, MapLabel l, int depth) {
    final selected = _selected.contains(l.id);
    final nm = l.name.trim().isEmpty ? l.type.name : l.name.trim();
    final note = l.note.trim();
    return Draggable<MapLabel>(
      data: l,
      onDragStarted: () {
        if (_selected.contains(l.id) && _selected.length > 1) {
          _dragGroup = Set.of(_selected);
        } else {
          _dragGroup = {l.id};
        }
      },
      feedback: Material(
        color: TokC.card,
        elevation: 4,
        borderRadius: BorderRadius.circular(TokR.s),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(nm,
              style:
                  const TextStyle(color: kTextMain, fontSize: TokFs.small)),
        ),
      ),
      childWhenDragging: Opacity(
          opacity: 0.35,
          child: _markRowBody(cid, l, nm, note, selected, depth)),
      child: _markRowBody(cid, l, nm, note, selected, depth),
    );
  }

  Widget _markRowBody(String cid, MapLabel l, String nm, String note,
      bool selected, int depth) {
    return InkWell(
      onTap: () {
        // 点击标记只定位，不弹窗；属性走右键。
        final kb = HardwareKeyboard.instance;
        if (kb.isControlPressed || kb.isMetaPressed) {
          setState(() {
            if (!_selected.remove(l.id)) _selected.add(l.id);
            _anchor = l.id;
          });
          return;
        }
        if (kb.isShiftPressed && _anchor.isNotEmpty) {
          _selectRangeTo(l.id);
          return;
        }
        if (_selected.isNotEmpty) setState(() => _selected.clear());
        _anchor = l.id;
        widget.onLocate?.call(l);
      },
      onSecondaryTapUp: (d) => _showMarkMenu(cid, l, d.globalPosition),
      child: Container(
        margin: EdgeInsets.only(
            left: 6.0 + depth * 16.0, right: 6, top: 2, bottom: 2),
        padding: const EdgeInsets.only(left: 8, right: 6),
        height: 32,
        decoration: BoxDecoration(
          color: selected ? kAccent.withValues(alpha: 0.18) : TokC.field,
          borderRadius: BorderRadius.circular(TokR.s),
          border: Border.all(
              color: selected ? kAccent : Colors.transparent, width: 1),
        ),
        child: Row(children: [
          Container(
            width: 16,
            height: 16,
            alignment: Alignment.center,
            decoration:
                BoxDecoration(color: l.type.color, shape: BoxShape.circle),
            child: Text(
                l.type.symbol.isNotEmpty
                    ? l.type.symbol
                    : (nm.isNotEmpty ? nm.substring(0, 1) : '·'),
                style: const TextStyle(
                    color: Colors.white, fontSize: 9, height: 1.0)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(nm,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: kTextMain, fontSize: TokFs.body)),
          ),
          if (note.isNotEmpty)
            Flexible(
              child: Text(note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: kTextHint, fontSize: TokFs.micro)),
            ),
          const SizedBox(width: 4),
          const Icon(Icons.my_location, size: 13, color: kTextHint),
        ]),
      ),
    );
  }

  /// 标记行的右键菜单（属性/移动到文件夹/删除）——用户指定右键改属性。
  Future<void> _showMarkMenu(String cid, MapLabel l, Offset pos) async {
    await _showMenuAt(pos, const [
      PopupMenuItem(value: 'props', height: 34, child: Text('查看 / 修改属性')),
      PopupMenuItem(value: 'move', height: 34, child: Text('移动到文件夹…')),
      PopupMenuItem(value: 'delete', height: 34, child: Text('删除标记')),
    ], (v) async {
      if (!mounted) return;
      final nm = l.name.trim().isEmpty ? l.type.name : l.name.trim();
      switch (v) {
        case 'props':
          await showLabelProperties(context, st, l, sourceCid: cid, title: nm);
          break;
        case 'move':
          await _moveMarkDialog(cid, l);
          break;
        case 'delete':
          await st.removeOverlayLabel(cid, l);
          if (mounted) toast(context, '已删除标记「$nm」');
          break;
      }
    });
  }

  /// 把标记移动到另一个文件夹（落到该层的「标记」收藏里）。
  Future<void> _moveMarkDialog(String cid, MapLabel l) async {
    var target = '';
    final folders = st.folders.where((f) => f.id.isNotEmpty).toList();
    await showDarkDialog(context,
        title: '移动标记「${l.name.trim().isEmpty ? l.type.name : l.name.trim()}」',
        content: StatefulBuilder(
          builder: (ctx, setSt) => DropdownButtonFormField<String>(
            value: target,
            dropdownColor: TokC.panelSolid,
            isExpanded: true,
            style: const TextStyle(color: kTextMain, fontSize: TokFs.body),
            decoration: dec('移动到…'),
            items: [
              const DropdownMenuItem(value: '', child: Text('根目录（收藏夹）')),
              for (final f in folders)
                DropdownMenuItem(value: f.id, child: Text(f.name)),
            ],
            onChanged: (v) => setSt(() => target = v ?? ''),
          ),
        ),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
          darkTextBtn('移动', () async {
            Navigator.pop(context);
            await st.moveMarkToFolder(cid, l, target);
            if (mounted) {
              toast(context, '已移动到「${target.isEmpty ? '收藏夹根目录' : _folderName(target)}」');
            }
          }, color: kGreen),
        ]);
  }

  /// 在指定屏幕位置弹菜单（右键 / 长按共用）。
  ///
  /// 用 `showMenu` 而不是对话框：奥维式的收藏夹操作是"右键哪一项就操作哪一项"，
  /// 弹模态框会打断"连着整理一排文件夹"的节奏。
  Future<void> _showMenuAt(
      Offset pos, List<PopupMenuEntry<String>> items,
      void Function(String) onSelected) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final sel = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
          Rect.fromPoints(pos, pos), Offset.zero & overlay.size),
      color: kPanelBg,
      items: items,
    );
    if (sel != null) onSelected(sel);
  }

  void _showFolderMenu(Folder f, Offset pos) {
    _showMenuAt(pos, [
      if (_selected.isNotEmpty)
        PopupMenuItem(
            value: 'del_sel',
            height: 34,
            child: Text('删除所选 ${_selected.length} 项',
                style: const TextStyle(color: kDanger))),
      if (_selected.isNotEmpty) const PopupMenuDivider(),
      const PopupMenuItem(
          value: 'sub', height: 34, child: Text('新建子文件夹')),
      const PopupMenuItem(
          value: 'save', height: 34, child: Text('把当前画布收藏到此')),
      const PopupMenuItem(value: 'rename', height: 34, child: Text('重命名')),
      const PopupMenuItem(value: 'delete', height: 34, child: Text('删除')),
    ], (v) async {
      switch (v) {
        case 'del_sel':
        await _deleteSelected();
        break;
      case 'sub':
          await _addFolder(parentId: f.id);
          break;
        case 'save':
          // 先把目标文件夹选上，保存对话框的"所属文件夹"即默认落在右键的这层。
          st.folderId = f.id;
          st.refreshUi();
          if (mounted) await showFinishDialog(context, st);
          break;
        case 'rename':
          await _renameFolder(f);
          break;
        case 'delete':
          await _confirmDeleteFolder(f);
          break;
      }
    });
  }

  /// 新建文件夹（修「新建一个出现 2 个」）。
  ///
  /// 旧实现的坑：`onSubmitted` 里 `created.complete(st.store.addFolder(...))`
  /// —— 回车后**对话框不关闭**；再按一次回车时，`complete` 的参数表达式
  /// 会先求值（第二个 `addFolder` 已发出去）才抛 StateError，两个并发写盘
  /// 竞态后文件夹就成了两个。现改为单一提交口 `submit` + `done` 闸门：
  /// 回车/按钮谁先来都只建一次，且回车立即关框。
  Future<void> _addFolder({String? parentId}) async {
    final ctl = TextEditingController();
    final parent = parentId ?? _selFolder;
    var done = false;
    Future<void> submit() async {
      if (done) return;
      done = true;
      Navigator.pop(context);
      final f = await st.store
          .addFolder(ctl.text.trim(), parent.isEmpty ? '' : parent);
      await st.refreshCollections();
      // 新文件夹就在当前层列表里可见（parent 即当前层），不用跳转。
      st.folderId = parent;
      st.refreshUi();
      if (mounted) toast(context, '已创建文件夹「${f.name}」');
    }

    await showDarkDialog(context,
        title: '新建文件夹',
        content: TextField(
            controller: ctl,
            autofocus: true,
            // 回车直接建并关框——"新建→命名→回车"是高频动作。
            onSubmitted: (_) => submit(),
            style: const TextStyle(color: kTextMain),
            decoration: dec(parent.isEmpty
                ? '文件夹名称（建在根目录）'
                : '文件夹名称（建在「${_folderName(parent)}」内）')),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
          darkTextBtn('创建', () => submit(), color: kGreen),
        ]);
  }

  /// 移动工程到目标文件夹：**下拉选择**（用户指定交互）。
  ///
  /// 候选 = 根目录 + 全部文件夹，按层级缩进；一次选择一次确认，不再把每个
  /// 文件夹摆成一个按钮（文件夹一多旧交互既放不下也看不清层级）。
  Future<void> _moveToFolderDialog(
      BuildContext context, CollectionMeta m) async {
    // 层级深度：用于下拉项缩进。
    int depthOf(Folder f) {
      var d = 0;
      var pid = f.parentId;
      while (pid.isNotEmpty) {
        final p = st.folders.where((e) => e.id == pid).toList();
        if (p.isEmpty) break;
        pid = p.first.parentId;
        d++;
      }
      return d;
    }

    var target = m.folder;
    var moved = false;
    await showDarkDialog(
      context,
      title: '移动「${m.name}」',
      content: StatefulBuilder(
        builder: (ctx, setSt) => DropdownButtonFormField<String>(
          value: target,
          dropdownColor: TokC.panelSolid,
          isExpanded: true,
          style: const TextStyle(color: kTextMain, fontSize: TokFs.body),
          decoration: dec('移动到…'),
          items: [
            const DropdownMenuItem(value: '', child: Text('根目录')),
            for (final f in st.folders)
              if (f.id != m.folder)
                DropdownMenuItem(
                    value: f.id,
                    child: Text('${'　' * depthOf(f)}${f.name}')),
          ],
          onChanged: (v) => setSt(() => target = v ?? ''),
        ),
      ),
      actions: [
        darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
        darkTextBtn('移动', () {
          moved = true;
          Navigator.pop(context);
        }, color: kGreen),
      ],
    );
    if (!moved) return;
    if (target == m.folder) return;
    await st.store.moveCollection(m.id, target);
    await st.refreshCollections();
    if (context.mounted) {
      toast(context, '已移动到${target.isEmpty ? '根目录' : '「${_folderName(target)}」'}');
    }
  }

  String _folderName(String fid) {
    for (final f in st.folders) {
      if (f.id == fid) return f.name;
    }
    return '根目录';
  }

  Future<void> _renameFolder(Folder f) async {
    final ctl = TextEditingController(text: f.name);
    await showDarkDialog(context,
        title: '重命名文件夹',
        content: TextField(
            controller: ctl,
            autofocus: true,
            onSubmitted: (_) => Navigator.pop(context),
            style: const TextStyle(color: kTextMain),
            decoration: dec('文件夹名称')),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
          darkTextBtn('保存', () async {
            await st.store.renameFolder(
                f.id, ctl.text.trim().isEmpty ? f.name : ctl.text.trim());
            Navigator.pop(context);
            await st.refreshCollections();
          }, color: kGreen),
        ]);
  }

  /// 删除文件夹：**级联删除整棵子树**（用户口径：删父文件夹连子文件夹一起删）。
  /// 工程数据不丢——子树内的工程上移到被删目录的父级；文案把数字说清。
  Future<void> _confirmDeleteFolder(Folder f) async {
    // 统计整棵子树：文件夹数 + 其中工程数。
    final subIds = <String>{f.id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final x in st.folders) {
        if (x.id.isNotEmpty && subIds.contains(x.parentId) && subIds.add(x.id)) {
          grew = true;
        }
      }
    }
    final nFolder = subIds.length;
    final nProj = st.collections.where((m) => subIds.contains(m.folder)).length;
    final extra = nFolder > 1 ? '及其内部的 ${nFolder - 1} 个子文件夹' : '';
    await showDarkDialog(context,
        title: '删除文件夹「${f.name}」',
        content: Text(
            '将删除「${f.name}」$extra'
            '${nProj > 0 ? '；其中 $nProj 个工程会移到上一级，不会被删除' : ''}。确定删除？',
            style: const TextStyle(color: kTextMain, fontSize: TokFs.body)),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
          darkTextBtn('删除', () async {
            Navigator.pop(context);
            final (nF, nP) = await st.store.deleteFolder(f.id);
            // 选中层若落在被删子树里，回到根。
            if (subIds.contains(_selFolder)) {
              _selFolder = '';
              st.folderId = '';
            }
            for (final id in subIds) {
              _collapsed.remove(id);
            }
            await st.refreshCollections();
            st.refreshUi();
            toast(context, '已删除 $nF 个文件夹'
                '${nP > 0 ? '（$nP 个工程已移到上一级）' : ''}');
          }, color: kDanger),
        ]);
  }

  // ---- 工程列表 ----

  /// 当前可见（受搜索/文件夹筛选）的工程列表——列表构建与 Shift 范围选择共用。
  List<CollectionMeta> _filteredItems() {
    final q = _query.toLowerCase();
    return st.collections.where((m) {
      // 标记收藏（kind=mark）的点已在树中以图钉行呈现，列表里不再重复列
      // 一张「标记」卡片（用户反馈：打点时下方老多出一份重复的）。
      if (m.kind == 'mark') return false;
      if (q.isNotEmpty) {
        return m.name.toLowerCase().contains(q) ||
            m.desc.toLowerCase().contains(q);
      }
      if (_selFolder.isEmpty) return m.folder.isEmpty;
      return m.folder == _selFolder;
    }).toList();
  }

  /// 选中集合对应的工程（按当前可见列表过滤掉已删除项）。
  /// 选中的标记点（cid, label）——批量删除要连标记一起处理。
  List<(String, MapLabel)> _selectedMarks() {
    final out = <(String, MapLabel)>[];
    for (final m in st.collections) {
      if (!(m.kind == 'mark' || m.name == '标记')) continue;
      for (final l in (st.overlayLabels[m.id] ?? const <MapLabel>[])) {
        if (_selected.contains(l.id)) out.add((m.id, l));
      }
    }
    return out;
  }

  /// 当前树的**可见行顺序**（Shift 范围选与全选都用它，保证「选的就是看到的」）。
  List<String> _visibleKeys() {
    final out = <String>[];
    void level(String fid) {
      for (final f in st.folders) {
        if (f.id.isEmpty || f.parentId != fid) continue;
        out.add(f.id);
        if (!_collapsed.contains(f.id)) level(f.id);
      }
      for (final m in st.collections) {
        if (m.folder != fid) continue;
        if (m.kind == 'mark' || m.name == '标记') {
          for (final l in (st.overlayLabels[m.id] ?? const <MapLabel>[])) {
            out.add(l.id);
          }
        } else {
          out.add(m.id);
        }
      }
    }

    level('');
    return out;
  }

  /// Shift 范围选：从锚点到当前行，整段加入选中集。
  void _selectRangeTo(String key) {
    final keys = _visibleKeys();
    final a = keys.indexOf(_anchor);
    final b = keys.indexOf(key);
    if (a < 0 || b < 0) {
      setState(() => _selected.add(key));
      return;
    }
    final lo = a < b ? a : b;
    final hi = a < b ? b : a;
    setState(() => _selected.addAll(keys.sublist(lo, hi + 1)));
  }

  /// 全选当前树里的所有条目（文件夹 + 工程 + 标记点）。
  void _selectAll() {
    setState(() => _selected
      ..clear()
      ..addAll(_visibleKeys()));
    toast(context, '已全选 ${_selected.length} 项，Delete 或工具条删除');
  }

  /// 删除所选：文件夹（级联）/ 工程 / 标记点 三类混合，一次确认全部处理。
  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) {
      toast(context, '先选条目（点击 / Ctrl 多选 / Ctrl+A 全选 / 拖框暂不支持）');
      return;
    }
    final folders = st.folders.where((f) => _selected.contains(f.id)).toList();
    // 文件夹级联会带走整棵子树：先把子树内的工程/标记从删除清单里剔除，
    // 否则后面对它们重复删除（甚至把别的层同 id 误删）。
    final doomed = <String>{};
    var grew = true;
    while (grew) {
      grew = false;
      for (final f in st.folders) {
        if (f.id.isEmpty) continue;
        if (doomed.contains(f.parentId) && doomed.add(f.id)) grew = true;
      }
    }
    final projects = st.collections
        .where((m) =>
            _selected.contains(m.id) &&
            !doomed.contains(m.folder))
        .toList();
    final marks = _selectedMarks()
        .where((pair) => !doomed
            .contains(st.collections
                .where((c) => c.id == pair.$1)
                .map((c) => c.folder)
                .toList()
                .first))
        .toList();
    final parts = <String>[
      if (folders.isNotEmpty) '${folders.length} 个文件夹（含子文件夹）',
      if (projects.isNotEmpty) '${projects.length} 个工程',
      if (marks.isNotEmpty) '${marks.length} 个标记',
    ];
    await showDarkDialog(context,
        title: '删除所选 ${_selected.length} 项',
        content: Text(
            '将删除：${parts.join('、')}。\n'
            '${projects.isEmpty && marks.isEmpty ? '' : '其中的点数据会随条目一起删除；'}'
            '确认后不可撤销。',
            style: const TextStyle(color: kTextMain, fontSize: TokFs.body)),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
          darkTextBtn('删除', () async {
            Navigator.pop(context);
            var nF = 0, nP = 0, nM = 0;
            for (final f in folders) {
              final (a, _) = await st.store.deleteFolder(f.id);
              nF += a;
            }
            for (final m in projects) {
              await st.deleteCollection(m.id);
              nP++;
            }
            for (final (cid, l) in marks) {
              await st.removeOverlayLabel(cid, l);
              nM++;
            }
            setState(() => _selected.clear());
            await st.refreshCollections();
            if (mounted) {
              toast(context,
                  '已删除 $nF 个文件夹、$nP 个工程、$nM 个标记');
            }
          }, color: kDanger),
        ]);
  }

  List<CollectionMeta> _selectedMetas() =>
      st.collections.where((m) => _selected.contains(m.id)).toList();

  /// 点击工程项：普通点击=清空多选并打开；Ctrl/Cmd=切换；Shift=范围选择。
  Future<void> _onItemTap(CollectionMeta m) async {
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    final shift = kb.isShiftPressed;

    if (ctrl) {
      setState(() {
        if (!_selected.remove(m.id)) _selected.add(m.id);
        _anchor = m.id;
      });
      return;
    }
    if (shift && _anchor.isNotEmpty) {
      final ids = _filteredItems().map((e) => e.id).toList();
      final a = ids.indexOf(_anchor);
      final b = ids.indexOf(m.id);
      if (a >= 0 && b >= 0) {
        final lo = a < b ? a : b;
        final hi = a < b ? b : a;
        setState(() => _selected.addAll(ids.sublist(lo, hi + 1)));
        return;
      }
    }
    // 普通点击：清空多选，打开工程。
    if (_selected.isNotEmpty) setState(() => _selected.clear());
    _anchor = m.id;
    await st.openCollection(m);
    if (mounted) toast(context, '已打开「${m.name}」，可继续编辑');
  }

  /// 批量导出选中工程（T21）：每个工程各存于 `导出/批量/<工程名>/`。
  Future<void> _batchExportSelected() async {
    final targets = _selectedMetas();
    if (targets.isEmpty) {
      toast(context, '请先选择要导出的工程（Ctrl/Shift 多选）');
      return;
    }
    await batchExportDxf(context, st, targets);
  }

  Widget _item(BuildContext context, CollectionMeta m, int depth) {
    final visible = st.visibleCids.contains(m.id);
    final selected = _selected.contains(m.id);
    // 同步状态取自可空快照（未接入同步 → 仅本地）；不读任何可能抛异常的 getter。
    final sync = context.watch<SyncController?>();
    final status = sync?.statusFor(m.id) ?? SyncStatus.localOnly;
    // 可拖拽（用户指定：工程可拖进文件夹）。多选时**拖一个带整组**。
    return Draggable<CollectionMeta>(
      data: m,
      onDragStarted: () {
        if (_selected.contains(m.id) && _selected.length > 1) {
          _dragGroup = Set.of(_selected); // 整组跟随
        } else {
          _dragGroup = {m.id};
        }
      },
      feedback: Material(
        color: TokC.card,
        elevation: 4,
        borderRadius: BorderRadius.circular(TokR.s),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(m.name.isEmpty ? '未命名' : m.name,
              style:
                  const TextStyle(color: kTextMain, fontSize: TokFs.small)),
        ),
      ),
      childWhenDragging: Opacity(
          opacity: 0.35,
          child: _itemCard(m, visible, selected, status, depth)),
      child: _itemCard(m, visible, selected, status, depth),
    );
  }

  Widget _itemCard(CollectionMeta m, bool visible, bool selected,
      SyncStatus status, int depth) {
    return Container(
      margin: EdgeInsets.only(
          left: 8.0 + depth * 16.0, right: 8, top: 3, bottom: 3),
      decoration: BoxDecoration(
        color: selected ? kAccent.withValues(alpha: 0.14) : TokC.card,
        borderRadius: BorderRadius.circular(TokR.m),
        border: Border.all(
            color: selected
                ? kAccent
                : (visible
                    ? kAccent.withValues(alpha: 0.6)
                    : Colors.transparent)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(TokR.m),
        onTap: () => _onItemTap(m),
        // 右键 = ⋮ 菜单（桌面惯例）。此前删除/重命名只藏在 ⋮ 里，
        // 用户反馈"没有删除功能"实为入口不可发现。
        onSecondaryTapUp: (d) => _showItemMenu(m, d.globalPosition),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 2, 7),
          child: Row(
            children: [
              if (selected)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.check_circle,
                      size: 14, color: kAccent),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.name.isEmpty ? '未命名' : m.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: kTextMain, fontSize: TokFs.body)),
                    const SizedBox(height: 2),
                    Row(children: [
                      _tag(_kindTag(m), _kindColor(m)),
                      const SizedBox(width: 6),
                      Text('${m.count} 点',
                          style: const TextStyle(
                              color: kTextSub, fontSize: TokFs.micro)),
                      const SizedBox(width: 6),
                      SyncBadge(status: status),
                    ]),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: visible ? '从地图隐藏' : '叠加显示到地图',
                onPressed: () => st.toggleVisible(m.id),
                icon: Icon(visible ? Icons.visibility : Icons.visibility_off,
                    color: visible ? kAccent : kTextSub, size: 18),
              ),
              PopupMenuButton<String>(
                tooltip: '更多操作',
                icon: const Icon(Icons.more_vert, color: kTextSub, size: 18),
                color: kPanelBg,
                onSelected: (v) => _onAction(context, m, v),
                itemBuilder: (ctx) => _itemMenuEntries,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _kindTag(CollectionMeta m) => m.kind == 'mark'
      ? '标记'
      : m.kind == 'track'
          ? '轨迹'
          : m.kind == 'data'
              ? '数据'
              : m.editMode == 'completion'
                  ? '竣工'
                  : '设计';

  Color _kindColor(CollectionMeta m) => m.kind == 'mark'
      ? const Color(0xFFE6A23C)
      : m.editMode == 'completion'
          ? TokC.warn
          : m.kind == 'track'
              ? const Color(0xFFFFD54F)
              : const Color(0xFF81C784);

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(TokR.s),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: TokFs.micro)),
      );

  /// 工程项动作清单——⋮ 按钮与**右键菜单**共用同一份，两边永远不会长得不一样。
  List<PopupMenuEntry<String>> get _itemMenuEntries => [
        if (_selected.isNotEmpty)
          PopupMenuItem(
              value: 'del_sel',
              height: 34,
              child: Text('删除所选 ${_selected.length} 项',
                  style: const TextStyle(color: kDanger))),
        if (_selected.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem(value: 'sync', height: 34, child: Text('同步该工程')),
        PopupMenuItem(value: 'history', height: 34, child: Text('历史版本')),
        PopupMenuItem(value: 'export', height: 34, child: Text('导出成果')),
        PopupMenuItem(
            value: 'batch_export',
            height: 34,
            child: Text('批量导出 DXF（选中项）')),
        PopupMenuItem(value: 'archive', height: 34, child: Text('竣工资料成册')),
        PopupMenuItem(value: 'rename', height: 34, child: Text('重命名')),
        PopupMenuItem(value: 'move', height: 34, child: Text('移动到文件夹')),
        PopupMenuItem(value: 'delete', height: 34, child: Text('删除')),
      ];

  /// 右键工程项：在指针位置弹动作菜单（复用 [showMenu]，与文件夹菜单同一套交互）。
  Future<void> _showItemMenu(CollectionMeta m, Offset pos) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final sel = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
          Rect.fromPoints(pos, pos), Offset.zero & overlay.size),
      color: kPanelBg,
      items: _itemMenuEntries,
    );
    if (sel == null || !mounted) return;
    await _onAction(context, m, sel);
  }

  Future<void> _onAction(
      BuildContext context, CollectionMeta m, String action) async {
    switch (action) {
      case 'del_sel':
        await _deleteSelected();
        return;
      case 'sync':
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
      case 'batch_export':
        // 批量导出：优先导出多选集合；无多选时退化为「仅本项」。
        final targets = _selectedMetas();
        await batchExportDxf(
            context, st, targets.isEmpty ? <CollectionMeta>[m] : targets);
        break;
      case 'archive':
        if (context.mounted) await showArchiveBookDialog(context, st);
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
        await _moveToFolderDialog(context, m);
        break;
      case 'delete':
        if (!context.mounted) return;
        await showDarkDialog(context,
            title: '删除收藏',
            content: Text('确定删除「${m.name}」（${m.count} 点）？',
                style: const TextStyle(color: kTextMain, fontSize: TokFs.body)),
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

  // ---- 导入区（点击选文件 / 应用内拖拽）T21 ----

  /// 点击「导入区」→ 选文件 → 按扩展名分派（`.ovimap` / `.geojson`）。
  Future<void> _importExternal() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['ovimap', 'geojson', 'json'],
        withData: false,
      );
    } catch (e) {
      if (mounted) toast(context, '打开文件选择器失败：$e');
      return;
    }
    if (picked == null || picked.files.isEmpty) return; // 用户取消：静默
    final p = picked.files.first.path;
    if (p == null || p.isEmpty) {
      if (mounted) toast(context, '无法获取所选文件的内容');
      return;
    }
    final msg = await st.openExternalFiles(<String>[p]);
    if (mounted) toast(context, msg);
  }

  Widget _dropZone(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: DragTarget<Object>(
        onWillAcceptWithDetails: (_) => true,
        onAcceptWithDetails: (details) async {
          final raw = details.data;
          final path = raw is String ? raw : '$raw';
          final msg = await st.openExternalFiles(<String>[path]);
          if (context.mounted) toast(context, msg);
        },
        builder: (ctx, candidate, rejected) {
          final hot = candidate.isNotEmpty;
          return InkWell(
            onTap: _importExternal,
            borderRadius: BorderRadius.circular(TokR.m),
            child: Container(
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: hot
                      ? kAccent.withValues(alpha: 0.12)
                      : TokC.field,
                  borderRadius: BorderRadius.circular(TokR.m),
                  border: Border.all(
                      color: hot ? kAccent : TokC.divider,
                      width: 1,
                      style: BorderStyle.solid)),
              child: const Text('点击导入文件，或拖入窗口\n（.ovimap 工程 / .geojson 底图）',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kTextSub, fontSize: TokFs.micro, height: 1.4)),
            ),
          );
        },
      ),
    );
  }
}
