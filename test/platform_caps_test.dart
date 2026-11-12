// PlatformCaps 单测（零网络）：验证「平台能力探测」单点收口契约。
//
// 关键：flutter_compass 无 Windows 实现，hasCompass=false 必须成立，
// 否则会抛 MissingPluginException。这里用「与 Platform.isAndroid/isIOS 等值」
// 的表达方式断言契约，保证在任何宿主平台上都有意义。
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/services/platform_caps.dart';

void main() {
  test('isDesktop = Windows/Linux/macOS 之一', () {
    final expected =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    expect(PlatformCaps.isDesktop, expected);
  });

  test('hasCompass 仅 Android/iOS（Windows 必须为 false，避免 compass 插件崩溃）', () {
    final expected = Platform.isAndroid || Platform.isIOS;
    expect(PlatformCaps.hasCompass, expected);
    if (Platform.isWindows) {
      expect(PlatformCaps.hasCompass, isFalse);
    }
  });

  test('hasCamera 仅 Android/iOS（桌面降级为选文件）', () {
    final expected = Platform.isAndroid || Platform.isIOS;
    expect(PlatformCaps.hasCamera, expected);
  });

  test('hasGps 仅 Android/iOS —— 桌面三平台（含 macOS/Linux）一律 false', () {
    final expected = Platform.isAndroid || Platform.isIOS;
    expect(PlatformCaps.hasGps, expected);
    // 回归护栏：hasGps 曾写成 `!Platform.isWindows`，把 macOS/Linux 误判为「有 GPS」。
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      expect(PlatformCaps.hasGps, isFalse);
    }
  });

  test('supportsFileSaveDialog = Windows/macOS（Linux 依赖 zenity 等外部程序，不开）', () {
    final expected = Platform.isWindows || Platform.isMacOS;
    expect(PlatformCaps.supportsFileSaveDialog, expected);
    if (Platform.isMacOS) {
      expect(PlatformCaps.supportsFileSaveDialog, isTrue,
          reason: 'macOS 走原生 NSSavePanel，导出必须能弹「另存为」');
    }
    if (Platform.isLinux) {
      expect(PlatformCaps.supportsFileSaveDialog, isFalse);
    }
  });

  test('桌面宿主（macOS/Linux）无罗盘、无相机、无 GPS', () {
    if (Platform.isMacOS || Platform.isLinux) {
      expect(PlatformCaps.hasCompass, isFalse);
      expect(PlatformCaps.hasCamera, isFalse);
      expect(PlatformCaps.hasGps, isFalse);
      expect(PlatformCaps.isDesktop, isTrue);
    }
  });
}
