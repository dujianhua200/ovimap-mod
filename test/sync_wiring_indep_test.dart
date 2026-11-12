// T16/T17/T18 接线断言（源级 / 零网络）：确认同步的 Provider 注入、AppState 回调接线、
// UI 以「可空快照」接入（AOT 安全）、无新增依赖、Worker 关键语义齐备。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String rel) => File(rel).readAsStringSync();

void main() {
  group('T16 AppState / main.dart 接线', () {
    test('main.dart 注入 SyncController 并启动（MultiProvider）', () {
      final s = read('lib/main.dart');
      expect(s.contains('MultiProvider('), isTrue);
      expect(s.contains('ChangeNotifierProvider<SyncController>'), isTrue);
      // ★ 必须 eager（精确匹配「provider 构造调用」，不匹配注释/文档串）：
      // 移动端 HomePage 启动不读 SyncController，惰性创建会导致
      // start()/attachSyncController 都不跑（冷启动不自动同步）。
      // 用正则锚定到 `ChangeNotifierProvider<SyncController>(` 之后的 `lazy: false`，
      // 这样删掉代码行（仅留注释）时断言会 RED，真正锁住回归。
      expect(
          RegExp(r'ChangeNotifierProvider<SyncController>\(\s*lazy:\s*false')
              .hasMatch(s),
          isTrue,
          reason: 'SyncController provider 必须 lazy:false（两端启动即起同步）');
      expect(s.contains('attachSyncController('), isTrue);
      expect(s.contains('sc.start'), isTrue);
      // 平台分支：桌面三平台（含 macOS）→ WorkspacePage；移动 → HomePage。
      // 判据必须是 PlatformCaps.isDesktop（曾写成 Platform.isWindows，
      // 使 macOS 落进移动竖屏壳）。此处按行归一化后断言，避免缩进/换行影响。
      final flat = s.replaceAll(RegExp(r'\s+'), ' ');
      expect(flat.contains('PlatformCaps.isDesktop ? const WorkspacePage() : const HomePage()'),
          isTrue,
          reason: 'main.dart 的界面壳分支应改用 PlatformCaps.isDesktop');
    });

    test('AppState：保存/删除回调同步器，且 sync 可为 null（本地可用）', () {
      final s = read('lib/state/app_state.dart');
      expect(s.contains('SyncController? syncController;'), isTrue);
      expect(s.contains('void attachSyncController(SyncController sc)'), isTrue);
      expect(s.contains('syncController?.onLocalSaved(cid)'), isTrue);
      expect(s.contains('syncController?.onLocalDeleted(cid)'), isTrue);
      expect(s.contains('Future<void> deleteCollection(String cid)'), isTrue);
      expect(s.contains('syncController?.pullProject'), isTrue);
    });

    test('依赖方向单向：SyncController 不 import AppState（无循环）', () {
      final s = read('lib/sync/sync_controller.dart');
      expect(s.contains('state/app_state.dart'), isFalse,
          reason: 'SyncController 不得依赖 AppState（避免循环）');
      expect(s.contains('onRemoteApplied'), isTrue,
          reason: '反向刷新走回调');
    });
  });

  group('T17 UI 接入（AOT 安全：可空快照）', () {
    test('同步面板/冲突框存在且默认「另存副本」', () {
      final panel = read('lib/ui/sync/sync_panel.dart');
      final conflict = read('lib/ui/sync/conflict_dialog.dart');
      expect(panel.contains('class SyncBadge'), isTrue);
      expect(panel.contains('showSyncSettingsDialog'), isTrue);
      expect(conflict.contains('showConflictDialog'), isTrue);
      expect(conflict.contains('var choice = ConflictChoice.saveCopy;'), isTrue,
          reason: '默认选中「另存冲突副本」');
    });

    test('工具栏/状态栏/左栏/抽屉：以 SyncController? 可空接入', () {
      final toolbar = read('lib/ui/desktop/toolbar.dart');
      final status = read('lib/ui/desktop/status_bar.dart');
      final left = read('lib/ui/desktop/left_panel.dart');
      final drawer = read('lib/ui/drawer_panel.dart');
      expect(toolbar.contains('SyncController? sync'), isTrue);
      expect(status.contains('SyncController? sync'), isTrue);
      expect(left.contains('context.watch<SyncController?>()'), isTrue);
      expect(drawer.contains('context.watch<SyncController?>()'), isTrue);
      expect(left.contains('SyncBadge('), isTrue);
      expect(drawer.contains('SyncBadge('), isTrue);
      expect(drawer.contains("'sync_project'"), isTrue);
    });

    test('设置面板含「云同步」入口', () {
      final s = read('lib/ui/settings_menu.dart');
      expect(s.contains("sheetGroupTitle('云同步')"), isTrue);
      expect(s.contains('showSyncPanel('), isTrue);
      expect(s.contains('showSyncSettingsDialog('), isTrue);
    });
  });

  group('T18/T19 Cloudflare 侧文件齐备', () {
    test('cloudflare 目录四件套存在', () {
      for (final f in [
        'cloudflare/wrangler.toml',
        'cloudflare/schema.sql',
        'cloudflare/src/index.js',
        'cloudflare/README.md',
      ]) {
        expect(File(f).existsSync(), isTrue, reason: '$f 应存在');
      }
    });

    test('Worker 关键语义：鉴权/乐观并发/保留/软删除/历史恢复', () {
      final s = read('cloudflare/src/index.js');
      expect(s.contains('SYNC_TOKEN'), isTrue);
      expect(s.contains('unauthorized('), isTrue);
      expect(s.contains('revAccepts('), isTrue);
      expect(s.contains('revsToPrune('), isTrue);
      expect(s.contains('409'), isTrue);
      expect(s.contains('RETENTION'), isTrue);
      expect(s.contains('deleted = 1') || s.contains('deleted = 1,'), isTrue);
      expect(s.contains('/restore') || s.contains('restore'), isTrue);
    });

    test('schema.sql 覆盖 projects + snapshots', () {
      final s = read('cloudflare/schema.sql');
      expect(s.contains('CREATE TABLE IF NOT EXISTS projects'), isTrue);
      expect(s.contains('CREATE TABLE IF NOT EXISTS snapshots'), isTrue);
      expect(s.contains('rev'), isTrue);
    });

    test('部署文档存在且含关键步骤', () {
      final s = read('docs/DEPLOY-sync.md');
      expect(s.contains('wrangler'), isTrue);
      expect(s.contains('SYNC_TOKEN'), isTrue);
      expect(s.contains('r2 bucket create') || s.contains('r2_buckets'), isTrue);
    });
  });

  group('硬约束：零新增运行时依赖', () {
    test('pubspec 未新增 crypto 等包', () {
      final s = read('pubspec.yaml');
      // 允许的既有依赖之外的哈希类包不得出现。
      expect(RegExp(r'\n\s+crypto:').hasMatch(s), isFalse,
          reason: '不得新增 crypto 依赖');
      expect(RegExp(r'\n\s+uuid:').hasMatch(s), isFalse);
      expect(s.contains('http: ^1.2.0'), isTrue);
    });
  });
}
