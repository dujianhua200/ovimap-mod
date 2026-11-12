import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sync_models.dart';

/// 网络层异常：HTTP 非 2xx / 业务 `code != 0` / 无网。
class SyncApiException implements Exception {
  SyncApiException(this.status, this.message);

  /// HTTP 状态码或业务 code（401 / 5xx / 其它）。
  final int status;
  final String message;

  @override
  String toString() => 'SyncApiException($status): $message';
}

/// Worker HTTP 客户端（架构文档 §4.4 / §8.2）。
///
/// - 基址：`https://sync.<域名>`（专属子域指向独立 Worker）。
/// - 统一响应体 `{ "code": 0, "data": {...}, "message": "ok" }`。
/// - 鉴权：`Authorization: Bearer <token>` + `X-Device-Id` + `X-Device-Name`；
///   无令牌/令牌错 → **401**。
/// - 乐观并发：`PUT/DELETE` 带 `baseRev`，`baseRev != 服务端 rev` → **409**
///   （由调用方处理为 [PutConflict]）。
///
/// **零新增依赖**（用既有 `http`）。零网络测试：注入 [httpGetOverride] /
/// [httpSendOverride]（与项目既有 `OverpassClient.httpGetOverride` 同款覆盖点）。
class SyncApi {
  SyncApi({
    required this.base,
    required this.token,
    required this.deviceId,
    required this.deviceName,
  });

  /// 服务器基址（无尾部 `/`，例：`https://sync.example.com`）。
  final String base;
  final String token;
  final String deviceId;
  final String deviceName;

  // ---- 测试注入点（零网络） ----

  /// GET 覆盖点。
  static Future<http.Response> Function(Uri url, {Map<String, String>? headers})?
      httpGetOverride;

  /// 任意方法（PUT/DELETE/POST）覆盖点。
  static Future<http.Response> Function(String method, Uri url,
      {Map<String, String>? headers, Object? body})? httpSendOverride;

  // ---- 真实实现 ----

  static Future<http.Response> _realGet(Uri url,
          {Map<String, String>? headers}) =>
      http.get(url, headers: headers);

  static Future<http.Response> _realSend(String method, Uri url,
      {Map<String, String>? headers, Object? body}) async {
    final req = http.Request(method, url);
    if (headers != null) req.headers.addAll(headers);
    if (body != null) {
      req.body = body is String ? body : jsonEncode(body);
    }
    final streamed = await http.Client().send(req);
    return http.Response.fromStream(streamed);
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'X-Device-Id': deviceId,
        'X-Device-Name': deviceName,
        'Accept': 'application/json',
      };

  Uri _uri(String path, [Map<String, String>? query]) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final u = Uri.parse('$b$path');
    if (query == null || query.isEmpty) return u;
    return u.replace(queryParameters: {...u.queryParameters, ...query});
  }

  Future<http.Response> _get(Uri u) =>
      (httpGetOverride ?? _realGet)(u, headers: _headers);

  Future<http.Response> _send(String method, Uri u, {Object? body}) =>
      (httpSendOverride ?? _realSend)(method, u,
          headers: {
            ..._headers,
            if (body != null) 'Content-Type': 'application/json',
          },
          body: body);

  /// 解析统一响应体；401 直接抛（无有效令牌）。返回 `(status, envelope)`。
  ({int status, Map<String, dynamic>? env}) _parse(http.Response r) {
    Map<String, dynamic>? env;
    try {
      final dynamic decoded = jsonDecode(utf8.decode(r.bodyBytes));
      if (decoded is Map) env = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    if (r.statusCode == 401) {
      throw SyncApiException(401, '同步令牌无效或未配置（401）');
    }
    return (status: r.statusCode, env: env);
  }

  /// 非 2xx 且无法判定业务码，或业务码为「非 0 且非 409」→ 抛异常。
  void _throwIfBad(({int status, Map<String, dynamic>? env}) p) {
    final code = (p.env?['code'] as num?)?.toInt();
    if (p.status >= 400 && code == null) {
      throw SyncApiException(p.status, 'HTTP ${p.status}');
    }
    if (code != null && code != 0 && code != 409) {
      throw SyncApiException(code, (p.env?['message'] ?? '').toString());
    }
  }

  /// 从统一响应取 `data.rev`（缺省回退 [fallback]）。
  static int _dataRev(Map<String, dynamic>? env, int fallback) {
    final Object? data = env?['data'];
    if (data is Map) {
      final Object? rev = data['rev'];
      if (rev is num) return rev.toInt();
    }
    return fallback;
  }

  static PutConflict _conflictFrom(Map<String, dynamic>? env) {
    final Object? data = env?['data'];
    final m = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    return PutConflict(
      serverRev: (m['serverRev'] as num?)?.toInt() ?? 0,
      serverUpdatedAt: (m['serverUpdatedAt'] as num?)?.toInt() ?? 0,
      serverDeviceName: (m['serverDeviceName'] as String?) ?? '',
      serverDeviceId: (m['serverDeviceId'] as String?) ?? '',
    );
  }

  // ===================== API =====================

  /// `GET /ping`：连通性探测（网络异常/非 200 → false，不抛）。
  Future<bool> ping() async {
    try {
      final r = await _get(_uri('/ping'));
      final p = _parse(r);
      return p.status == 200 && ((p.env?['code'] as num?)?.toInt() ?? -1) == 0;
    } catch (_) {
      return false;
    }
  }

  /// `GET /index?since=<ms>`：工程索引（比对用）。
  Future<IndexResult> fetchIndex({int? since}) async {
    final r = await _get(
        _uri('/index', since != null ? {'since': '$since'} : null));
    final p = _parse(r);
    _throwIfBad(p);
    final Object? data = p.env?['data'];
    final Object? items = data is Map ? data['items'] : null;
    return IndexResult([
      if (items is List)
        for (final e in items)
          if (e is Map) RemoteIndexEntry.fromJson(Map<String, dynamic>.from(e))
    ]);
  }

  /// `GET /project/:id?rev=<n>`：取最新 / 指定版本快照。404 → `null`。
  Future<ProjectSnapshot?> fetchProject(String cid, {int? rev}) async {
    final r = await _get(
        _uri('/project/$cid', rev != null ? {'rev': '$rev'} : null));
    if (r.statusCode == 404) return null;
    final p = _parse(r);
    _throwIfBad(p);
    final Object? data = p.env?['data'];
    if (data is! Map) return null;
    return ProjectSnapshot.fromJson(Map<String, dynamic>.from(data));
  }

  /// `PUT /project/:id`：上传（乐观并发）。返回 [PutOk] / [PutConflict]。
  Future<PutResult> putProject(
    String cid, {
    required int baseRev,
    required String name,
    required String kind,
    required String folder,
    required String editMode,
    required int count,
    required String payload,
    required int updatedAt,
  }) async {
    final r = await _send('PUT', _uri('/project/$cid'), body: {
      'baseRev': baseRev,
      'name': name,
      'kind': kind,
      'folder': folder,
      'editMode': editMode,
      'count': count,
      'payload': payload,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'updatedAt': updatedAt,
    });
    final p = _parse(r);
    if ((p.env?['code'] as num?)?.toInt() == 409) return _conflictFrom(p.env);
    _throwIfBad(p);
    return PutOk(_dataRev(p.env, baseRev + 1));
  }

  /// `DELETE /project/:id`：软删除（rev+1）。返回 [PutOk] / [PutConflict]。
  Future<PutResult> deleteProject(String cid, {required int baseRev}) async {
    final r = await _send('DELETE', _uri('/project/$cid'), body: {
      'baseRev': baseRev,
      'deviceId': deviceId,
      'deviceName': deviceName,
    });
    final p = _parse(r);
    if ((p.env?['code'] as num?)?.toInt() == 409) return _conflictFrom(p.env);
    _throwIfBad(p);
    return PutOk(_dataRev(p.env, baseRev + 1));
  }

  /// `GET /project/:id/history`：版本历史。
  Future<List<VersionInfo>> history(String cid) async {
    final r = await _get(_uri('/project/$cid/history'));
    final p = _parse(r);
    _throwIfBad(p);
    final Object? data = p.env?['data'];
    final Object? versions = data is Map ? data['versions'] : null;
    return [
      if (versions is List)
        for (final e in versions)
          if (e is Map) VersionInfo.fromJson(Map<String, dynamic>.from(e))
    ];
  }

  /// `POST /project/:id/restore`：恢复到指定版本（生成新 rev）。
  Future<int> restore(String cid, int rev) async {
    final r = await _send('POST', _uri('/project/$cid/restore'), body: {
      'rev': rev,
      'deviceId': deviceId,
      'deviceName': deviceName,
    });
    final p = _parse(r);
    _throwIfBad(p);
    return _dataRev(p.env, rev);
  }
}
