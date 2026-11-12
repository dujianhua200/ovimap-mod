import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 跨平台「权威数据目录」单点收口。
///
/// 所有落盘路径（工程数据、瓦片缓存、导出、本地底图、照片）都从这里派生，
/// 业务代码**禁止**直接调用 `getExternalStorageDirectory()` /
/// `getApplicationSupportDirectory()` / 手拼 `%APPDATA%`。
///
/// 目录结构（Windows 与 Android **逐字同构**，整目录拷贝即可互换）：
/// ```
/// <root>/
///   labels/
///     index.json  draft.json  folders.json
///     collection_<id>.json
///     export/     basemap/
///   tiles/
///   photos/          （Android 在「应用文档目录」下，其余在 <root> 下）
/// ```
///
/// - Android：`<外部存储>/ovimap`（与旧版完全一致，**权威**）
/// - Windows：`%APPDATA%\ovimap`（即 `C:\Users\<用户>\AppData\Roaming\ovimap`）
/// - 其它：`<应用支持目录>/ovimap`
class AppPaths {
  AppPaths._();

  /// 测试注入（`LabelStore.setBaseDirForTest` 转调此处）。
  /// 非空时所有路径都相对该目录派生，绕开 path_provider 插件依赖。
  static Directory? _force;

  /// 非注入场景下解析结果的缓存（避免重复调用插件/读环境变量）。
  static Directory? _cache;

  /// 测试专用：注入权威数据根目录。
  static void setBaseForTest(Directory dir) {
    _force = dir;
    _cache = null;
  }

  /// 测试专用：清除注入（测试收尾用，避免用例间串扰）。
  static void clearForTest() {
    _force = null;
    _cache = null;
  }

  static Future<Directory> _ensure(Directory d) async {
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  /// 权威数据根目录。
  ///
  /// - Android：`getExternalStorageDirectory() ?? getApplicationSupportDirectory()` → `<ext>/ovimap`
  ///   （与旧版一致，不得变）
  /// - Windows：`%APPDATA%\ovimap`
  /// - 其它：`getApplicationSupportDirectory()/ovimap`
  static Future<Directory> baseDir() async {
    if (_force != null) return _ensure(_force!);

    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        final d = await _ensure(Directory('$appData\\ovimap'));
        _cache = d;
        return d;
      }
    }

    final cached = _cache;
    if (cached != null && cached.existsSync()) return cached;

    final Directory ext;
    if (Platform.isAndroid) {
      ext = await getExternalStorageDirectory() ??
          await getApplicationSupportDirectory();
    } else {
      ext = await getApplicationSupportDirectory();
    }
    final d = await _ensure(Directory('${ext.path}/ovimap'));
    _cache = d;
    return d;
  }

  static Future<Directory> _sub(String name) async {
    final b = await baseDir();
    return _ensure(Directory('${b.path}/$name'));
  }

  /// `labels/`：工程数据（index/draft/folders/collection_*）所在目录。
  static Future<Directory> labelsDir() => _sub('labels');

  /// `tiles/`：瓦片磁盘缓存。
  static Future<Directory> tilesDir() => _sub('tiles');

  /// `labels/basemap/`：项目级底图缓存（跨草稿/跨次长期复用）。
  static Future<Directory> basemapDir() => _sub('labels/basemap');

  /// `labels/export/`：导出中间产物目录。
  static Future<Directory> exportDir() => _sub('labels/export');

  /// 现场取证照片目录。
  ///
  /// **为不动 Android 现状**：Android 仍落在「应用文档目录」下的 `photos/`
  /// （照片不参与跨端同步，`MapLabel.photoPaths` 只存相对文件名，互换不受影响）；
  /// Windows 落在 `%APPDATA%\ovimap\photos`。
  static Future<Directory> photosDir() async {
    if (_force != null) return _ensure(Directory('${_force!.path}/photos'));
    if (Platform.isWindows) {
      final b = await baseDir();
      return _ensure(Directory('${b.path}/photos'));
    }
    final docs = await getApplicationDocumentsDirectory();
    return _ensure(Directory('${docs.path}/photos'));
  }
}
