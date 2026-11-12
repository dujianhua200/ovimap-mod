/// 云同步数据模型（架构文档 §8.2 / §12）。
///
/// 本文件**只含纯数据 + 纯函数**（无 IO、无网络），便于零网络单测。
/// `rev` 为**服务端权威**的工程级、单调递增版本号；客户端把同步元数据存到
/// 设备本地旁路 `labels/sync_state.json`（见 [SyncStore]），**绝不写入 `index.json`**
/// （旧版 Android 的 `finishCollection()` 会重建 index.json 抹掉新字段，见 §5）。
library;

import '../ui/design_tokens.dart';

// ===================== 同步状态 =====================

/// 工程级同步状态。对应工程列表徽标 ✓ / ↑ / ⚠ / ●（架构文档 §12.4）。
enum SyncStatus { synced, pendingUpload, conflict, localOnly }

extension SyncStatusX on SyncStatus {
  /// 徽标字符：`✓` 已同步 / `↑` 待上传 / `⚠` 有冲突 / `●` 仅本地。
  String get badge => switch (this) {
        SyncStatus.synced => '✓',
        SyncStatus.pendingUpload => '↑',
        SyncStatus.conflict => '⚠',
        SyncStatus.localOnly => '●',
      };

  /// 中文说明（状态栏 / 面板用）。
  String get label => switch (this) {
        SyncStatus.synced => '已同步',
        SyncStatus.pendingUpload => '待上传',
        SyncStatus.conflict => '有冲突',
        SyncStatus.localOnly => '仅本地',
      };

  /// 徽标/圆点颜色（ARGB，与项目既有暗色主题一致）。
  int get argb => switch (this) {
        SyncStatus.synced => TokC.ok.value,
        SyncStatus.pendingUpload => TokC.warn.value,
        SyncStatus.conflict => TokC.danger.value,
        SyncStatus.localOnly => 0xFF9E9E9E,
      };
}

/// 状态名 → 枚举（持久化反序列化用，未知/缺省 → `localOnly`）。
SyncStatus syncStatusFromName(String? name) => switch (name) {
      'synced' => SyncStatus.synced,
      'pendingUpload' => SyncStatus.pendingUpload,
      'conflict' => SyncStatus.conflict,
      _ => SyncStatus.localOnly,
    };

// ===================== 旁路元数据 =====================

/// 单个工程的同步元数据（存 `labels/sync_state.json` 旁路文件）。
class SyncMeta {
  String cid;

  /// 服务端权威版本号。客户端首次同步前缺省按 0（架构文档 §5）。
  int rev;

  /// 最后修改时间（毫秒时间戳）。
  int updatedAt;

  /// 最后修改设备。
  String lastDeviceId;
  String lastDeviceName;

  /// 本工程的同步状态。
  SyncStatus status;

  SyncMeta({
    required this.cid,
    this.rev = 0,
    this.updatedAt = 0,
    this.lastDeviceId = '',
    this.lastDeviceName = '',
    this.status = SyncStatus.localOnly,
  });

  SyncMeta copyWith({
    int? rev,
    int? updatedAt,
    String? lastDeviceId,
    String? lastDeviceName,
    SyncStatus? status,
  }) =>
      SyncMeta(
        cid: cid,
        rev: rev ?? this.rev,
        updatedAt: updatedAt ?? this.updatedAt,
        lastDeviceId: lastDeviceId ?? this.lastDeviceId,
        lastDeviceName: lastDeviceName ?? this.lastDeviceName,
        status: status ?? this.status,
      );

  Map<String, dynamic> toJson() => {
        'rev': rev,
        'updatedAt': updatedAt,
        'lastDeviceId': lastDeviceId,
        'lastDeviceName': lastDeviceName,
        'status': status.name,
      };

  factory SyncMeta.fromJson(String cid, Map<String, dynamic> o) => SyncMeta(
        cid: cid,
        rev: (o['rev'] as num?)?.toInt() ?? 0,
        updatedAt: (o['updatedAt'] as num?)?.toInt() ?? 0,
        lastDeviceId: (o['lastDeviceId'] as String?) ?? '',
        lastDeviceName: (o['lastDeviceName'] as String?) ?? '',
        status: syncStatusFromName(o['status'] as String?),
      );
}

/// 离线队列操作类型。
class SyncOp {
  SyncOp._();
  static const upsert = 'upsert';
  static const delete = 'delete';
}

/// 离线待上传队列项（存 `labels/sync_queue.json`）。
class QueueItem {
  String cid;
  String op;
  int baseRev;
  int enqueuedAt;
  int attempts;
  String lastError;

  QueueItem({
    required this.cid,
    required this.op,
    this.baseRev = 0,
    required this.enqueuedAt,
    this.attempts = 0,
    this.lastError = '',
  });

  QueueItem copyWith({int? baseRev, int? attempts, String? lastError}) =>
      QueueItem(
        cid: cid,
        op: op,
        baseRev: baseRev ?? this.baseRev,
        enqueuedAt: enqueuedAt,
        attempts: attempts ?? this.attempts,
        lastError: lastError ?? this.lastError,
      );

  Map<String, dynamic> toJson() => {
        'cid': cid,
        'op': op,
        'baseRev': baseRev,
        'enqueuedAt': enqueuedAt,
        'attempts': attempts,
        'lastError': lastError,
      };

  factory QueueItem.fromJson(Map<String, dynamic> o) => QueueItem(
        cid: (o['cid'] as String?) ?? '',
        op: (o['op'] as String?) ?? SyncOp.upsert,
        baseRev: (o['baseRev'] as num?)?.toInt() ?? 0,
        enqueuedAt: (o['enqueuedAt'] as num?)?.toInt() ?? 0,
        attempts: (o['attempts'] as num?)?.toInt() ?? 0,
        lastError: (o['lastError'] as String?) ?? '',
      );
}

// ===================== 网络结果模型 =====================

/// 服务端索引条目（`GET /index` 的 `data.items[]`）。
class RemoteIndexEntry {
  String id;
  String name;
  String kind;
  String folder;
  int count;
  int rev;
  int updatedAt;
  String lastDeviceId;
  String lastDeviceName;
  bool deleted;

  RemoteIndexEntry({
    required this.id,
    this.name = '',
    this.kind = 'label',
    this.folder = '',
    this.count = 0,
    this.rev = 0,
    this.updatedAt = 0,
    this.lastDeviceId = '',
    this.lastDeviceName = '',
    this.deleted = false,
  });

  factory RemoteIndexEntry.fromJson(Map<String, dynamic> o) {
    final Object? d = o['deleted'];
    return RemoteIndexEntry(
      id: (o['id'] as String?) ?? '',
      name: (o['name'] as String?) ?? '',
      kind: (o['kind'] as String?) ?? 'label',
      folder: (o['folder'] as String?) ?? '',
      count: (o['count'] as num?)?.toInt() ?? 0,
      rev: (o['rev'] as num?)?.toInt() ?? 0,
      updatedAt: (o['updatedAt'] as num?)?.toInt() ?? 0,
      lastDeviceId: (o['lastDeviceId'] as String?) ?? '',
      lastDeviceName: (o['lastDeviceName'] as String?) ?? '',
      deleted: d == true || (d is num && d.toInt() == 1),
    );
  }
}

/// 版本信息（`GET /project/:id/history`）。
class VersionInfo {
  final int rev;
  final int updatedAt;
  final String deviceName;
  final int labelCount;
  final int size;

  const VersionInfo({
    required this.rev,
    this.updatedAt = 0,
    this.deviceName = '',
    this.labelCount = 0,
    this.size = 0,
  });

  factory VersionInfo.fromJson(Map<String, dynamic> o) => VersionInfo(
        rev: (o['rev'] as num?)?.toInt() ?? 0,
        updatedAt: (o['updatedAt'] as num?)?.toInt() ?? 0,
        deviceName: (o['deviceName'] as String?) ?? '',
        labelCount: (o['labelCount'] as num?)?.toInt() ?? 0,
        size: (o['size'] as num?)?.toInt() ?? 0,
      );
}

/// 单个工程快照（`GET /project/:id` 的 `data`）。
class ProjectSnapshot {
  final String id;
  final int rev;
  final int updatedAt;
  final String lastDeviceId;
  final String lastDeviceName;

  /// `collection_<id>.json` 原文（服务端存 R2 的内容）。
  final String payload;

  /// 工程元信息（name/kind/folder/editMode/count）。
  final Map<String, dynamic> meta;

  const ProjectSnapshot({
    required this.id,
    required this.rev,
    this.updatedAt = 0,
    this.lastDeviceId = '',
    this.lastDeviceName = '',
    required this.payload,
    this.meta = const <String, dynamic>{},
  });

  factory ProjectSnapshot.fromJson(Map<String, dynamic> data) {
    final Object? m = data['meta'];
    return ProjectSnapshot(
      id: (data['id'] as String?) ?? '',
      rev: (data['rev'] as num?)?.toInt() ?? 0,
      updatedAt: (data['updatedAt'] as num?)?.toInt() ?? 0,
      lastDeviceId: (data['lastDeviceId'] as String?) ?? '',
      lastDeviceName: (data['lastDeviceName'] as String?) ?? '',
      payload: (data['payload'] as String?) ?? '',
      meta: m is Map ? Map<String, dynamic>.from(m) : <String, dynamic>{},
    );
  }
}

/// 索引结果。
class IndexResult {
  final List<RemoteIndexEntry> items;
  const IndexResult(this.items);
}

/// 上传/删除结果（sealed）。
sealed class PutResult {
  const PutResult();
}

/// 成功：服务端接受，返回新的 `rev`。
class PutOk extends PutResult {
  final int rev;
  const PutOk(this.rev);
}

/// 冲突（409）：`baseRev != 服务端 rev`，保守不覆盖（架构文档 §4.6）。
class PutConflict extends PutResult {
  final int serverRev;
  final int serverUpdatedAt;
  final String serverDeviceName;
  final String serverDeviceId;
  const PutConflict({
    required this.serverRev,
    this.serverUpdatedAt = 0,
    this.serverDeviceName = '',
    this.serverDeviceId = '',
  });
}

/// 冲突信息（供冲突框展示：设备名 + 时间）。
class ConflictInfo {
  final String cid;
  final int localRev;
  final int localUpdatedAt;
  final String localDeviceName;
  final int serverRev;
  final int serverUpdatedAt;
  final String serverDeviceName;

  const ConflictInfo({
    required this.cid,
    this.localRev = 0,
    this.localUpdatedAt = 0,
    this.localDeviceName = '',
    this.serverRev = 0,
    this.serverUpdatedAt = 0,
    this.serverDeviceName = '',
  });
}

/// 冲突三选一（**默认 `saveCopy`**，架构文档 §4.6 / §12.5）。
enum ConflictChoice { keepCloud, keepLocal, saveCopy }

// ===================== 纯服务端逻辑（与 Worker 对齐） =====================
//
// 以下两个纯函数把「Worker 的关键判定」以 Dart 复刻，便于零网络单测；
// `cloudflare/src/index.js` 中保持同名/同语义，避免前后端判据漂移。

/// 乐观并发判定（工程**已存在**时）：仅当 `baseRev == 当前 rev` 才接受。
///
/// `baseRev` 缺失（`null`，旧版不带）→ 一律视为不匹配 → **保守不覆盖**
/// （架构文档 §5「旧版上传不带 baseRev → 已存在一律 409」）。
bool revAccepts({required int? baseRev, required int currentRev}) =>
    baseRev != null && baseRev == currentRev;

/// 快照保留：每工程只保留最近 [keep] 个 `rev`，返回**应删除**的 `rev`（升序）。
///
/// 输入无需有序；`keep <= 0` 视作「全删」（返回全部 rev）。
List<int> revsToPrune(List<int> revs, int keep) {
  if (keep <= 0) return List<int>.from(revs);
  final sorted = [...revs]..sort();
  if (sorted.length <= keep) return const <int>[];
  return sorted.sublist(0, sorted.length - keep);
}
