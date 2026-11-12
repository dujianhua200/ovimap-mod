import 'package:flutter/services.dart';

/// Windows 资源管理器文件拖放桥（T21）。
///
/// Flutter 的 `DragTarget` **只处理应用内拖拽**，收不到从资源管理器拖入的文件。
/// 零依赖方案：`windows/runner/` 侧 `DragAcceptFiles` + `WM_DROPFILES` 取路径，
/// 经 **MethodChannel `ovimap/drop`** 的 `openFiles(paths: List<String>)` 回调到 Dart。
///
/// 非 Windows 平台该方法永不触发（无副作用）；本类只做「通道 → 回调」的薄封装，
/// **不引入任何新依赖**。
class FileDrop {
  FileDrop._();

  /// 与 `windows/runner/flutter_window.cpp` 中的通道名**必须一致**。
  static const MethodChannel _channel = MethodChannel('ovimap/drop');

  static bool _registered = false;

  /// 注册拖放回调。重复调用只生效一次。
  ///
  /// [onDrop] 收到**文件绝对路径**列表（可能多个）。
  static void register(void Function(List<String> paths) onDrop) {
    if (_registered) return;
    _registered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'openFiles') return null;
      final args = call.arguments;
      final paths = <String>[];
      if (args is List) {
        for (final a in args) {
          if (a is String && a.trim().isNotEmpty) paths.add(a);
        }
      }
      if (paths.isNotEmpty) onDrop(paths);
      return null;
    });
  }
}
