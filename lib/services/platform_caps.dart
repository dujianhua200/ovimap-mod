import 'dart:io' show Platform;

/// 平台能力探测（单点收口）。
///
/// 业务代码判断平台能力时统一走这里，**禁止**散落 `Platform.isWindows`。
///
/// 两处顶层用途：
/// - **界面壳选择**（`lib/main.dart`）：[isDesktop] 决定用桌面三栏壳还是移动竖屏壳；
/// - **能力降级**（桌面端四类）：
///   - 无 GPS（[hasGps]=false）→ 不订阅位置流，打点走手动落点；
///   - 无罗盘（[hasCompass]=false）→ 不订阅 `flutter_compass`（其无桌面实现，
///     调用会抛 `MissingPluginException`），罗盘控件隐藏；
///   - 无相机（[hasCamera]=false）→ 拍照入口降级为「选文件」；
///   - [supportsFileSaveDialog] → 区分导出走「系统另存为」还是「分享」。
///
/// ⚠️ 历史坑：本类曾把判据写成 `Platform.isWindows`，导致 macOS 被当成
/// 「非桌面」—— 界面落到移动竖屏壳（宽窗口下严重变形）、地图默认交互开关
/// 缺少滚轮缩放（滚轮完全没反应）。新增平台判断时**一律用 [isDesktop]，
/// 不要用单一平台的 `isXxx`**，参见 `docs/DESKTOP-UI.md`。
class PlatformCaps {
  PlatformCaps._();

  /// 是否桌面平台（Windows / Linux / macOS）。
  static final bool isDesktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 是否 macOS。**只用于「原生菜单栏」这类 macOS 独有能力**。
  ///
  /// 与 [isDesktop] 分开的理由：`PlatformMenuBar` 在 macOS 上把菜单渲染到
  /// 屏幕顶部系统菜单栏（且会整体接管主菜单），Windows / Linux 没有这个能力，
  /// 必须继续用窗口内自绘菜单栏。所以这里需要区分「桌面」与「macOS」。
  /// 其余平台判断（有无 GPS / 罗盘 / 相机 / 另存为对话框）**一律仍用 [isDesktop]**，
  /// 不要因为本 getter 的存在就改回 `Platform.isXxx` 散判。
  static final bool isMacOS = Platform.isMacOS;

  /// 是否有真实 GPS 定位。
  ///
  /// **只有移动端有，桌面三平台都没有。** 旧实现写成 `!Platform.isWindows`，
  /// 会把 macOS / Linux 误判为"有 GPS"—— 一旦有人拿它当订阅判据，
  /// 桌面端就会去订阅定位流。判据要与 [LocService] 里实际用的
  /// `PlatformCaps.isDesktop` 保持一致。
  static bool get hasGps => Platform.isAndroid || Platform.isIOS;

  /// 是否有电子罗盘。`flutter_compass` 仅 iOS/Android 有实现。
  static bool get hasCompass => Platform.isAndroid || Platform.isIOS;

  /// 是否有相机拍摄能力。`image_picker` 的 `ImageSource.camera` 仅移动端支持。
  static bool get hasCamera => Platform.isAndroid || Platform.isIOS;

  /// 是否支持系统「另存为」对话框（`file_picker.saveFile`）。
  ///
  /// Windows 走 IFileSaveDialog、macOS 走 NSSavePanel，两端都是原生实现；
  /// Linux 的 saveFile 依赖 zenity/qarma 等外部程序，可用性不保证，故不开。
  /// 未开启的平台由 [ExportSaver] 退化为「分享 / 落地到数据目录」。
  ///
  /// macOS 侧依赖沙箱授权 `com.apple.security.files.user-selected.read-write`
  /// （已在 `macos/Runner/Release.entitlements` 声明）：用户显式选中的路径
  /// 才允许写入，正是「另存为」的语义。
  static bool get supportsFileSaveDialog =>
      Platform.isWindows || Platform.isMacOS;
}
