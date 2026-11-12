import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'platform_caps.dart';

/// 「把生成好的文件交付给用户」的统一出口。
///
/// - **桌面（Windows）**：`file_picker.saveFile` 弹「另存为」，把 [file] 拷贝到
///   用户所选绝对路径（桌面没有「分享目标」语义）。
/// - **移动端**：`share_plus.shareXFiles`（现状不变）。
///
/// 业务代码**禁止**在 UI 里直接调用 `Share.*` 或 `FilePicker.saveFile`，
/// 一律经本类。返回 `true` 表示已成功交付；用户取消或失败返回 `false`。
class ExportSaver {
  ExportSaver._();

  /// 把 [file] 交付给用户。
  ///
  /// [suggestedName] 为「另存为」对话框的默认文件名；缺省取 [file] 的文件名。
  static Future<bool> saveOrShare(
    BuildContext context,
    File file, {
    String? suggestedName,
  }) async {
    // 在异步间隙之前拿到 messenger，避免跨 await 使用 BuildContext。
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!file.existsSync()) {
      _notify(messenger, '文件不存在，无法导出');
      return false;
    }
    final name = resolveSuggestedName(file, suggestedName);

    if (PlatformCaps.supportsFileSaveDialog) {
      return _saveAs(messenger, file, name);
    }
    return _share(messenger, file, name);
  }

  /// 计算交付用的默认文件名（纯函数，便于零插件单测）。
  ///
  /// [suggestedName] 为空 / 全空白时，回退到 [file] 的文件名。
  static String resolveSuggestedName(File file, String? suggestedName) {
    if (suggestedName == null || suggestedName.trim().isEmpty) {
      return file.uri.pathSegments.last;
    }
    return suggestedName.trim();
  }

  /// 若 [path] 不以 `.<ext>` 结尾，则补齐扩展名（个别平台不自动补）。
  ///
  /// [ext] 为空时原样返回。
  static String ensureExtension(String path, String ext) {
    if (ext.isEmpty) return path;
    if (path.toLowerCase().endsWith('.${ext.toLowerCase()}')) return path;
    return '$path.$ext';
  }

  /// 在系统文件管理器中打开目录（T21 批量导出后揭示产物位置）。
  ///
  /// - 桌面（Windows/macOS/Linux）：用系统命令打开资源管理器/Finder；
  /// - 移动端：无「打开文件夹」语义，返回 `false`（调用方仅展示路径）。
  ///
  /// 全程 `dart:io`，**零新增依赖**；失败一律静默返回 `false`（不抛）。
  static Future<bool> revealDirectory(Directory dir) async {
    try {
      if (!dir.existsSync()) return false;
      final String cmd;
      if (Platform.isWindows) {
        // explorer 对目录以「打开该文件夹」处理；返回码非 0 属正常，忽略。
        cmd = 'explorer';
      } else if (Platform.isMacOS) {
        cmd = 'open';
      } else if (Platform.isLinux) {
        cmd = 'xdg-open';
      } else {
        return false;
      }
      await Process.run(cmd, <String>[dir.path]);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 从文件名中取扩展名（无扩展名返回空串）。
  static String extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return (dot > 0 && dot < name.length - 1) ? name.substring(dot + 1) : '';
  }

  /// 桌面「另存为」：弹系统保存对话框 → 拷贝到目标路径。
  static Future<bool> _saveAs(
      ScaffoldMessengerState? messenger, File file, String name) async {
    try {
      final ext = extensionOf(name);
      final String? target = await FilePicker.platform.saveFile(
        dialogTitle: '另存为',
        fileName: name,
        type: ext.isEmpty ? FileType.any : FileType.custom,
        allowedExtensions: ext.isEmpty ? null : <String>[ext],
      );
      // 用户取消：target == null → 静默返回，不报错。
      if (target == null || target.trim().isEmpty) return false;

      // 个别平台不自动补扩展名，这里补齐，保证双击可用。
      final path = ensureExtension(target, ext);
      await file.copy(path);
      _notify(messenger, '已保存到：$path');
      return true;
    } catch (e) {
      _notify(messenger, '保存失败：$e');
      return false;
    }
  }

  /// 移动端「分享」（现状不变）。
  static Future<bool> _share(
      ScaffoldMessengerState? messenger, File file, String name) async {
    try {
      await Share.shareXFiles(<XFile>[XFile(file.path)], subject: name);
      return true;
    } catch (e) {
      _notify(messenger, '分享失败：$e');
      return false;
    }
  }

  static void _notify(ScaffoldMessengerState? messenger, String msg) {
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 2200),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(24, 0, 24, 120),
      ));
  }
}
