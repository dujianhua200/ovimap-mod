import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../geo/geo_util.dart';
import '../models/map_label.dart';
import 'app_paths.dart';

/// 收藏项索引元数据。
class CollectionMeta {
  String id;
  String name;
  String kind;
  int count;
  String folder;
  String editMode;
  int createdAt;
  int color;
  double width;
  String desc;

  /// 以下为云同步元数据（**纯加法**，旧版忽略即可）。服务端 `rev` 为唯一权威，
  /// 客户端权威存于 `labels/sync_state.json`；这里仅作可选镜像，`toJson` 仅在
  /// 非零/非空时输出，因此不影响既有索引文件。
  int rev;
  int updatedAt;
  String lastDeviceId;
  String lastDeviceName;

  CollectionMeta({
    required this.id,
    this.name = '',
    this.kind = 'label',
    this.count = 0,
    this.folder = '',
    this.editMode = 'design',
    this.createdAt = 0,
    this.color = 0,
    this.width = 0,
    this.desc = '',
    this.rev = 0,
    this.updatedAt = 0,
    this.lastDeviceId = '',
    this.lastDeviceName = '',
  });

  factory CollectionMeta.fromJson(Map<String, dynamic> o) => CollectionMeta(
        id: (o['id'] as String?) ?? '',
        name: (o['name'] as String?) ?? '',
        kind: (o['kind'] as String?) ?? 'label',
        count: (o['count'] as num?)?.toInt() ?? 0,
        folder: (o['folder'] as String?) ?? (o['folderId'] as String?) ?? '',
        editMode: (o['editMode'] as String?) ?? 'design',
        createdAt: (o['createdAt'] as num?)?.toInt() ?? 0,
        color: (o['color'] as num?)?.toInt() ?? 0,
        width: (o['width'] as num?)?.toDouble() ?? 0,
        desc: (o['desc'] as String?) ?? '',
        rev: (o['rev'] as num?)?.toInt() ?? 0,
        updatedAt: (o['updatedAt'] as num?)?.toInt() ?? 0,
        lastDeviceId: (o['lastDeviceId'] as String?) ?? '',
        lastDeviceName: (o['lastDeviceName'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind,
        'count': count,
        'folder': folder,
        'folderId': folder,
        'editMode': editMode,
        'createdAt': createdAt,
        if (color != 0) 'color': color,
        if (width > 0) 'width': width,
        if (desc.isNotEmpty) 'desc': desc,
        if (rev != 0) 'rev': rev,
        if (updatedAt != 0) 'updatedAt': updatedAt,
        if (lastDeviceId.isNotEmpty) 'lastDeviceId': lastDeviceId,
        if (lastDeviceName.isNotEmpty) 'lastDeviceName': lastDeviceName,
      };
}

class Folder {
  final String id;
  final String name;
  final String parentId;
  const Folder(this.id, this.name, [this.parentId = '']);
}

class DraftMeta {
  String projectName = '';
  String folderId = '';
  String editMode = 'design';
}

/// 数据持久化：草稿、收藏（标签/轨迹/测量数据）、文件夹。
/// 与旧版 Java 应用共用同一数据目录（同 applicationId），实现数据无缝迁移：
///   <external-files>/ovimap/labels/  draft.json / collection_*.json / index.json / folders.json
class LabelStore {
  LabelStore._();
  static final LabelStore instance = LabelStore._();

  static const kindLabel = 'label';
  static const kindTrack = 'track';
  static const kindData = 'data';
  static const kindArea = 'area';

  /// 测试专用：注入基础目录，绕过 path_provider 插件依赖（flutter_test 无插件）。
  /// 注入后本实例所有读写都落在该目录下的 labels/ 等子目录。
  /// 现转调 [AppPaths.setBaseForTest]（唯一磁盘注入点），既有 49 个用例的注入点不破。
  void setBaseDirForTest(Directory dir) {
    AppPaths.setBaseForTest(dir);
  }

  /// 权威数据根目录：委托 [AppPaths]（Android=`<外部存储>/ovimap`，Windows=`%APPDATA%\ovimap`）。
  Future<Directory> baseDir() => AppPaths.baseDir();

  Future<Directory> labelsDir() => AppPaths.labelsDir();

  Future<Directory> tilesDir() => AppPaths.tilesDir();

  Future<Directory> exportDir() => AppPaths.exportDir();

  /// 项目级底图缓存目录 `${labelsDir}/basemap`（跨草稿/跨次长期复用）。
  Future<Directory> basemapDir() => AppPaths.basemapDir();

  // ---- 草稿 ----

  Future<void> saveDraft(List<MapLabel> labels,
      [String projectName = '', String folderId = '', String editMode = 'design']) async {
    try {
      final dir = await labelsDir();
      final o = <String, dynamic>{
        'labels': labels.map((l) => l.toJson()).toList(),
        'projectName': projectName,
        'folderId': folderId,
        'editMode': editMode,
      };
      await robustWriteAsString(File('${dir.path}/draft.json'), jsonEncode(o));
    } catch (_) {}
  }

  Future<DraftMeta> loadDraftMeta() async {
    final meta = DraftMeta();
    try {
      final dir = await labelsDir();
      final f = File('${dir.path}/draft.json');
      if (!f.existsSync()) return meta;
      final o = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      meta.projectName = (o['projectName'] as String?) ?? '';
      meta.folderId = (o['folderId'] as String?) ?? '';
      meta.editMode = (o['editMode'] as String?) ?? 'design';
    } catch (_) {}
    return meta;
  }

  Future<List<MapLabel>> loadDraft() async {
    try {
      final dir = await labelsDir();
      final f = File('${dir.path}/draft.json');
      if (!f.existsSync()) return [];
      final o = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return (o['labels'] as List)
          .map((e) => MapLabel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> clearDraft() async {
    try {
      final dir = await labelsDir();
      final f = File('${dir.path}/draft.json');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // ---- 文件夹 ----

  Future<List<Folder>> loadFolders() async {
    final list = <Folder>[const Folder('', '默认')];
    try {
      final dir = await labelsDir();
      final f = File('${dir.path}/folders.json');
      if (!f.existsSync()) return list;
      final arr = jsonDecode(await f.readAsString()) as List;
      for (final o in arr.cast<Map<String, dynamic>>()) {
        list.add(Folder(
          (o['id'] as String?) ?? '',
          (o['name'] as String?) ?? '文件夹',
          (o['parentId'] as String?) ?? '',
        ));
      }
    } catch (_) {}
    return list;
  }

  Future<Folder> addFolder(String name, [String parentId = '']) async {
    var nm = name.trim();
    if (nm.isEmpty) nm = '文件夹';
    final folder = Folder(MapLabel().id, nm, parentId);
    final list = await loadFolders();
    final updated = [...list, folder];
    await _saveFolders(updated);
    return folder;
  }

  Future<void> renameFolder(String fid, String newName) async {
    final nm = newName.trim();
    if (nm.isEmpty) return;
    final list = await loadFolders();
    final updated = [
      for (final f in list)
        if (f.id == fid) Folder(f.id, nm, f.parentId) else f,
    ];
    await _saveFolders(updated);
  }

  /// 改文件夹的父级（拖拽移动）。目标是自己或自己后代时忽略（防环）。
  Future<void> setFolderParent(String fid, String parentId) async {
    if (fid == parentId) return;
    final list = await loadFolders();
    var p = parentId;
    final seen = <String>{};
    while (p.isNotEmpty && seen.add(p)) {
      if (p == fid) return; // 目标是自己的后代 → 拒绝
      final hit = list.where((e) => e.id == p).toList();
      p = hit.isEmpty ? '' : hit.first.parentId;
    }
    await _saveFolders([
      for (final f in list)
        if (f.id == fid) Folder(f.id, f.name, parentId) else f,
    ]);
  }

  /// 删除文件夹：**级联删整棵子树**（用户口径：删父文件夹连内部子文件夹
  /// 一起删），其中的工程上移到被删目录的父级——工程数据不丢。
  ///
  /// 返回 (被删文件夹数, 上移的工程数)，供 UI 弹窗与提示用。
  Future<(int, int)> deleteFolder(String fid) async {
    final list = await loadFolders();
    var parentId = '';
    for (final f in list) {
      if (f.id == fid) {
        parentId = f.parentId;
        break;
      }
    }

    // 收集整棵子树的 id（含自己）。
    final doomed = <String>{fid};
    var grew = true;
    while (grew) {
      grew = false;
      for (final f in list) {
        if (f.id.isNotEmpty && doomed.contains(f.parentId) && doomed.add(f.id)) {
          grew = true;
        }
      }
    }

    await _saveFolders([for (final f in list) if (!doomed.contains(f.id)) f]);

    // 子树内的工程上移到最外层被删目录的父级。
    var moved = 0;
    try {
      final items = await _loadIndexItems();
      for (final o in items) {
        final itemFolder =
            (o['folder'] as String?) ?? (o['folderId'] as String?) ?? '';
        if (doomed.contains(itemFolder)) {
          o['folder'] = parentId;
          o['folderId'] = parentId;
          moved++;
        }
      }
      if (moved > 0) await _saveIndexItems(items);
    } catch (_) {}
    return (doomed.length, moved);
  }

  Future<void> _saveFolders(List<Folder> list) async {
    try {
      final dir = await labelsDir();
      final arr = list
          .where((f) => f.id.isNotEmpty)
          .map((f) => {'id': f.id, 'name': f.name, 'parentId': f.parentId})
          .toList();
      await robustWriteAsString(File('${dir.path}/folders.json'), jsonEncode(arr));
    } catch (_) {}
  }

  // ---- 收藏索引 ----

  Future<List<CollectionMeta>> loadIndex() async {
    try {
      final items = await _loadIndexItems();
      return items.map(CollectionMeta.fromJson).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _loadIndexItems() async {
    final dir = await labelsDir();
    final f = File('${dir.path}/index.json');
    if (!f.existsSync()) return [];
    final s = (await f.readAsString()).trim();
    final dynamic decoded = jsonDecode(s);
    if (decoded is List) {
      // 兼容旧格式（纯数组）
      return decoded.cast<Map<String, dynamic>>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    final root = decoded as Map<String, dynamic>;
    final items = root['items'];
    if (items is! List) return [];
    return items.cast<Map<String, dynamic>>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> _saveIndexItems(List<Map<String, dynamic>> items) async {
    final dir = await labelsDir();
await robustWriteAsString(
        File('${dir.path}/index.json'), jsonEncode({'items': items}));
  }

  // ---- 收藏内容 ----

  /// 仅更新收藏文件中的 labels（拓扑连接编辑保存用），不动索引元数据。
  Future<void> saveCollectionLabels(String cid, List<MapLabel> labels) async {
    final dir = await labelsDir();
    final f = File('${dir.path}/collection_$cid.json');
    if (!f.existsSync()) return;
    try {
      final o =
          Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map);
      o['labels'] = labels.map((l) => l.toJson()).toList();
      await robustWriteAsString(f, jsonEncode(o));
    } catch (_) {}
  }

  Future<List<MapLabel>> loadCollection(String cid) async {
    try {
      final dir = await labelsDir();
      final f = File('${dir.path}/collection_$cid.json');
      if (!f.existsSync()) return [];
      final o = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return (o['labels'] as List)
          .map((e) => MapLabel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<String> loadCollectionKind(String cid) async {
    try {
      final dir = await labelsDir();
      final f = File('${dir.path}/collection_$cid.json');
      if (!f.existsSync()) return kindLabel;
      final o = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return (o['kind'] as String?) ?? kindLabel;
    } catch (_) {
      return kindLabel;
    }
  }

  Future<String> loadCollectionName(String cid) async {
    try {
      final dir = await labelsDir();
      final f = File('${dir.path}/collection_$cid.json');
      if (!f.existsSync()) return '';
      final o = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return (o['name'] as String?) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> deleteCollection(String cid) async {
    try {
      final dir = await labelsDir();
      final f = File('${dir.path}/collection_$cid.json');
      if (f.existsSync()) f.deleteSync();
      final items = await _loadIndexItems();
      final out = items.where((m) => cid != (m['id'] as String?)).toList();
      await _saveIndexItems(out);
    } catch (_) {}
  }

  // ---- 云同步（T13/T16）：原文读写 + 远端落盘。均为**纯加法**，不改既有语义。

  /// 读取 `collection_<cid>.json` 原文（云同步上传的 `payload`）。不存在 → `null`。
  ///
  /// 上传时**整文件原文**上云（含 `labels`、`distances` 等），保证跨端逐字一致。
  Future<String?> readCollectionRaw(String cid) async {
    try {
      final dir = await labelsDir();
      final f = File('${dir.path}/collection_$cid.json');
      if (!f.existsSync()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 在 `collection_<cid>.json` 顶层写入/更新旁路对象 `_sync`
  /// （`saveCollectionLabels` 只覆盖 `labels` 键，故该键对旧版天然保留，见 §4.3）。
  Future<void> writeSyncTag(String cid, Map<String, dynamic> syncTag) async {
    try {
      final dir = await labelsDir();
      final f = File('${dir.path}/collection_$cid.json');
      if (!f.existsSync()) return;
      final o =
          Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map);
      o['_sync'] = syncTag;
      await robustWriteAsString(f, jsonEncode(o));
    } catch (_) {}
  }

  /// 把远端快照落盘为本地工程（云同步拉取/冲突覆盖用）。
  ///
  /// - `collection_<cid>.json`：以 [payload] 原文为基底，写入 [meta] 的业务字段
  ///   （name/kind/folder/editMode）与旁路对象 `_sync`（便于调试 + 旧版天然保留）。
  /// - `index.json`：仅更新**业务字段**（name/kind/count/folder/editMode），
  ///   **绝不写入 `rev`/`updatedAt`/`lastDevice*`**——同步元数据权威在
  ///   `sync_state.json` 旁路（架构文档 §4.3 / §5，旧版兼容）。
  Future<void> applyRemoteCollection(
    String cid,
    String payload, {
    required CollectionMeta meta,
    Map<String, dynamic>? syncTag,
  }) async {
    final dir = await labelsDir();
    Map<String, dynamic> o;
    try {
      o = Map<String, dynamic>.from(jsonDecode(payload) as Map);
    } catch (_) {
      o = <String, dynamic>{};
    }
    o['id'] = cid;
    if (meta.name.isNotEmpty) o['name'] = meta.name;
    o['kind'] = meta.kind;
    o['folderId'] = meta.folder;
    o['editMode'] = meta.editMode;
    o['finished'] = true;
    o['createdAt'] = (o['createdAt'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    if (syncTag != null) o['_sync'] = syncTag;
    var count = meta.count;
    if (o['labels'] is List) count = (o['labels'] as List).length;
    await robustWriteAsString(
        File('${dir.path}/collection_$cid.json'), jsonEncode(o));

    // 索引条目：保留既有业务附加字段（color/width/desc/createdAt），不注入同步字段。
    final items = await _loadIndexItems();
    Map<String, dynamic>? existing;
    for (final it in items) {
      if (cid == (it['id'] as String?)) {
        existing = it;
        break;
      }
    }
    final entry = <String, dynamic>{
      'id': cid,
      'name': meta.name.isEmpty ? (existing?['name'] ?? '') : meta.name,
      'kind': meta.kind,
      'count': count,
      'folder': meta.folder,
      'folderId': meta.folder,
      'editMode': meta.editMode,
      'createdAt': (existing?['createdAt'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    };
    if (existing != null) {
      if (existing['color'] != null) entry['color'] = existing['color'];
      if (existing['width'] != null) entry['width'] = existing['width'];
      final d = existing['desc'];
      if (d is String && d.isNotEmpty) entry['desc'] = d;
    }
    final updated =
        items.where((m) => cid != (m['id'] as String?)).toList()..add(entry);
    await _saveIndexItems(updated);
  }

  Future<void> moveCollection(String cid, String folderId) async {
    try {
      final items = await _loadIndexItems();
      for (final o in items) {
        if (cid == (o['id'] as String?)) o['folder'] = folderId;
      }
      await _saveIndexItems(items);
    } catch (_) {}
  }

  /// 重命名收藏项目（同时更新 collection 文件内的 name）。
  Future<void> renameCollection(String cid, String newName) async {
    try {
      final items = await _loadIndexItems();
      for (final o in items) {
        if (cid == (o['id'] as String?)) o['name'] = newName;
      }
      await _saveIndexItems(items);
      final dir = await labelsDir();
      final f = File('${dir.path}/collection_$cid.json');
      if (f.existsSync()) {
        final o =
            Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map);
        o['name'] = newName;
        await robustWriteAsString(f, jsonEncode(o));
      }
    } catch (_) {}
  }

  /// 收藏项目线样式（颜色 ARGB / 宽度 dp），存入索引。
  Future<void> setCollectionStyle(String cid, int color, double widthDp) async {
    try {
      final items = await _loadIndexItems();
      for (final o in items) {
        if (cid == (o['id'] as String?)) {
          o['color'] = color;
          o['width'] = widthDp;
        }
      }
      await _saveIndexItems(items);
    } catch (_) {}
  }

  /// 更新索引中的点数（导入节点后同步）
  Future<void> setCollectionCount(String cid, int count) async {
    try {
      final items = await _loadIndexItems();
      for (final o in items) {
        if (cid == (o['id'] as String?)) o['count'] = count;
      }
      await _saveIndexItems(items);
    } catch (_) {}
  }

  Future<void> setCollectionDesc(String cid, String desc) async {
    try {
      final items = await _loadIndexItems();
      for (final o in items) {
        if (cid == (o['id'] as String?)) o['desc'] = desc;
      }
      await _saveIndexItems(items);
    } catch (_) {}
  }

  /// 保存收藏（新建或更新）。
  ///
  /// [clearDraftNow] 默认 true（正常保存收藏后清空草稿，行为不变）。
  /// 传 false 用于「临时点直接入收藏」等不经过草稿的保存场景——
  /// 保留用户正在编辑的草稿不被误清。
  Future<String> finishCollection({
    String existingId = '',
    required String name,
    required String kind,
    required String folderId,
    required String editMode,
    required List<MapLabel> labels,
    bool clearDraftNow = true,
  }) async {
    final cid = existingId.isEmpty ? MapLabel().id : existingId;
    final o = <String, dynamic>{
      'id': cid,
      'name': name,
      'kind': kind,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'finished': true,
      'folderId': folderId,
      'editMode': editMode,
      'labels': labels.map((l) => l.toJson()).toList(),
    };
    if (kindData == kind) {
      final segs = <Map<String, dynamic>>[];
      for (var i = 0; i < labels.length - 1; i++) {
        final p1 = labels[i];
        final p2 = labels[i + 1];
        final d = p2.distanceM ??
            GeoUtil.haversine(p1.lat, p1.lon, p2.lat, p2.lon);
        segs.add({'from': i, 'to': i + 1, 'dist': d});
      }
      o['distances'] = segs;
    }
    final dir = await labelsDir();
    await robustWriteAsString(File('${dir.path}/collection_$cid.json'), jsonEncode(o));

    final items = await _loadIndexItems();
    final updated =
        items.where((old) => cid != (old['id'] as String?)).toList();
    updated.add(CollectionMeta(
      id: cid,
      name: name,
      kind: kind,
      count: labels.length,
      folder: folderId,
      editMode: editMode,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ).toJson());
    await _saveIndexItems(updated);
    if (clearDraftNow) await clearDraft();
    return cid;
  }

  static double haversineQuick(double la1, double lo1, double la2, double lo2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(la2 - la1);
    final dLon = rad(lo2 - lo1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(la1)) * math.cos(rad(la2)) *
            math.sin(dLon / 2) * math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}


/// 健壮写文件：目标文件可能属主异常（旧版本/文件管理器创建，root:644）
/// 导致覆盖写 Permission denied。此时删除重建（目录可写即可）。
Future<void> robustWriteAsString(File f, String content) async {
  try {
    await f.writeAsString(content, flush: true);
  } catch (_) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    await f.writeAsString(content, flush: true);
  }
}

Future<void> robustWriteBytes(File f, List<int> bytes) async {
  try {
    await f.writeAsBytes(bytes, flush: true);
  } catch (_) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    await f.writeAsBytes(bytes, flush: true);
  }
}

/// 文件名清洗。
String sanitizeName(String? name) {
  var s = (name ?? 'export').trim();
  s = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  if (s.isEmpty) s = 'export';
  return s;
}
