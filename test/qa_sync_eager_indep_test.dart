// QA 独立护栏（批次五）：验证移动端启动即创建 SyncController（provider `lazy: false`）。
//
// 背景：移动端 HomePage.build 不读 SyncController（同步 UI 仅在抽屉/设置里），
// ChangeNotifierProvider 若用默认 `lazy: true`，`create` 不会在启动时触发，
// 导致 attachSyncController/start() 都不跑 → 「已配置设备冷启动不自动同步」。
//
// 本测试不复用源级字符串断言（那易写成同义反复），而是**真正 pump 真实 OviMapApp**，
// 从移动壳子树取 AppState，断言 syncController 已被接线。这是端到端行为护栏。
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:ovimap/main.dart';
import 'package:ovimap/services/platform_caps.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/home_page.dart';

void main() {
  // ⚠️ 仅移动壳下有意义，桌面平台**必须 skip**（两条独立理由，缺一不可）：
  //
  // 1) 断言价值为零：桌面壳 `WorkspacePage.build` 自己就 `watch<SyncController?>()`，
  //    于是即便 provider 是 `lazy: true` 也会在首帧被创建 —— 本用例在桌面上
  //    无法区分 eager / lazy，是个永远为真的空断言。
  // 2) 实测会让 Windows 门禁静默变红：在 Windows runner 上让本用例去 pump 真实桌面壳，
  //    会出现「用例全绿（✅）+ 汇总显示 502 passed, 1 skipped，但 flutter test
  //    退出码 = 1」，且日志里没有任何失败行 —— 排查成本极高。
  //    见 run 35360092169 的 Windows 任务。
  testWidgets('移动端启动即创建并接线 SyncController（eager, lazy:false）',
      skip: PlatformCaps.isDesktop, (tester) async {
    await tester.pumpWidget(const OviMapApp());
    // 让首帧与 provider 建立完成。
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(HomePage), findsOneWidget,
        reason: '移动平台应挂载移动壳 HomePage');

    final ctx = tester.element(find.byType(HomePage));
    final st = Provider.of<AppState>(ctx, listen: false);

    // 关键断言：移动端壳从不读 SyncController，但启动即应已创建并接线。
    expect(st.syncController, isNotNull,
        reason: 'SyncController provider 必须 eager（lazy:false）——'
            '否则冷启动不会自动同步');
  });
}
