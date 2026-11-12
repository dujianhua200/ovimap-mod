import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'services/platform_caps.dart';
import 'state/app_state.dart';
import 'sync/sync_controller.dart';
import 'ui/desktop/workspace_page.dart';
import 'ui/home_page.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  // 移动端保持竖屏；桌面端（Windows / macOS / Linux）**不加方向约束**，
  // 允许 1024×680 起的任意窗口尺寸 —— 桌面三栏壳在竖屏锁下会被压成一团。
  //
  // 判据用 [PlatformCaps.isDesktop] 而非 `Platform.isWindows`：
  // 后者会把 macOS 判成"移动端"，正是此前 macOS 包跑移动竖屏壳、
  // 界面变形且滚轮缩放失效的根因。
  if (!PlatformCaps.isDesktop) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }
  runApp(OviMapApp(startupProjectPath: startupProjectFromArgs(args)));
}

/// 从启动参数里解析 `.ovimap` 工程文件路径（T22 文件关联：`ovimap.exe "xxx.ovimap"`）。
///
/// Windows 的 runner 已把命令行参数经 `set_dart_entrypoint_arguments` 传入 Dart；
/// 这里只挑出第一个以 `.ovimap` 结尾的参数（去掉可能的包裹引号）。无则返回空串。
String startupProjectFromArgs(List<String> args) {
  for (final raw in args) {
    var a = raw.trim();
    if (a.length >= 2 && a.startsWith('"') && a.endsWith('"')) {
      a = a.substring(1, a.length - 1).trim();
    }
    if (a.toLowerCase().endsWith('.ovimap')) return a;
  }
  return '';
}

class OviMapApp extends StatelessWidget {
  const OviMapApp({super.key, this.startupProjectPath = ''});

  /// 启动时自动导入并打开的 `.ovimap` 工程文件路径（空串表示无）。
  final String startupProjectPath;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>(
          create: (_) => AppState(startupProjectPath: startupProjectPath)..init(),
        ),
        // 云同步编排器（T15/T16）：单个 `SYNC_TOKEN` 单用户多设备，不做账号体系。
        // 与 AppState 通过回调接线（`AppState.attachSyncController`），避免循环依赖。
        //
        // ⚠️ `lazy: false` 必须！移动端 `HomePage` 启动时不读 `SyncController`
        // （同步 UI 仅在抽屉/设置里），若用默认惰性，`create` 不触发 → `start()`
        // 与 `attachSyncController` 都不会跑，导致「已配置设备冷启动不自动同步」。
        // 桌面端 `WorkspacePage` 于 build 中 watch 会触发，但显式 `lazy: false`
        // 让两端一致地在启动即起同步。
        ChangeNotifierProvider<SyncController>(
          lazy: false,
          create: (ctx) {
            final st = ctx.read<AppState>();
            final sc = SyncController(store: st.store);
            st.attachSyncController(sc);
            // 启动同步（异步，不阻塞首帧；未配置令牌时静默保持本地模式）。
            scheduleMicrotask(sc.start);
            return sc;
          },
        ),
      ],
      child: MaterialApp(
        title: '滑洲云图',
        debugShowCheckedModeBanner: false,
        // 浅色主题（用户指定白底，与 TokC 令牌同源同值）。
        // brightness 决定 Material 组件（chips / 弹出菜单 / 对话框）的默认墨色，
        // 必须与 TokC 的浅色面板一致，否则会出现"面板白、控件黑"的混搭。
        theme: ThemeData(
          useMaterial3: false,
          brightness: Brightness.light,
          scaffoldBackgroundColor: const Color(0xFFF2F4F6),
          colorScheme: const ColorScheme.light(
            primary: Color(0xFF0288D1),
            secondary: Color(0xFF2E7D32),
          ),
        ),
        // 平台分支（架构文档 §3.1）：桌面（Windows / macOS / Linux）→ 桌面三栏壳；
        // 移动（Android / iOS）→ 移动竖屏壳。
        // 唯一顶层平台判断点；业务代码内平台能力一律走 PlatformCaps。
        home: PlatformCaps.isDesktop
            ? const WorkspacePage()
            : const HomePage(),
      ),
    );
  }
}
