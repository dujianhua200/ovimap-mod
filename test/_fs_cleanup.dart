// 测试清理助手：Windows 安全的临时目录删除。
//
// 背景：POSIX 允许删除仍被打开的文件，Windows 不允许 —— 若测试体结束时还有
// 异步写盘句柄未释放，`dir.deleteSync(recursive: true)` 会抛
// `PathAccessException: ... OS Error: The process cannot access the file because
// it is being used by another process, errno = 32`。
//
// 最容易踩到的是「同步 + 落盘」类用例：SyncController 带着 debounce 定时器与
// 在途 HTTP 请求，dispose() 之后仍可能有一次写盘正在收尾。
//
// 处理原则：退让重试若干次；仍失败只告警、不判红。理由是断言在清理之前早已
// 跑完，残留的临时目录由系统临时目录机制回收，属于基础设施噪音，
// 不该让整条构建流水线失败。
import 'dart:io';

/// 删除 [dir]（递归），失败时退让重试。
///
/// 目录本就不存在时直接返回。重试 [attempts] 次、每次间隔 [step]，
/// 最后一次仍失败则打印告警并返回（不抛）。
Future<void> deleteTempDirResilient(
  Directory dir, {
  int attempts = 10,
  Duration step = const Duration(milliseconds: 100),
}) async {
  for (var i = 0; i < attempts; i++) {
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException catch (e) {
      if (i == attempts - 1) {
        // ignore: avoid_print
        print('[warn] 临时目录清理失败（已重试 $attempts 次）：${dir.path} -> $e');
        return;
      }
      await Future<void>.delayed(step);
    }
  }
}
