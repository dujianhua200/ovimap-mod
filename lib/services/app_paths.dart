import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

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

  /// path_provider 的当前实现（测试替换成 `FakePathProvider` 后与默认值不同）。
  ///
  /// 用它当**缓存钥匙**：`PathProviderPlatform.instance` 被换掉，就说明运行环境
  /// 变了（测试用例之间换临时目录），此前缓存的 `_cache` 必须作废。
  /// 否则会出现「同一进程里第二个用例仍然写进第一个用例的目录」这种串扰。
  static Object? _cachedProviderTag;

  /// 缓存是否仍然有效（环境未变且目录还在）。
  static bool _cacheValid() {
    final cached = _cache;
    if (cached == null) return false;
    if (!identical(_cachedProviderTag, PathProviderPlatform.instance)) {
      return false;
    }
    return cached.existsSync();
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
  ///
  /// ⚠️ **Windows 分支必须先检查 path_provider 是否被替换**：
  /// 直接读 `%APPDATA%` 会绕过 `PathProviderPlatform`，于是测试里设的
  /// `FakePathProvider(临时目录)` 完全失效——所有用例都写进真实的
  /// `%APPDATA%\ovimap`，单文件内多个用例互相污染（缓存命中态、脏地名等）。
  /// 这正是「同一份代码单跑绿、全量跑红」的根因。
  static Future<Directory> baseDir() async {
    if (_force != null) return _ensure(_force!);

    if (Platform.isWindows && _usesDefaultPathProvider) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        final d = await _ensure(Directory('$appData\\ovimap'));
        _cache = d;
        _cachedProviderTag = PathProviderPlatform.instance;
        return d;
      }
    }

    if (_cacheValid()) return _cache!;

    final Directory ext;
    if (Platform.isAndroid) {
      ext = await getExternalStorageDirectory() ??
          await getApplicationSupportDirectory();
    } else {
      ext = await getApplicationSupportDirectory();
    }
    final d = await _ensure(Directory('${ext.path}/ovimap'));
    _cache = d;
    _cachedProviderTag = PathProviderPlatform.instance;
    return d;
  }

  /// platform 实现是否就是出厂默认的 MethodChannel 实现。
  ///
  /// `MethodChannelPathProvider` 在 `path_provider_platform_interface` 的 `src/`
  /// 下、**没有导出**，所以不能直接做 `is` 判断。这里改用运行时类型名判断：
  /// 测试里的 fake 都是 `FakePathProvider` / `_FakePathProvider`，
  /// 名字不含 `MethodChannel`，判据干净且不依赖内部实现路径。
  static bool get _usesDefaultPathProvider {
    final name = PathProviderPlatform.instance.runtimeType.toString();
    return name.contains('MethodChannel');
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
