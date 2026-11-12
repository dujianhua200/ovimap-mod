import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/device_identity.dart';
import '../services/store.dart';
import 'sync_api.dart';
import 'sync_models.dart';
import 'sync_store.dart';

/// 同步编排（架构文档 §4.5 / §8.2 / T15）。
///
/// 职责：启动拉索引比对、打开工程拉最新、保存后 debounce 上传、网络恢复拉取+冲洗
/// 离线队列、冲突三选一 resolve。**只做「读写工程文件 + 网络传输」**，不改任何业务语义
/// （DXF/链路/坐标/撤销栈一行不动）。
///
/// 依赖方向：`SyncController → SyncApi / SyncStore / DeviceIdentity / LabelStore`。
/// **不 import `AppState`**（避免与 `AppState → SyncController` 形成循环依赖）：
/// 拉取落盘后通过可选的 [onRemoteApplied] 回调请上层刷新列表/重载正在编辑的工程。
class SyncController extends ChangeNotifier {
  SyncController({
    LabelStore? store,
    SyncStore? syncStore,
    DeviceIdentity? identity,
    Duration? uploadDebounce,
  })  : _store = store ?? LabelStore.instance,
        _syncStore = syncStore ?? SyncStore(),
        _identity = identity ?? DeviceIdentity.instance,
        uploadDebounce = uploadDebounce ?? const Duration(seconds: 30);

  final LabelStore _store;
  final SyncStore _syncStore;
  final DeviceIdentity _identity;

  /// 保存后自动上传的 debounce（默认 30s，架构文档 §4.5；测试可注入 0）。
  Duration uploadDebounce;

  /// 是否自动轮询 `/ping`（默认开；测试可关）。
  bool autoPoll = true;

  /// `/ping` 轮询周期（默认 20s）。
  Duration pingInterval = const Duration(seconds: 20);

  /// 是否在 pullIndex 时把「仅本地存在」的工程自动排队首传（默认开）。
  bool autoUploadNewLocals = true;

  /// 远端快照落盘后的回调（由 `AppState` 注册：刷新列表 / 重载打开的工程）。
  Future<void> Function(String cid)? onRemoteApplied;

  Map<String, SyncMeta> _state = <String, SyncMeta>{};
  List<QueueItem> _queue = <QueueItem>[];

  bool _started = false;
  bool _online = false;
  bool _flushing = false;
  int? _lastSyncAt;
  int _pendingCount = 0;
  String _lastError = '';

  Timer? _debounce;
  final Set<String> _debounceCids = <String>{};
  Timer? _pingTimer;

  // ===================== 只读视图（均不抛异常） =====================

  DeviceIdentity get identity => _identity;

  /// 是否已配置可同步（令牌 + 服务器地址）。
  bool get configured => _identity.configured;

  /// 上次成功同步时间（毫秒），`null` 表示从未。
  int? get lastSyncAt => _lastSyncAt;

  /// 待上传数量（队列长度 + pendingUpload 状态的工程数）。
  int get pendingCount => _pendingCount;

  /// 网络是否可用（最近一次 /ping / 请求结果）。
  bool get online => _online;

  /// 最近一次错误（中文，供面板展示）。
  String get lastError => _lastError;

  /// 某工程的同步状态（未知 → `localOnly`）。
  SyncStatus statusFor(String cid) => _state[cid]?.status ?? SyncStatus.localOnly;

  /// 某工程的同步元数据（可能为 null）。
  SyncMeta? metaFor(String cid) => _state[cid];

  /// 全部状态快照（只读副本，供 UI 遍历）。
  Map<String, SyncMeta> get allMeta => Map<String, SyncMeta>.unmodifiable(_state);

  /// 汇总状态（工具栏圆点 / 状态栏用）：冲突 > 待上传 > 已同步 > 仅本地。
  SyncStatus get aggregateStatus {
    if (!_identity.configured) return SyncStatus.localOnly;
    var s = SyncStatus.synced;
    for (final m in _state.values) {
      if (m.status == SyncStatus.conflict) return SyncStatus.conflict;
      if (m.status == SyncStatus.pendingUpload) s = SyncStatus.pendingUpload;
    }
    return s;
  }

  /// 上次同步时间的展示串（`--` 表示从未）。
  String get lastSyncText {
    final t = _lastSyncAt;
    if (t == null || t <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${p2(d.month)}-${p2(d.day)} ${p2(d.hour)}:${p2(d.minute)}';
  }

  /// 设备名（未加载时给缺省）。
  String get deviceName =>
      _identity.deviceName.isEmpty ? DeviceIdentity.defaultDeviceName() : _identity.deviceName;

  SyncApi? _api() {
    if (!_identity.configured) return null;
    return SyncApi(
      base: _identity.serverBase,
      token: _identity.token,
      deviceId: _identity.deviceId,
      deviceName: _identity.deviceName,
    );
  }

  // ===================== 生命周期 =====================

  /// 启动：加载身份 + 旁路 → 已配置则拉索引 + 冲洗队列 + 起轮询定时器。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _identity.load();
    await _load();
    if (!_identity.configured) {
      notifyListeners();
      return;
    }
    await pullIndex();
    await flushQueue();
    _startPingTimer();
    notifyListeners();
  }

  /// 重新加载身份（设置页改完令牌后调用）。
  Future<void> reloadIdentity() async {
    await _identity.load();
    await _load();
    notifyListeners();
  }

  bool _disposed = false;

  /// dispose 后静默忽略通知。
  ///
  /// 防抖定时器触发后的 `_uploadOne` 是跨 await 的异步链：慢 runner（实测
  /// Windows CI）上测试/界面在 await 期间 dispose 掉控制器，回调恢复执行时
  /// 再调 [notifyListeners] 会命中 ChangeNotifier 的 debug 断言
  /// 「used after being disposed」。所有异步续体统一走本覆写收口。
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _pingTimer?.cancel();
    super.dispose();
  }

  // ===================== 内部：持久化 =====================

  Future<void> _load() async {
    _state = await _syncStore.loadState();
    _queue = await _syncStore.loadQueue();
    _recount();
  }

  Future<void> _persistState() => _syncStore.saveState(_state);

  Future<void> _persistQueue() => _syncStore.saveQueue(_queue);

  void _recount() {
    // 待上传 = 「在队列中的 cid」∪「状态为 pendingUpload 的 cid」去重计数
    // （同一工程既是队列项又标 pendingUpload 时只算一次）。
    final set = <String>{for (final q in _queue) q.cid};
    for (final e in _state.entries) {
      if (e.value.status == SyncStatus.pendingUpload) set.add(e.key);
    }
    _pendingCount = set.length;
  }

  void _setStatus(
    String cid,
    SyncStatus status, {
    int? rev,
    int? updatedAt,
    String? lastDeviceId,
    String? lastDeviceName,
  }) {
    final m = _state[cid] ?? SyncMeta(cid: cid);
    m.status = status;
    if (rev != null) m.rev = rev;
    if (updatedAt != null) m.updatedAt = updatedAt;
    if (lastDeviceId != null) m.lastDeviceId = lastDeviceId;
    if (lastDeviceName != null) m.lastDeviceName = lastDeviceName;
    _state[cid] = m;
  }

  // ===================== 拉取 =====================

  /// 拉工程索引并与本地比对（启动 / 回前台 / 手动同步）。
  Future<void> pullIndex() async {
    final api = _api();
    if (api == null) {
      _recount();
      notifyListeners();
      return;
    }
    try {
      final IndexResult idx = await api.fetchIndex();
      _online = true;
      _lastError = '';

      final local = await _store.loadIndex();
      final localIds = <String>{for (final m in local) m.id};
      final seen = <String>{};

      for (final e in idx.items) {
        if (e.id.isEmpty) continue;
        seen.add(e.id);
        final sm = _state[e.id];
        final localRev = sm?.rev ?? 0;
        final localHas = localIds.contains(e.id);
        final dirty = _isDirty(e.id);

        if (e.deleted) {
          // 云端软删除：本地干净且存在 → 跟随删除；本地有改动 → 冲突（保守不覆盖）。
          if (localHas && !dirty) {
            await _store.deleteCollection(e.id);
            _setStatus(e.id, SyncStatus.localOnly, rev: e.rev);
          } else if (localHas) {
            _setStatus(e.id, SyncStatus.conflict, rev: e.rev);
          }
          continue;
        }

        if (!localHas && !dirty) {
          // 本地没有 → 全新下载。
          await _downloadApply(api, e.id, e.rev);
        } else if (e.rev > localRev) {
          if (dirty) {
            // 双侧都变 → 冲突（不自动覆盖，弹框三选一）。
            _setStatus(e.id, SyncStatus.conflict, rev: localRev);
          } else {
            await _downloadApply(api, e.id, e.rev);
          }
        }
        // e.rev == localRev：无变化，保持现状。
      }

      // 本地有、云端无（且未软删）：从未同步过的工程 → 排队首传。
      if (autoUploadNewLocals) {
        for (final m in local) {
          if (seen.contains(m.id)) continue;
          final sm = _state[m.id];
          if (sm == null || sm.status == SyncStatus.localOnly) {
            _enqueue(m.id, SyncOp.upsert);
            _setStatus(m.id, SyncStatus.pendingUpload);
          }
        }
      }

      _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
    } on SyncApiException catch (e) {
      _lastError = e.message;
      if (e.status == 401) _online = false;
    } catch (e) {
      _online = false;
      _lastError = '$e';
    }
    await _persistState();
    await _persistQueue();
    _recount();
    notifyListeners();
  }

  /// 打开某工程时拉取该工程最新版本。
  Future<void> pullProject(String cid) async {
    final api = _api();
    if (api == null || cid.isEmpty) return;
    try {
      final snap = await api.fetchProject(cid);
      if (snap == null) return;
      _online = true;
      final localRev = _state[cid]?.rev ?? 0;
      final dirty = _isDirty(cid);
      if (snap.rev > localRev) {
        if (dirty) {
          _setStatus(cid, SyncStatus.conflict, rev: localRev);
        } else {
          await _downloadApply(api, cid, snap.rev);
        }
      }
      _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
    } catch (_) {}
    await _persistState();
    _recount();
    notifyListeners();
  }

  /// 下载并落盘单个工程快照；清同步元 + 出队。
  Future<void> _downloadApply(SyncApi api, String cid, int serverRev) async {
    final ProjectSnapshot? snap = await api.fetchProject(cid, rev: serverRev);
    if (snap == null) return;
    final meta = CollectionMeta(
      id: cid,
      name: (snap.meta['name'] as String?) ?? '',
      kind: (snap.meta['kind'] as String?) ?? 'label',
      folder: (snap.meta['folder'] as String?) ?? '',
      editMode: (snap.meta['editMode'] as String?) ?? 'design',
      count: (snap.meta['count'] as num?)?.toInt() ?? 0,
    );
    await _store.applyRemoteCollection(
      cid,
      snap.payload,
      meta: meta,
      syncTag: <String, dynamic>{
        'rev': snap.rev,
        'updatedAt': snap.updatedAt,
        'lastDeviceId': snap.lastDeviceId,
        'lastDeviceName': snap.lastDeviceName,
      },
    );
    _setStatus(
      cid,
      SyncStatus.synced,
      rev: snap.rev,
      updatedAt: snap.updatedAt,
      lastDeviceId: snap.lastDeviceId,
      lastDeviceName: snap.lastDeviceName,
    );
    _queue.removeWhere((q) => q.cid == cid);
    await _persistState();
    await _persistQueue();
    await onRemoteApplied?.call(cid);
  }

  // ===================== 上传 / 队列 =====================

  /// 本地保存工程后回调（由 `AppState` 触发）→ 标记待上传 + debounce 上传。
  void onLocalSaved(String cid) {
    if (cid.isEmpty) return;
    if (!_identity.configured) return; // 未配置同步：纯本地，不排队。
    _setStatus(cid, SyncStatus.pendingUpload,
        updatedAt: DateTime.now().millisecondsSinceEpoch);
    _enqueue(cid, SyncOp.upsert);
    _recount();
    notifyListeners();
    scheduleUpload(cid);
  }

  /// 本地删除工程后回调（软删除语义：`DELETE` → 服务端 rev+1）。
  void onLocalDeleted(String cid) {
    if (cid.isEmpty) return;
    if (!_identity.configured) return;
    _setStatus(cid, SyncStatus.pendingUpload,
        updatedAt: DateTime.now().millisecondsSinceEpoch);
    _enqueue(cid, SyncOp.delete);
    _recount();
    notifyListeners();
    scheduleUpload(cid);
  }

  /// 入队（同 `cid` 去重，后写覆盖；删除 op 覆盖先前的 upsert）。
  void _enqueue(String cid, String op) {
    final baseRev = _state[cid]?.rev ?? 0;
    _queue.removeWhere((q) => q.cid == cid);
    _queue.add(QueueItem(
      cid: cid,
      op: op,
      baseRev: baseRev,
      enqueuedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    unawaited(_persistQueue());
  }

  /// debounce 上传（多次保存合并为一次，默认 30s）。
  void scheduleUpload(String cid) {
    if (cid.isEmpty) return;
    _debounceCids.add(cid);
    _debounce?.cancel();
    _debounce = Timer(uploadDebounce, () {
      final cids = _debounceCids.toList();
      _debounceCids.clear();
      for (final c in cids) {
        unawaited(_uploadOne(c));
      }
    });
  }

  /// 立即可靠上传单个工程（跳过 debounce）。
  Future<void> uploadNow(String cid) async {
    final api = _api();
    if (api == null) return;
    final item = _firstOrNull((q) => q.cid == cid);
    if (item == null) return;
    await _pushItem(api, item);
    _recount();
    notifyListeners();
  }

  Future<void> _uploadOne(String cid) async {
    final api = _api();
    if (api == null) return;
    final item = _firstOrNull((q) => q.cid == cid);
    if (item == null) return;
    await _pushItem(api, item);
    _recount();
    notifyListeners();
  }

  /// 冲洗离线队列（按 `enqueuedAt` 升序逐条重放）。网络错误 → 中断本轮并保留。
  Future<void> flushQueue() async {
    if (_flushing) return;
    final api = _api();
    if (api == null) return;
    _flushing = true;
    try {
      final items = [..._queue]
        ..sort((a, b) => a.enqueuedAt.compareTo(b.enqueuedAt));
      for (final item in items) {
        final settled = await _pushItem(api, item);
        if (!settled) break; // 网络不可用：保留队列，中断本轮。
      }
      _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      _lastError = '';
    } finally {
      _flushing = false;
    }
    _recount();
    notifyListeners();
  }

  /// 手动同步（工具栏/面板）→ 拉索引 + 双向 + 冲洗队列。
  Future<void> manualSync() async {
    await _identity.load();
    await _load();
    final api = _api();
    if (api == null) {
      _recount();
      notifyListeners();
      return;
    }
    await pullIndex();
    await flushQueue();
    notifyListeners();
  }

  /// 网络从「无」变「有」：拉取 + 冲洗队列（`/ping` 轮询触发）。
  void onNetworkRestored() {
    _online = true;
    unawaited(pullIndex());
    unawaited(flushQueue());
    notifyListeners();
  }

  /// 「同步该工程」（工程右键）：先拉最新比对，再上传本机改动。
  Future<void> syncProject(String cid) async {
    if (cid.isEmpty) return;
    final api = _api();
    if (api == null) {
      await manualSync();
      return;
    }
    await pullProject(cid);
    // 拉取后若仍标为待上传（或本地脏）→ 上传本机。
    if (_isDirty(cid)) {
      await uploadNow(cid);
    }
    _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  // ===================== 版本历史 / 恢复（T20） =====================

  /// 拉取某工程的版本历史（`GET /project/:id/history`）。
  ///
  /// 返回 `null` 表示**未配置云同步**（调用方据此给中文提示）；
  /// 返回空列表表示「已配置但暂无历史」。网络/鉴权错误 → 返回 `null` 且记入
  /// [lastError]。**复用既有 [SyncApi.history]，不改其语义。**
  Future<List<VersionInfo>?> listHistory(String cid) async {
    if (cid.isEmpty) return const <VersionInfo>[];
    final api = _api();
    if (api == null) return null;
    try {
      final vs = await api.history(cid);
      _online = true;
      _lastError = '';
      return vs;
    } on SyncApiException catch (e) {
      _lastError = e.message;
      if (e.status == 401) _online = false;
      return null;
    } catch (e) {
      _online = false;
      _lastError = '$e';
      return null;
    } finally {
      notifyListeners();
    }
  }

  /// 恢复到指定版本（T20）：`POST /project/:id/restore` 生成**新 rev**（服务端定），
  /// 随后以服务端为准**直接落盘**该新版本（清本地待上传标记）→ 刷新本地工程，
  /// 再 `pullProject` 比对一次确保两端一致。
  ///
  /// 返回 `true` 表示恢复成功。**复用既有 [SyncApi.restore]，不改其语义。**
  Future<bool> restoreVersion(String cid, int rev) async {
    if (cid.isEmpty) return false;
    final api = _api();
    if (api == null) return false;
    try {
      final newRev = await api.restore(cid, rev);
      _online = true;
      // 恢复即「以服务端为准」：清掉本工程的待上传项，避免旧脏数据盖回去。
      _queue.removeWhere((q) => q.cid == cid);
      await _downloadApply(api, cid, newRev);
      await pullProject(cid); // 双保险：rev 相等时为 no-op
      _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      _lastError = '';
      _recount();
      notifyListeners();
      return true;
    } on SyncApiException catch (e) {
      _lastError = e.message;
      if (e.status == 401) _online = false;
      notifyListeners();
      return false;
    } catch (e) {
      _online = false;
      _lastError = '$e';
      notifyListeners();
      return false;
    }
  }

  // ===================== 冲突处理 =====================

  /// 构造冲突信息（供冲突框展示）。
  ConflictInfo conflictInfoFor(String cid, PutConflict c) => ConflictInfo(
        cid: cid,
        localRev: _state[cid]?.rev ?? 0,
        localUpdatedAt: _state[cid]?.updatedAt ?? 0,
        localDeviceName: _state[cid]?.lastDeviceName ?? deviceName,
        serverRev: c.serverRev,
        serverUpdatedAt: c.serverUpdatedAt,
        serverDeviceName: c.serverDeviceName,
      );

  /// 冲突三选一（架构文档 §4.6）。
  Future<void> resolve(String cid, ConflictChoice choice) async {
    final api = _api();
    if (api == null) return;
    try {
      switch (choice) {
        case ConflictChoice.keepCloud:
          final snap = await api.fetchProject(cid);
          if (snap != null) await _downloadApply(api, cid, snap.rev);
          break;
        case ConflictChoice.keepLocal:
          await _forceUpload(api, cid);
          break;
        case ConflictChoice.saveCopy:
          await _saveConflictCopy(api, cid);
          break;
      }
    } catch (e) {
      _lastError = '$e';
    }
    _queue.removeWhere((q) => q.cid == cid);
    await _persistQueue();
    await _persistState();
    _recount();
    notifyListeners();
  }

  /// 「保留本机」：用刚取的 serverRev 重传覆盖云端。
  Future<void> _forceUpload(SyncApi api, String cid) async {
    final snap = await api.fetchProject(cid);
    final serverRev = snap?.rev ?? 0;
    final body = await _buildPutBody(cid);
    if (body == null) return;
    final res = await api.putProject(
      cid,
      baseRev: serverRev,
      name: body.name,
      kind: body.kind,
      folder: body.folder,
      editMode: body.editMode,
      count: body.count,
      payload: body.payload,
      updatedAt: body.updatedAt,
    );
    if (res is PutOk) {
      _setStatus(cid, SyncStatus.synced,
          rev: res.rev,
          updatedAt: body.updatedAt,
          lastDeviceId: _identity.deviceId,
          lastDeviceName: _identity.deviceName);
      await _writeSyncTag(cid, res.rev, body.updatedAt);
    } else if (res is PutConflict) {
      _setStatus(cid, SyncStatus.conflict, rev: res.serverRev);
    }
  }

  /// 「另存冲突副本」（默认推荐）：本机改动另存为新工程，云端覆盖本工程。
  ///
  /// 返回新建副本的 `cid`（无本地内容时返回空串）。
  Future<String> _saveConflictCopy(SyncApi api, String cid) async {
    final local = await _store.loadCollection(cid);
    if (local.isEmpty) {
      // 没有可另存的内容 → 退化为「保留云端」。
      final snap = await api.fetchProject(cid);
      if (snap != null) await _downloadApply(api, cid, snap.rev);
      return '';
    }
    final name = await _store.loadCollectionName(cid);
    final kind = await _store.loadCollectionKind(cid);
    final meta = await _localMeta(cid);
    final stamp = _mmdd(DateTime.now());
    final copyName = '${name.isEmpty ? '未命名' : name}'
        '(本机-${_identity.deviceName} $stamp)';
    final newCid = await _store.finishCollection(
      existingId: '',
      name: copyName,
      kind: kind,
      folderId: meta?.folder ?? '',
      editMode: meta?.editMode ?? 'design',
      labels: local
          .map((e) => e.clone())
          .toList(), // 克隆，避免与打开中的草稿共享引用
      clearDraftNow: false,
    );
    _setStatus(newCid, SyncStatus.pendingUpload,
        updatedAt: DateTime.now().millisecondsSinceEpoch);
    _enqueue(newCid, SyncOp.upsert);
    // 云端覆盖本工程
    final snap = await api.fetchProject(cid);
    if (snap != null) await _downloadApply(api, cid, snap.rev);
    await _persistQueue();
    return newCid;
  }

  // ===================== 介质读写 =====================

  Future<CollectionMeta?> _localMeta(String cid) async {
    final cols = await _store.loadIndex();
    for (final m in cols) {
      if (m.id == cid) return m;
    }
    return null;
  }

  /// 组装上传体（读本地 `collection_<cid>.json` 原文 + 索引元信息）。
  Future<
      ({
        String name,
        String kind,
        String folder,
        String editMode,
        int count,
        String payload,
        int updatedAt,
      })?> _buildPutBody(String cid) async {
    final raw = await _store.readCollectionRaw(cid);
    if (raw == null) return null;
    final m = await _localMeta(cid);
    var count = m?.count ?? 0;
    try {
      final o = jsonDecode(raw);
      if (o is Map && o['labels'] is List) count = (o['labels'] as List).length;
    } catch (_) {}
    return (
      name: (m?.name.isNotEmpty ?? false)
          ? m!.name
          : await _store.loadCollectionName(cid),
      kind: m?.kind ?? 'label',
      folder: m?.folder ?? '',
      editMode: m?.editMode ?? 'design',
      count: count,
      payload: raw,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _writeSyncTag(String cid, int rev, int updatedAt) =>
      _store.writeSyncTag(cid, <String, dynamic>{
        'rev': rev,
        'updatedAt': updatedAt,
        'lastDeviceId': _identity.deviceId,
        'lastDeviceName': _identity.deviceName,
      });

  /// 推送单条队列项。返回 `true` 表示「已定案（成功/冲突/永久拒绝）」可出队；
  /// `false` 表示网络不可用 → 保留在队并中断本轮。
  Future<bool> _pushItem(SyncApi api, QueueItem item) async {
    try {
      if (item.op == SyncOp.delete) {
        final res = await api.deleteProject(item.cid, baseRev: item.baseRev);
        _queue.removeWhere((q) => q.cid == item.cid);
        if (res is PutConflict) {
          _setStatus(item.cid, SyncStatus.conflict, rev: res.serverRev);
        } else {
          _state.remove(item.cid);
        }
        await _persistQueue();
        await _persistState();
        return true;
      }

      final body = await _buildPutBody(item.cid);
      if (body == null) {
        // 本地文件已不存在（可能已被删除）：出队，避免死循环。
        _queue.removeWhere((q) => q.cid == item.cid);
        await _persistQueue();
        return true;
      }
      final res = await api.putProject(
        item.cid,
        baseRev: item.baseRev,
        name: body.name,
        kind: body.kind,
        folder: body.folder,
        editMode: body.editMode,
        count: body.count,
        payload: body.payload,
        updatedAt: body.updatedAt,
      );
      _queue.removeWhere((q) => q.cid == item.cid);
      if (res is PutConflict) {
        _setStatus(item.cid, SyncStatus.conflict, rev: res.serverRev);
      } else {
        final rev = (res as PutOk).rev;
        _setStatus(item.cid, SyncStatus.synced,
            rev: rev,
            updatedAt: body.updatedAt,
            lastDeviceId: _identity.deviceId,
            lastDeviceName: _identity.deviceName);
        await _writeSyncTag(item.cid, rev, body.updatedAt);
      }
      await _persistQueue();
      await _persistState();
      return true;
    } on SyncApiException catch (e) {
      // 4xx（非 409）：服务端永久拒绝 → 出队并记录（避免反复重试）。
      item.attempts += 1;
      item.lastError = e.message;
      _queue.removeWhere((q) => q.cid == item.cid);
      _setStatus(item.cid, SyncStatus.localOnly);
      await _persistQueue();
      await _persistState();
      return true;
    } catch (e) {
      // 网络错误 / 5xx：保留在队，中断本轮。
      item.attempts += 1;
      item.lastError = '$e';
      final i = _queue.indexWhere((q) => q.cid == item.cid);
      if (i >= 0) _queue[i] = item;
      await _persistQueue();
      _online = false;
      return false;
    }
  }

  // ===================== 工具 =====================

  bool _isDirty(String cid) =>
      (_state[cid]?.status == SyncStatus.pendingUpload) ||
      _queue.any((q) => q.cid == cid);

  QueueItem? _firstOrNull(bool Function(QueueItem) test) {
    for (final q in _queue) {
      if (test(q)) return q;
    }
    return null;
  }

  static String _mmdd(DateTime d) {
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${p2(d.month)}-${p2(d.day)}';
  }

  void _startPingTimer() {
    if (!autoPoll) return;
    _pingTimer ??= Timer.periodic(pingInterval, (_) async {
      final api = _api();
      if (api == null) return;
      final ok = await api.ping();
      if (ok && !_online) {
        onNetworkRestored();
      } else {
        _online = ok;
      }
    });
  }
}
