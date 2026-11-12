import 'dart:convert';
import 'dart:io';

import '../services/app_paths.dart';
import '../services/store.dart' show robustWriteAsString;
import 'sync_models.dart';

/// 同步元数据的**设备本地旁路存储**（架构文档 §4.3）。
///
/// ⭐ 关键设计：同步元数据（`rev`/`updatedAt`/`lastDeviceId/Name`/`status`）只写这里
/// （`labels/sync_state.json`）与离线队列（`labels/sync_queue.json`），**绝不写入
/// `index.json`**。原因：旧版 Android 的 `finishCollection()` 会**重建** `index.json`
/// 条目并整体重写该文件，会把未知新字段抹掉；而旁路文件旧版从不触碰，因此它才是
/// 客户端一侧的权威（服务端 `rev` 仍为唯一权威，见 §4.3）。
///
/// 路径一律经 [AppPaths]（硬约束 4：路径单点收口）。
class SyncStore {
  SyncStore();

  /// 旁路状态文件名。
  static const stateFile = 'sync_state.json';

  /// 离线队列文件名。
  static const queueFile = 'sync_queue.json';

  Future<File> _file(String name) async {
    final dir = await AppPaths.labelsDir();
    return File('${dir.path}/$name');
  }

  /// 读取同步状态（`cid -> SyncMeta`）。文件缺失/损坏 → 空表（缺省容错）。
  Future<Map<String, SyncMeta>> loadState() async {
    try {
      final f = await _file(stateFile);
      if (!f.existsSync()) return <String, SyncMeta>{};
      final dynamic decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return <String, SyncMeta>{};
      // 兼容两种形态：`{"projects": {...}}`（本实现）或直接 `{cid: {...}}`。
      final Object? rawProjects = decoded['projects'];
      final Map<String, dynamic> projects = rawProjects is Map
          ? Map<String, dynamic>.from(rawProjects)
          : Map<String, dynamic>.from(decoded);
      final out = <String, SyncMeta>{};
      projects.forEach((k, v) {
        if (v is Map) {
          out[k] = SyncMeta.fromJson(k, Map<String, dynamic>.from(v));
        }
      });
      return out;
    } catch (_) {
      return <String, SyncMeta>{};
    }
  }

  /// 写入同步状态。
  Future<void> saveState(Map<String, SyncMeta> state) async {
    try {
      final f = await _file(stateFile);
      final projects = <String, dynamic>{
        for (final e in state.entries) e.key: e.value.toJson(),
      };
      await robustWriteAsString(f, jsonEncode({'projects': projects}));
    } catch (_) {}
  }

  /// 读取离线队列。缺失/损坏 → 空表。
  Future<List<QueueItem>> loadQueue() async {
    try {
      final f = await _file(queueFile);
      if (!f.existsSync()) return <QueueItem>[];
      final dynamic decoded = jsonDecode(await f.readAsString());
      if (decoded is! List) return <QueueItem>[];
      return [
        for (final e in decoded)
          if (e is Map) QueueItem.fromJson(Map<String, dynamic>.from(e)),
      ];
    } catch (_) {
      return <QueueItem>[];
    }
  }

  /// 写入离线队列。
  Future<void> saveQueue(List<QueueItem> queue) async {
    try {
      final f = await _file(queueFile);
      await robustWriteAsString(
          f, jsonEncode([for (final e in queue) e.toJson()]));
    } catch (_) {}
  }
}
