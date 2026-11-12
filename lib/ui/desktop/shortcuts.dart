import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 桌面快捷键（架构文档 §3.3 / T12；奥维桌面版对齐见 `docs/DESKTOP-UI.md`）。
///
/// ## 两条硬规则
///
/// **规则 1：裸键只在「非文本编辑态」注册。**
///
/// `Shortcuts` 沿焦点链**由内向外**冒泡，而本组件位于 `WidgetsApp` 的
/// `DefaultTextEditingShortcuts` **内侧**（更靠近焦点）—— 也就是说，
/// 只要在这里无条件注册 `Delete` / `Backspace` / `+` / `-`，
/// 文本框里的「向后删除 / 退格 / 输入 +−」就会被本层截胡，
/// 左栏搜索框、属性对话框全都会失灵。所以裸键表随
/// 「当前主焦点是否落在 [EditableText] 子树内」动态开关。
///
/// 检测成本：每次焦点变化做一次祖先查找（O(树深)），并只 `setState` 本组件 ——
/// `child` 是同一个 Widget 实例，Element 复用，**不会**连地图一起重建。
///
/// **规则 2：带修饰键的条目始终生效。** Ctrl/⌘ 组合不会与文本输入冲突。
///
/// ## 键位表
///
/// | 键 | Intent | 作用 | 生效条件 |
/// |---|---|---|---|
/// | Ctrl+S / ⌘S | [SaveIntent] | 保存工程 | 始终 |
/// | Ctrl+Z / ⌘Z | [UndoIntent] | 撤销 | 始终 |
/// | Ctrl+Y / Ctrl+Shift+Z / ⌘⇧Z | [RedoIntent] | 重做 | 始终 |
/// | Ctrl+E / ⌘E | [ExportIntent] | 打开导出中心 | 始终 |
/// | Ctrl+F / ⌘F | [FocusSearchIntent] | 聚焦左栏搜索 | 始终 |
/// | Ctrl+O / ⌘O | [OpenProjectIntent] | 打开 `.ovimap` 工程 | 始终 |
/// | Ctrl+= / Ctrl++ / ⌘± | [ZoomInIntent] | 放大一级 | 始终 |
/// | Ctrl+- / ⌘− | [ZoomOutIntent] | 缩小一级 | 始终 |
/// | Ctrl+0 / ⌘0 | [ResetViewIntent] | 复位到启动视图 | 始终 |
/// | Alt+Ctrl+L / ⌥⌘L | [ToggleLeftIntent] | 折叠 / 展开左栏 | 始终 |
/// | Alt+Ctrl+R / ⌥⌘R | [ToggleRightIntent] | 折叠 / 展开右栏 | 始终 |
/// | Alt+Ctrl+M / ⌥⌘M | [FocusMapIntent] | 专注地图（两侧全收 / 还原） | 始终 |
/// | Alt+Ctrl+K / ⌥⌘K | [InspectIntent] | 出图体检（查段距/敷设方式/编号/标注） | 始终 |
/// | `+` / `=` / `-`（含小键盘） | [ZoomInIntent] / [ZoomOutIntent] | 同 Ctrl± | 非编辑态 |
/// | Esc | [EscapeIntent] | 取消当前操作 / 结束模式 | 非编辑态 |
/// | Backspace | [UndoPointIntent] | 退掉最后一个点/连线 | 非编辑态 |
/// | Delete | [DeleteSelectionIntent] | 删除选中点 | 非编辑态 |
class SaveIntent extends Intent {
  const SaveIntent();
}

/// Ctrl+Z：撤销。
class UndoIntent extends Intent {
  const UndoIntent();
}

/// Ctrl+Y / Ctrl+Shift+Z：重做。
class RedoIntent extends Intent {
  const RedoIntent();
}

/// Delete：删除选择集。
class DeleteSelectionIntent extends Intent {
  const DeleteSelectionIntent();
}

/// Ctrl+E：打开导出。
class ExportIntent extends Intent {
  const ExportIntent();
}

/// Ctrl+F：聚焦搜索框。
class FocusSearchIntent extends Intent {
  const FocusSearchIntent();
}

/// Ctrl+O：打开工程文件（`.ovimap`）。
class OpenProjectIntent extends Intent {
  const OpenProjectIntent();
}

/// `+` / `=`：放大一级。
class ZoomInIntent extends Intent {
  const ZoomInIntent();
}

/// `-`：缩小一级。
class ZoomOutIntent extends Intent {
  const ZoomOutIntent();
}

/// `0`：复位到启动视图。
class ResetViewIntent extends Intent {
  const ResetViewIntent();
}

/// Esc：取消当前操作（退出模式 / 取消待定点位编辑 / 清空选择）。
class EscapeIntent extends Intent {
  const EscapeIntent();
}

/// Backspace：退掉最后一个点（采集退点 / 测量退点 / 连线退一条）。
class UndoPointIntent extends Intent {
  const UndoPointIntent();
}

/// Alt+Ctrl+L / ⌥⌘L：折叠 / 展开左栏。
class ToggleLeftIntent extends Intent {
  const ToggleLeftIntent();
}

/// Alt+Ctrl+R / ⌥⌘R：折叠 / 展开右栏。
class ToggleRightIntent extends Intent {
  const ToggleRightIntent();
}

/// Alt+Ctrl+M / ⌥⌘M：专注地图（两侧全收，再按还原）。
class FocusMapIntent extends Intent {
  const FocusMapIntent();
}

/// Alt+Ctrl+K / ⌥⌘K：出图体检（出图前的查错清单）。
class InspectIntent extends Intent {
  const InspectIntent();
}

/// 桌面快捷键容器：把一组回调接到对应 Intent 上。
class DesktopShortcuts extends StatefulWidget {
  const DesktopShortcuts({
    super.key,
    required this.child,
    required this.onSave,
    required this.onUndo,
    required this.onRedo,
    required this.onDeleteSelection,
    required this.onExport,
    required this.onFocusSearch,
    required this.onOpenProject,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onResetView,
    required this.onEscape,
    required this.onUndoPoint,
    required this.onToggleLeft,
    required this.onToggleRight,
    required this.onFocusMap,
    required this.onInspect,
  });

  final Widget child;
  final VoidCallback onSave;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onDeleteSelection;
  final VoidCallback onExport;
  final VoidCallback onFocusSearch;
  final VoidCallback onOpenProject;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onResetView;
  final VoidCallback onEscape;
  final VoidCallback onUndoPoint;
  final VoidCallback onToggleLeft;
  final VoidCallback onToggleRight;
  final VoidCallback onFocusMap;
  final VoidCallback onInspect;

  @override
  State<DesktopShortcuts> createState() => _DesktopShortcutsState();
}

class _DesktopShortcutsState extends State<DesktopShortcuts> {
  /// 当前主焦点是否位于可编辑文本内（决定裸键是否注册）。
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
    _onFocusChanged();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    final editing = _isEditingText();
    if (editing != _editing && mounted) {
      setState(() => _editing = editing);
    }
  }

  /// 主焦点是否在 [EditableText] 内。
  ///
  /// 两道判断：焦点节点自身就是文本框（少见，例如自定义输入组件），
  /// 或它是文本框内部 Focus 的节点（常态，`EditableText` 的 Focus 在其子树内）。
  static bool _isEditingText() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null || !ctx.mounted) return false;
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, Intent>{
      // ---- 带修饰键：任何情况下都生效 ----
      const SingleActivator(LogicalKeyboardKey.keyS, control: true):
          const SaveIntent(),
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
          const UndoIntent(),
      const SingleActivator(LogicalKeyboardKey.keyY, control: true):
          const RedoIntent(),
      const SingleActivator(
          LogicalKeyboardKey.keyZ, control: true, shift: true): const RedoIntent(),
      const SingleActivator(LogicalKeyboardKey.keyE, control: true):
          const ExportIntent(),
      const SingleActivator(LogicalKeyboardKey.keyF, control: true):
          const FocusSearchIntent(),
      const SingleActivator(LogicalKeyboardKey.keyO, control: true):
          const OpenProjectIntent(),
      const SingleActivator(LogicalKeyboardKey.equal, control: true):
          const ZoomInIntent(),
      const SingleActivator(LogicalKeyboardKey.add, control: true):
          const ZoomInIntent(),
      const SingleActivator(LogicalKeyboardKey.minus, control: true):
          const ZoomOutIntent(),
      const SingleActivator(LogicalKeyboardKey.digit0, control: true):
          const ResetViewIntent(),

      // ---- macOS：Command 组合（⌘）与 Control 组合并存 ----
      const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
          const SaveIntent(),
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
          const UndoIntent(),
      const SingleActivator(
          LogicalKeyboardKey.keyZ, meta: true, shift: true): const RedoIntent(),
      const SingleActivator(LogicalKeyboardKey.keyE, meta: true):
          const ExportIntent(),
      const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
          const FocusSearchIntent(),
      const SingleActivator(LogicalKeyboardKey.keyO, meta: true):
          const OpenProjectIntent(),
      const SingleActivator(LogicalKeyboardKey.equal, meta: true):
          const ZoomInIntent(),
      const SingleActivator(LogicalKeyboardKey.add, meta: true):
          const ZoomInIntent(),
      const SingleActivator(LogicalKeyboardKey.minus, meta: true):
          const ZoomOutIntent(),
      const SingleActivator(LogicalKeyboardKey.digit0, meta: true):
          const ResetViewIntent(),

      // ---- 侧栏 / 地图占屏（Alt 组合，不与文本编辑冲突）----
      //
      // 与 macOS 原生菜单里同一批菜单项声明的快捷键**重复是刻意的、也是安全的**：
      // 按 Apple 的事件派发顺序（Handling Key Events），按键先沿**视图层级**
      // 传递，只有视图层不处理时才轮到菜单栏的 key equivalent —— 两条路径
      // 命中同一个动作，且一条命中即终止，不会触发两遍。
      const SingleActivator(LogicalKeyboardKey.keyL, control: true, alt: true):
          const ToggleLeftIntent(),
      const SingleActivator(LogicalKeyboardKey.keyR, control: true, alt: true):
          const ToggleRightIntent(),
      const SingleActivator(LogicalKeyboardKey.keyM, control: true, alt: true):
          const FocusMapIntent(),
      const SingleActivator(LogicalKeyboardKey.keyK, control: true, alt: true):
          const InspectIntent(),
      const SingleActivator(LogicalKeyboardKey.keyL, meta: true, alt: true):
          const ToggleLeftIntent(),
      const SingleActivator(LogicalKeyboardKey.keyR, meta: true, alt: true):
          const ToggleRightIntent(),
      const SingleActivator(LogicalKeyboardKey.keyM, meta: true, alt: true):
          const FocusMapIntent(),
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true, alt: true):
          const InspectIntent(),

      // ---- 裸键：仅在非文本编辑态注册（规则 1）----
      if (!_editing) ...{
        const SingleActivator(LogicalKeyboardKey.equal): const ZoomInIntent(),
        const SingleActivator(LogicalKeyboardKey.add): const ZoomInIntent(),
        const SingleActivator(LogicalKeyboardKey.numpadAdd):
            const ZoomInIntent(),
        const SingleActivator(LogicalKeyboardKey.numpadEqual):
            const ZoomInIntent(),
        const SingleActivator(LogicalKeyboardKey.minus): const ZoomOutIntent(),
        const SingleActivator(LogicalKeyboardKey.numpadSubtract):
            const ZoomOutIntent(),
        const SingleActivator(LogicalKeyboardKey.digit0):
            const ResetViewIntent(),
        const SingleActivator(LogicalKeyboardKey.numpad0):
            const ResetViewIntent(),
        const SingleActivator(LogicalKeyboardKey.escape): const EscapeIntent(),
        const SingleActivator(LogicalKeyboardKey.backspace):
            const UndoPointIntent(),
        const SingleActivator(LogicalKeyboardKey.delete):
            const DeleteSelectionIntent(),
      },
    };

    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          SaveIntent: CallbackAction<SaveIntent>(
              onInvoke: (_) => _run(widget.onSave)),
          UndoIntent: CallbackAction<UndoIntent>(
              onInvoke: (_) => _run(widget.onUndo)),
          RedoIntent: CallbackAction<RedoIntent>(
              onInvoke: (_) => _run(widget.onRedo)),
          DeleteSelectionIntent: CallbackAction<DeleteSelectionIntent>(
              onInvoke: (_) => _run(widget.onDeleteSelection)),
          ExportIntent: CallbackAction<ExportIntent>(
              onInvoke: (_) => _run(widget.onExport)),
          FocusSearchIntent: CallbackAction<FocusSearchIntent>(
              onInvoke: (_) => _run(widget.onFocusSearch)),
          OpenProjectIntent: CallbackAction<OpenProjectIntent>(
              onInvoke: (_) => _run(widget.onOpenProject)),
          ZoomInIntent: CallbackAction<ZoomInIntent>(
              onInvoke: (_) => _run(widget.onZoomIn)),
          ZoomOutIntent: CallbackAction<ZoomOutIntent>(
              onInvoke: (_) => _run(widget.onZoomOut)),
          ResetViewIntent: CallbackAction<ResetViewIntent>(
              onInvoke: (_) => _run(widget.onResetView)),
          EscapeIntent: CallbackAction<EscapeIntent>(
              onInvoke: (_) => _run(widget.onEscape)),
          UndoPointIntent: CallbackAction<UndoPointIntent>(
              onInvoke: (_) => _run(widget.onUndoPoint)),
          ToggleLeftIntent: CallbackAction<ToggleLeftIntent>(
              onInvoke: (_) => _run(widget.onToggleLeft)),
          ToggleRightIntent: CallbackAction<ToggleRightIntent>(
              onInvoke: (_) => _run(widget.onToggleRight)),
          FocusMapIntent: CallbackAction<FocusMapIntent>(
              onInvoke: (_) => _run(widget.onFocusMap)),
          InspectIntent: CallbackAction<InspectIntent>(
              onInvoke: (_) => _run(widget.onInspect)),
        },
        // autofocus 保证快捷键在无其它可聚焦控件时也能命中。
        child: Focus(autofocus: true, child: widget.child),
      ),
    );
  }

  /// 统一的 Action 包装：执行回调并返回 null（满足 `CallbackAction` 签名）。
  Object? _run(VoidCallback cb) {
    cb();
    return null;
  }
}
