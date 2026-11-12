// 桌面板接线断言（源级 / 零网络）：确认 T08~T12 的桌面壳、快捷键、右键菜单、
// 三栏与平台单点收口确实接线，且业务 UI 未散落平台/交付分支。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String rel) => File(rel).readAsStringSync();

/// 折叠所有空白，让「跨行书写」的代码也能被单行子串命中。
String flat(String src) => src.replaceAll(RegExp(r'\s+'), ' ');

/// 只保留**代码行**（剔除整行注释）。
///
/// 用途：凡「某旧写法/旧 token 必须已消失」这类回归护栏，注释里往往会解释
/// 「以前写的是 XXX」—— 若直接对全文断言 `contains('XXX') == false`，
/// 注释自己就会把护栏判红。故这类断言一律跑在本函数的结果上。
String codeOnly(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  group('T08 桌面壳 + main.dart 平台分支', () {
    test('main.dart：桌面三平台 → WorkspacePage，移动 → HomePage；仅移动强制竖屏', () {
      final s = read('lib/main.dart');
      final f = flat(s);
      expect(s.contains("import 'ui/desktop/workspace_page.dart';"), isTrue);
      expect(s.contains("import 'services/platform_caps.dart';"), isTrue);
      // 判据必须是 PlatformCaps.isDesktop —— 曾经写成 Platform.isWindows，
      // 导致 macOS 落到移动竖屏壳（宽窗口下界面变形 + 滚轮缩放失效）。
      expect(s.contains('PlatformCaps.isDesktop'), isTrue);
      expect(
          f.contains(
              'PlatformCaps.isDesktop ? const WorkspacePage() : const HomePage()'),
          isTrue);
      expect(f.contains('if (!PlatformCaps.isDesktop)'), isTrue);
      // 回归护栏：main.dart 不得再出现单一平台的裸判据。
      expect(codeOnly(s).contains('Platform.isWindows'), isFalse);
      expect(s.contains("import 'dart:io' show Platform;"), isFalse);
    });

    test('workspace_page：三栏 + 可拖拽分隔 + 折叠 + LayoutBuilder 自适应', () {
      final s = read('lib/ui/desktop/workspace_page.dart');
      expect(s.contains('DesktopShortcuts('), isTrue);
      expect(s.contains('LayoutBuilder('), isTrue);
      expect(s.contains('AppMenuBar('), isTrue);
      expect(s.contains('Toolbar('), isTrue);
      expect(s.contains('StatusBar('), isTrue);
      expect(s.contains('LeftPanel('), isTrue);
      expect(s.contains('RightPanel('), isTrue);
      // 共享地图核心：桌面点选交给右栏，不直接弹对话框。
      expect(s.contains('openDetailOnTap: false,'), isTrue);
      // 交互开关**不得**在壳里覆盖：覆盖就等于绕过 defaultFlagsForCurrentPlatform()，
      // 历史缺陷正是「全部开关」（含旋转/惯性/双击缩放，且双击缩放会给每次
      // 单击落点加 250ms 判定延迟）。断言只跑代码行，注释里可以自由解释旧写法。
      final code = codeOnly(s);
      expect(code.contains('InteractiveFlag.all'), isFalse);
      expect(code.contains('interactionFlags:'), isFalse);
      // 鼠标经纬度：地图 → 壳 → 状态栏（奥维桌面版状态栏口径）。
      expect(s.contains('onPointerGeo: _onMouseGeo'), isTrue);
      expect(s.contains('mouseGeo: _mouseGeo'), isTrue);
      expect(s.contains('ValueNotifier<LatLng?>'), isTrue);
      // 模式提示栏（奥维「提示栏」位）
      expect(s.contains('_hintBar('), isTrue);
      // 鼠标右键 → 右键菜单
      expect(s.contains('onSecondaryTap:'), isTrue);
      expect(s.contains('showMapContextMenu('), isTrue);
      // 窗口 < 1180 自动收起右栏
      expect(s.contains('1180'), isTrue);
    });
  });

  group('T12 快捷键 + 右键菜单', () {
    test('shortcuts：Shortcuts/Actions/Intent（零依赖）', () {
      final s = read('lib/ui/desktop/shortcuts.dart');
      expect(s.contains('Shortcuts('), isTrue);
      expect(s.contains('Actions('), isTrue);
      expect(s.contains('SingleActivator(LogicalKeyboardKey.keyS, control: true):'),
          isTrue);
      expect(s.contains('SingleActivator(LogicalKeyboardKey.delete):'), isTrue);
      expect(s.contains('class SaveIntent'), isTrue);
      expect(s.contains('class UndoIntent'), isTrue);
      expect(s.contains('class RedoIntent'), isTrue);
      expect(s.contains('class DeleteSelectionIntent'), isTrue);
      expect(s.contains('class ExportIntent'), isTrue);
      expect(s.contains('class FocusSearchIntent'), isTrue);
      // Ctrl+Shift+Z 也映射到 Redo
      expect(s.contains('logicalKeyboardKey.keyZ') ||
          s.contains('LogicalKeyboardKey.keyZ, control: true, shift: true'),
          isTrue);
    });

    test('shortcuts：奥维口径的缩放/复位/取消/退点', () {
      final s = read('lib/ui/desktop/shortcuts.dart');
      expect(s.contains('class ZoomInIntent'), isTrue);
      expect(s.contains('class ZoomOutIntent'), isTrue);
      expect(s.contains('class ResetViewIntent'), isTrue);
      expect(s.contains('class EscapeIntent'), isTrue);
      expect(s.contains('class UndoPointIntent'), isTrue);
      // 裸 ± / 0 / Esc / Backspace
      expect(s.contains('SingleActivator(LogicalKeyboardKey.equal):'), isTrue);
      expect(s.contains('SingleActivator(LogicalKeyboardKey.add):'), isTrue);
      expect(s.contains('LogicalKeyboardKey.numpadAdd):'), isTrue);
      expect(s.contains('SingleActivator(LogicalKeyboardKey.minus):'), isTrue);
      expect(s.contains('LogicalKeyboardKey.numpadSubtract):'), isTrue);
      expect(s.contains('SingleActivator(LogicalKeyboardKey.digit0):'), isTrue);
      expect(s.contains('SingleActivator(LogicalKeyboardKey.escape):'), isTrue);
      expect(s.contains('SingleActivator(LogicalKeyboardKey.backspace):'), isTrue);
      // 带修饰键的缩放（不参与裸键守卫，始终生效）
      expect(s.contains('LogicalKeyboardKey.equal, control: true'), isTrue);
      expect(s.contains('LogicalKeyboardKey.minus, control: true'), isTrue);
      expect(s.contains('LogicalKeyboardKey.digit0, control: true'), isTrue);
      // macOS 的 Command 组合
      expect(s.contains('LogicalKeyboardKey.keyS, meta: true'), isTrue);
      // 回归护栏：裸键必须按「是否在编辑文本」开关，否则会吞掉文本框输入。
      expect(s.contains('if (!_editing)'), isTrue);
      expect(s.contains('findAncestorWidgetOfExactType<EditableText>()'), isTrue);
    });

    test('context_menu：showMenu + 点/线/空白三态菜单项', () {
      final s = read('lib/ui/desktop/context_menu.dart');
      expect(s.contains('showMenu<String>('), isTrue);
      // 点
      expect(s.contains("value: 'edit'"), isTrue);
      expect(s.contains("value: 'branch'"), isTrue);
      expect(s.contains("value: 'drag'"), isTrue);
      expect(s.contains("value: 'del_point'"), isTrue);
      // 线段
      expect(s.contains("value: 'seg_kind'"), isTrue);
      expect(s.contains("value: 'seg_cable'"), isTrue);
      expect(s.contains("value: 'seg_slack'"), isTrue);
      // 空白
      expect(s.contains("value: 'add'"), isTrue);
      expect(s.contains("value: 'paste_coord'"), isTrue);
      expect(s.contains("value: 'import_file'"), isTrue);
    });
  });

  group('T09/T10/T11 三栏件', () {
    test('left_panel：搜索 + 文件夹 + 工程列表 + 同步徽标位 + 拖拽导入占位', () {
      final s = read('lib/ui/desktop/left_panel.dart');
      expect(s.contains('onNewProject'), isTrue);
      expect(s.contains('文件夹'), isTrue);
      expect(s.contains('DragTarget<Object>'), isTrue);
      // 同步徽标位：T17 已由「本地」占位升级为真实 SyncBadge（可空接入 SyncController）。
      expect(s.contains("'SyncBadge'") || s.contains('SyncBadge(status:'), isTrue);
      expect(s.contains('context.watch<SyncController?>('), isTrue);
      expect(s.contains('searchFocus'), isTrue);
    });

    test('right_panel：复用属性编辑逻辑（草稿/收藏两路保存）', () {
      final s = read('lib/ui/desktop/right_panel.dart');
      expect(s.contains('st.updateLabel('), isTrue);
      expect(s.contains('updateOverlayLabel('), isTrue);
      expect(s.contains('showLabelProperties('), isTrue);
      expect(s.contains('ChoiceChip('), isTrue); // 敷设方式
    });

    test('toolbar / status_bar：工具入口 + 设备名/同步状态/坐标/图源', () {
      final tb = read('lib/ui/desktop/toolbar.dart');
      expect(tb.contains('AppMode.measureArea'), isTrue);
      expect(tb.contains('onSync'), isTrue);
      expect(tb.contains('showSourceDialog('), isTrue);

      final sb = read('lib/ui/desktop/status_bar.dart');
      expect(sb.contains('本地模式'), isTrue);
      expect(sb.contains('最后同步'), isTrue);
      expect(sb.contains('curSource.name'), isTrue);
      // 鼠标所在经纬度（奥维桌面版状态栏口径）+ 视图中心，两者分列。
      expect(sb.contains('鼠标'), isTrue);
      expect(sb.contains('中心 '), isTrue);
      expect(sb.contains('ValueListenableBuilder<LatLng?>'), isTrue);
    });
  });

  group('平台单点收口 / 禁止散落', () {
    test('业务 UI（lib/ui）不得直接调用 Share.* 或 FilePicker.saveFile', () {
      final files = Directory('lib/ui')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      for (final f in files) {
        final s = f.readAsStringSync();
        expect(s.contains('Share.'), isFalse,
            reason: '${f.path} 直接调用 Share，应走 ExportSaver');
        expect(s.contains('FilePicker.platform.saveFile'), isFalse,
            reason: '${f.path} 直接调用 saveFile，应走 ExportSaver');
      }
    });

    test('业务 UI（lib/ui）不得出现 Platform.isWindows（须走 PlatformCaps）', () {
      final files = Directory('lib/ui')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      for (final f in files) {
        expect(f.readAsStringSync().contains('Platform.isWindows'), isFalse,
            reason: '${f.path} 散落 Platform.isWindows，应走 PlatformCaps');
      }
    });

    test('loc.dart：罗盘订阅经 PlatformCaps.hasCompass 拦截（无 Windows 实现）', () {
      final s = read('lib/services/loc.dart');
      expect(s.contains('PlatformCaps.hasCompass'), isTrue);
    });

    test('dialogs.dart：交付出口收敛到 ExportSaver（不再直接 import share_plus）', () {
      final s = read('lib/ui/dialogs.dart');
      expect(s.contains('ExportSaver.saveOrShare'), isTrue);
      expect(s.contains("import 'package:share_plus/share_plus.dart';"), isFalse);
      expect(s.contains('PlatformCaps.hasCamera'), isTrue);
    });

    test('app_paths.dart：Windows 走 %APPDATA%（APPDATA 环境变量）', () {
      final s = read('lib/services/app_paths.dart');
      expect(s.contains("Platform.environment['APPDATA']"), isTrue);
      expect(s.contains('\\\\ovimap'), isTrue); // %APPDATA%\ovimap
    });
  });
}
