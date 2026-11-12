import 'dart:io';

import 'app_paths.dart';

/// 现场取证照片存储：照片统一拷贝到照片目录下，
/// 文件名 = <labelId>_<时间戳>.<ext>，MapLabel.photoPaths 只存相对文件名。
/// 删除标签不删照片文件（撤销恢复后照片仍可用；孤儿文件可在设置里清理）。
///
/// 目录跨平台收口于 [AppPaths.photosDir]：Android 保持原路径（应用文档目录/photos），
/// Windows 落 `%APPDATA%\ovimap\photos`。
class PhotoService {
  static Directory? _dir;

  static Future<Directory> dir() async {
    if (_dir != null) return _dir!;
    final d = await AppPaths.photosDir();
    _dir = d;
    return d;
  }

  /// 把拍摄/选择的图片拷贝进 photos/，返回相对文件名；失败返回 null。
  static Future<String?> importFile(String labelId, String srcPath) async {
    try {
      final src = File(srcPath);
      if (!src.existsSync()) return null;
      final ext = srcPath.contains('.')
          ? srcPath.substring(srcPath.lastIndexOf('.')).toLowerCase()
          : '.jpg';
      final name =
          '${labelId}_${DateTime.now().millisecondsSinceEpoch}$ext';
      await src.copy('${(await dir()).path}/$name');
      return name;
    } catch (_) {
      return null;
    }
  }

  /// 相对文件名 → 绝对路径（文件不存在也返回路径，由展示层处理）。
  static Future<String> absPath(String relName) async =>
      '${(await dir()).path}/$relName';

  static Future<void> deleteFile(String relName) async {
    try {
      final f = File('${(await dir()).path}/$relName');
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  /// 清理孤儿照片（没有任何标签引用的文件），返回删除数量。设置页入口用。
  static Future<int> purgeOrphans(
      Iterable<Iterable<String>> referencedGroups) async {
    final referenced = <String>{};
    for (final g in referencedGroups) {
      referenced.addAll(g);
    }
    var n = 0;
    final d = await dir();
    for (final f in d.listSync()) {
      if (f is File && !referenced.contains(f.uri.pathSegments.last)) {
        try {
          await f.delete();
          n++;
        } catch (_) {}
      }
    }
    return n;
  }
}
