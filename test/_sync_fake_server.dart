// 零网络测试夹具：内存版 Worker（复刻 cloudflare/src/index.js 的语义）。
//
// 覆盖：Bearer 鉴权(401)、乐观并发(baseRev==rev 才接受，否则 409)、
// 软删除、/history、/restore、快照保留（复用 lib 的 revsToPrune 保证与 Worker 同判据）。
// 通过 SyncApi 的静态覆盖点注入，全程不发真实网络请求。
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:ovimap/sync/sync_api.dart';
import 'package:ovimap/sync/sync_models.dart';

class SnapshotRow {
  final int rev;
  final String payload;
  final String deviceId;
  final String deviceName;
  final int labelCount;
  final int createdAt;

  const SnapshotRow({
    required this.rev,
    required this.payload,
    this.deviceId = '',
    this.deviceName = '',
    this.labelCount = 0,
    required this.createdAt,
  });
}

class FakeProject {
  int rev = 0;
  String name = '';
  String kind = 'label';
  String folder = '';
  String editMode = 'design';
  int count = 0;
  int updatedAt = 0;
  String lastDeviceId = '';
  String lastDeviceName = '';
  bool deleted = false;
  int createdAt = 0;
  final Map<int, SnapshotRow> snapshots = <int, SnapshotRow>{};
}

/// 内存 Worker。
class FakeSyncServer {
  FakeSyncServer({this.token = 'tok-test', this.retention = 10});

  final String token;
  final int retention;
  final Map<String, FakeProject> projects = <String, FakeProject>{};

  /// 设为 true 时所有请求抛 [SocketException]（模拟断网）。
  bool offline = false;

  /// 请求日志（`GET /project/x` / `PUT /project/x` …），用于断言顺序。
  final List<String> log = <String>[];

  int get putCount => log.where((e) => e.startsWith('PUT ')).length;

  void install() {
    SyncApi.httpGetOverride = _get;
    SyncApi.httpSendOverride = _send;
  }

  void uninstall() {
    SyncApi.httpGetOverride = null;
    SyncApi.httpSendOverride = null;
  }

  // ---- 覆盖点 ----

  Future<http.Response> _get(Uri url, {Map<String, String>? headers}) async {
    // 断网请求根本没到服务端 → 不计入日志（仅记录真正到达的请求）。
    if (offline) throw const SocketException('offline');
    log.add('GET ${url.path}');
    if (!_authOk(headers)) return _resp(401, 401, null, 'unauth');
    final seg = _seg(url);
    if (seg.length == 1 && seg[0] == 'ping') {
      return _ok(<String, dynamic>{'serverTime': DateTime.now().millisecondsSinceEpoch});
    }
    if (seg.length == 1 && seg[0] == 'index') {
      final since = int.tryParse(url.queryParameters['since'] ?? '') ?? 0;
      final items = <Map<String, dynamic>>[];
      projects.forEach((id, p) {
        if (p.updatedAt > since) items.add(_indexItem(id, p));
      });
      return _ok(<String, dynamic>{'items': items});
    }
    if (seg.length == 2 && seg[0] == 'project') {
      final id = Uri.decodeComponent(seg[1]);
      final p = projects[id];
      if (p == null) return _resp(404, 404, null, 'not found');
      final revQ = url.queryParameters['rev'];
      final rev = revQ == null ? p.rev : (int.tryParse(revQ) ?? p.rev);
      final snap = p.snapshots[rev];
      return _ok(<String, dynamic>{
        'id': id,
        'rev': rev,
        'updatedAt': p.updatedAt,
        'lastDeviceId': p.lastDeviceId,
        'lastDeviceName': p.lastDeviceName,
        'meta': <String, dynamic>{
          'name': p.name,
          'kind': p.kind,
          'folder': p.folder,
          'editMode': p.editMode,
          'count': p.count,
          'deleted': p.deleted ? 1 : 0,
        },
        'payload': snap?.payload ?? '',
      });
    }
    if (seg.length == 3 && seg[0] == 'project' && seg[2] == 'history') {
      final id = Uri.decodeComponent(seg[1]);
      final p = projects[id];
      if (p == null) return _resp(404, 404, null, 'not found');
      final versions = p.snapshots.values.toList()
        ..sort((a, b) => b.rev.compareTo(a.rev));
      return _ok(<String, dynamic>{
        'versions': [
          for (final s in versions)
            <String, dynamic>{
              'rev': s.rev,
              'updatedAt': s.createdAt,
              'deviceName': s.deviceName,
              'labelCount': s.labelCount,
              'size': s.payload.length,
            }
        ]
      });
    }
    return _resp(404, 404, null, 'not found');
  }

  Future<http.Response> _send(String method, Uri url,
      {Map<String, String>? headers, Object? body}) async {
    final text = body == null ? null : (body is String ? body : jsonEncode(body));
    return handleSendRaw(method, url, headers: headers, bodyText: text);
  }

  /// 直接以「已序列化请求体文本」调用（供测试构造缺字段请求，如旧版不带 baseRev）。
  Future<http.Response> handleSendRaw(String method, Uri url,
      {Map<String, String>? headers, String? bodyText}) async {
    // 断网请求根本没到服务端 → 不计入日志（仅记录真正到达的请求）。
    if (offline) throw const SocketException('offline');
    log.add('$method ${url.path}');
    if (!_authOk(headers)) return _resp(401, 401, null, 'unauth');
    final Map<String, dynamic> b = bodyText == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(bodyText) as Map);
    final seg = _seg(url);
    if (seg.length == 2 && seg[0] == 'project') {
      final id = Uri.decodeComponent(seg[1]);
      if (method == 'PUT') return _put(id, b);
      if (method == 'DELETE') return _delete(id, b);
    }
    if (seg.length == 3 &&
        seg[0] == 'project' &&
        seg[2] == 'restore' &&
        method == 'POST') {
      return _restore(Uri.decodeComponent(seg[1]), b);
    }
    return _resp(404, 404, null, 'not found');
  }

  // ---- 语义 ----

  http.Response _put(String id, Map<String, dynamic> b) {
    final payload = (b['payload'] as String?) ?? '';
    final existing = projects[id];
    final baseRev = _optInt(b['baseRev']);

    if (existing == null) {
      final p = FakeProject()
        ..rev = 1
        ..name = (b['name'] ?? '').toString()
        ..kind = (b['kind'] ?? 'label').toString()
        ..folder = (b['folder'] ?? '').toString()
        ..editMode = (b['editMode'] ?? 'design').toString()
        ..count = _optInt(b['count']) ?? 0
        ..updatedAt = _optInt(b['updatedAt']) ?? _now()
        ..lastDeviceId = (b['deviceId'] ?? '').toString()
        ..lastDeviceName = (b['deviceName'] ?? '').toString()
        ..createdAt = _now();
      projects[id] = p;
      _snap(p, id, 1, payload, b);
      _prune(p, id);
      return _ok(<String, dynamic>{'rev': 1});
    }

    if (baseRev == null || baseRev != existing.rev) {
      return _conflict(existing);
    }
    existing
      ..rev = existing.rev + 1
      ..name = (b['name'] ?? existing.name).toString()
      ..kind = (b['kind'] ?? existing.kind).toString()
      ..folder = (b['folder'] ?? existing.folder).toString()
      ..editMode = (b['editMode'] ?? existing.editMode).toString()
      ..count = _optInt(b['count']) ?? existing.count
      ..updatedAt = _optInt(b['updatedAt']) ?? _now()
      ..lastDeviceId = (b['deviceId'] ?? '').toString()
      ..lastDeviceName = (b['deviceName'] ?? '').toString()
      ..deleted = false;
    _snap(existing, id, existing.rev, payload, b);
    _prune(existing, id);
    return _ok(<String, dynamic>{'rev': existing.rev});
  }

  http.Response _delete(String id, Map<String, dynamic> b) {
    final p = projects[id];
    if (p == null) return _resp(404, 404, null, 'not found');
    final baseRev = _optInt(b['baseRev']);
    if (baseRev == null || baseRev != p.rev) return _conflict(p);
    p
      ..rev = p.rev + 1
      ..deleted = true
      ..updatedAt = _now()
      ..lastDeviceId = (b['deviceId'] ?? '').toString()
      ..lastDeviceName = (b['deviceName'] ?? '').toString();
    return _ok(<String, dynamic>{'rev': p.rev});
  }

  http.Response _restore(String id, Map<String, dynamic> b) {
    final p = projects[id];
    if (p == null) return _resp(404, 404, null, 'not found');
    final wantRev = _optInt(b['rev']) ?? -1;
    final src = p.snapshots[wantRev];
    if (src == null) return _resp(404, 404, null, 'version not found');
    p
      ..rev = p.rev + 1
      ..deleted = false
      ..updatedAt = _now()
      ..lastDeviceId = (b['deviceId'] ?? '').toString()
      ..lastDeviceName = (b['deviceName'] ?? '').toString();
    p.snapshots[p.rev] = SnapshotRow(
      rev: p.rev,
      payload: src.payload,
      deviceId: p.lastDeviceId,
      deviceName: p.lastDeviceName,
      labelCount: src.labelCount,
      createdAt: _now(),
    );
    _prune(p, id);
    return _ok(<String, dynamic>{'rev': p.rev});
  }

  void _snap(FakeProject p, String id, int rev, String payload,
      Map<String, dynamic> b) {
    p.snapshots[rev] = SnapshotRow(
      rev: rev,
      payload: payload,
      deviceId: (b['deviceId'] ?? '').toString(),
      deviceName: (b['deviceName'] ?? '').toString(),
      labelCount: _optInt(b['count']) ?? 0,
      createdAt: _now(),
    );
  }

  void _prune(FakeProject p, String id) {
    final toDelete = revsToPrune(p.snapshots.keys.toList(), retention);
    for (final rv in toDelete) {
      p.snapshots.remove(rv);
    }
  }

  Map<String, dynamic> _indexItem(String id, FakeProject p) => <String, dynamic>{
        'id': id,
        'name': p.name,
        'kind': p.kind,
        'folder': p.folder,
        'count': p.count,
        'rev': p.rev,
        'updatedAt': p.updatedAt,
        'lastDeviceId': p.lastDeviceId,
        'lastDeviceName': p.lastDeviceName,
        'deleted': p.deleted ? 1 : 0,
      };

  // ---- 便捷断言辅助 ----

  /// 模拟「另一台设备」把某工程推进到 rev+1 并写入新内容。
  void bumpByOtherDevice(String id,
      {required String payload, String deviceName = '手机-信阳'}) {
    final p = projects[id];
    if (p == null) return;
    p
      ..rev = p.rev + 1
      ..updatedAt = _now()
      ..lastDeviceId = 'dev-other'
      ..lastDeviceName = deviceName
      ..deleted = false;
    p.snapshots[p.rev] = SnapshotRow(
        rev: p.rev, payload: payload, deviceName: deviceName, createdAt: _now());
  }

  // ---- 内部 ----

  bool _authOk(Map<String, String>? headers) {
    final h = headers?['Authorization'] ?? '';
    final tok = h.replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '').trim();
    return tok == token;
  }

  List<String> _seg(Uri url) =>
      url.path.split('/').where((s) => s.isNotEmpty).toList();

  static int? _optInt(Object? v) => v is num ? v.toInt() : null;
  static int _now() => DateTime.now().millisecondsSinceEpoch;

  http.Response _ok(Map<String, dynamic> data) => _resp(200, 0, data, 'ok');

  http.Response _conflict(FakeProject p) => _resp(
      409,
      409,
      <String, dynamic>{
        'serverRev': p.rev,
        'serverUpdatedAt': p.updatedAt,
        'serverDeviceId': p.lastDeviceId,
        'serverDeviceName': p.lastDeviceName,
      },
      'conflict');

  http.Response _resp(int status, int code, Object? data, String message) =>
      http.Response(
        jsonEncode(<String, dynamic>{'code': code, 'data': data, 'message': message}),
        status,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
}
