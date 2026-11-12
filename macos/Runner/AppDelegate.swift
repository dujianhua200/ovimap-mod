import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 强制浅色外观（Light Aqua）。
  ///
  /// 为什么必须在**宿主**而不是 Flutter 侧设：应用内容区是 Flutter 画的，主题
  /// 是白色（`lib/main.dart` 的 `Brightness.light` + 底色 `0xFFF2F4F6`，设计令牌
  /// `TokC` 同为浅色）。用户看到的「不搭」来自 **macOS 系统外壳** —— 屏幕顶部
  /// 的系统菜单栏与窗口标题栏跟随**系统外观**：系统若处于深色模式，它们是黑的，
  /// 与白色内容区割裂。macOS 的规则是：应用处于前台时，系统菜单栏采用**该应用**
  /// 的外观；把 `NSApp.appearance` 钉成 `lightAqua`，顶部菜单栏与标题栏即跟随白底。
  ///
  /// 历史注记：v3.1.0 这里钉的是 `darkAqua`（当时内容区是深色）；v3.3.0 应用户
  /// 要求整体转为白色主题，宿主与 Flutter 同步翻转。**两处必须一起改**，只改
  /// 一侧就会出现上一版「上黑下白」式割裂。
  ///
  /// 放在 `applicationWillFinishLaunching` 而不是 `didFinishLaunching`：
  /// 前者早于窗口与菜单的首次绘制，才不会在启动瞬间闪一下深色。
  override func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.appearance = NSAppearance(named: .aqua)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
