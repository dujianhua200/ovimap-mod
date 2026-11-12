import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 桌面壳的目标初始尺寸（与 Windows 侧 `windows/runner/main.cpp` 的 1440×900 对齐）。
  ///
  /// 为什么必须显式设置：`flutter create` 模板生成的 MainMenu.xib 里窗口只有
  /// 800×600，而桌面三栏布局（左栏 260 + 地图 + 右栏 300）在该宽度下会被挤成一团 ——
  /// 这是「界面变形严重」的直接成因之一。窗口尺寸归窗口管，UI 侧的自适应只做兜底。
  private static let preferredSize = NSSize(width: 1440, height: 900)

  /// 最小尺寸与 Windows 侧 `win32_window.cpp` 的 WM_GETMINMAXINFO 限制保持一致，
  /// 低于此尺寸三栏壳无法正常排布。
  private static let minimumSize = NSSize(width: 1024, height: 680)

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // 窗口底色与 Flutter 侧 `Scaffold.backgroundColor`（0xFFF2F4F6，白色主题）对齐：
    // Flutter 首帧渲染之前窗口是"空"的，不设底色会闪一下系统默认底色。
    self.backgroundColor = NSColor(srgbRed: 0xF2 / 255.0,
                                   green: 0xF4 / 255.0,
                                   blue: 0xF6 / 255.0,
                                   alpha: 1)
    // 标题栏/工具条区域也走浅色。AppDelegate 已把 `NSApp.appearance` 钉成
    // aqua（浅色），这里对窗口再显式声明一次 —— 窗口级外观与全局外观是两套独立
    // 属性，只设一处时个别系统版本会出现标题栏仍是深色。
    self.appearance = NSAppearance(named: .aqua)

    // 屏幕可能比目标尺寸小（如 1280×800 的笔记本）：按可见区域收敛，避免窗口超出屏幕。
    let target = MainFlutterWindow.preferredSize
    if let visible = (self.screen ?? NSScreen.main)?.visibleFrame {
      self.setContentSize(NSSize(width: min(target.width, visible.width),
                                 height: min(target.height, visible.height)))
    } else {
      self.setContentSize(target)
    }
    self.contentMinSize = MainFlutterWindow.minimumSize
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
