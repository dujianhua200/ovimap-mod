import 'dart:convert';
import 'dart:io';

import 'basemap.dart';
import 'local_basemap.dart';

/// 从「文件」导入本地开源矢量底图（GeoJSON）的 IO 层。
///
/// **职责边界**：只做 `文件 → 文本` 这一段的接线，并把文本交给**既有**落盘路径；
/// 解析与存储语义**完全复用** [GeoJsonImporter] / [LocalBasemapStore]，
/// 不改变任何既有口径（坐标、分级、裁剪、要素计数一律不变）。
///
/// 与 UI 解耦、**零网络**，便于用临时文件做单测。
///
/// **大文件策略**：整市底图可达十余 MB，导入时优先 `pickFiles(...)` 取 `path`
/// 后再 `File.readAsBytes`，避免 `withData: true` 把整份数据在内存里多拷贝一层；
/// 仅当平台只给 `content://`（无本地路径）时才回退读字节。
class BasemapFileImporter {
  BasemapFileImporter._();

  /// 单次导入的字节上限（约 150 MB）：超过即判定为「选错文件」提前拦下，
  /// 以免把内存打爆（正常 GeoJSON 底图远小于此，整市文件约 18 MB）。
  static const int maxBytes = 150 * 1024 * 1024;

  /// 文件字节 → 文本（UTF-8，容错 BOM 与非法字节）。
  ///
  /// - 去掉开头的 UTF-8 BOM（`EF BB BF`）：否则 `jsonDecode` 会把 `U+FEFF`
  ///   当非法字符直接抛错（`String.trim()` 并不会去掉 BOM）。
  /// - `allowMalformed: true`：非 UTF-8（如误选的 GBK 文本）**不在这里抛**，
  ///   而是交给 [GeoJsonImporter.parse] 以统一的 [FormatException] 报「不是合法 JSON」。
  static String decodeBytes(List<int> bytes) {
    if (bytes.isEmpty) return '';
    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3; // 跳过 UTF-8 BOM
    }
    return utf8.decode(bytes.sublist(start), allowMalformed: true);
  }

  /// 从本地路径读取文本；先校验大小，超过 [limit] 抛 [BasemapImportException]。
  ///
  /// [limit] 可注入（默认 [maxBytes]），便于单测构造「过大」分支。
  static Future<String> readTextFromPath(
    String path, {
    int limit = maxBytes,
  }) async {
    final file = File(path);
    final length = await file.length();
    if (length > limit) {
      throw BasemapImportException(
        '文件过大（${_mb(length)}，上限 ${_mb(limit)}）：'
        '请确认选的是 GeoJSON 底图，或先用工具裁剪到所需范围再导入。',
      );
    }
    return decodeBytes(await file.readAsBytes());
  }

  /// 把已读到的文本解析并落盘到项目级存储（与「粘贴/剪贴板」导入**同一条**落盘路径）。
  ///
  /// 失败语义与 [GeoJsonImporter.parse] 一致：非法输入抛 [FormatException]。
  static Future<BasemapData> importFromText(
    String raw, {
    String sourceName = '',
  }) async {
    final bm = GeoJsonImporter.parse(raw);
    final store = await LocalBasemapStore.open();
    await store.save(
      raw,
      sourceName: sourceName,
      roads: bm.roads.length,
      buildings: bm.buildings.length,
      places: bm.places.length,
    );
    return bm;
  }

  /// 从本地路径导入：读文本 → 解析 → 落盘。
  ///
  /// [sourceName] 缺省取路径末段文件名；[limit] 可注入以便单测。
  static Future<BasemapData> importFromPath(
    String path, {
    String? sourceName,
    int limit = maxBytes,
  }) async {
    final raw = await readTextFromPath(path, limit: limit);
    return importFromText(
      raw,
      sourceName: sourceName ?? basename(path),
    );
  }

  /// 从内存字节导入（部分平台选择器返回 `content://` 而无本地路径时的回退）。
  static Future<BasemapData> importFromBytes(
    List<int> bytes, {
    String sourceName = '',
  }) async {
    return importFromText(decodeBytes(bytes), sourceName: sourceName);
  }

  /// 取路径末段作默认来源文件名（手动解析，避免为取 basename 再引入依赖）。
  static String basename(String path) {
    final norm = path.replaceAll('\\', '/');
    final i = norm.lastIndexOf('/');
    return i >= 0 ? norm.substring(i + 1) : norm;
  }

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// 导入过程中的可读错误（如「文件过大」）。
///
/// [toString] 直接返回中文 [message]，UI 可原样展示。
class BasemapImportException implements Exception {
  const BasemapImportException(this.message);

  /// 面向用户的中文原因说明。
  final String message;

  @override
  String toString() => message;
}
