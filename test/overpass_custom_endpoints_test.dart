// 第二十三批：**自定义 Overpass 端点**（配合用户自建 Cloudflare 反代）。
//
// 背景：底图（建筑/道路，来自 OSM Overpass）内置端点全在境外，抓取慢且不稳。
// 用户可自建反代（Cloudflare Worker / 自建服务器），把地址填进 App，**优先走反代**。
//
// 覆盖（全部零网络，mock 注入）：
//  ① resolve 解析：resolve('')==builtin()；自定义在前、内置在后、无重复；多分隔符/空白处理
//  ② 接线：fetchFor 确实把 resolve(userCustom) 传给 fetchRaw（行为级 + 源级）
//  ③ 设置项持久化：AppState 存 / 取 / 清空
//  ④ URL 校验：非法地址的中文提示分支
//  ⑤ 回归：未配置时只用内置 6 个端点（请求集合与顺序不变）
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/overpass.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/state/app_state.dart';

// ---------------- 夹具 ----------------

const double kLat = 32.1264;
const double kLon = 114.0913;

List<MapLabel> _labels() => [
      MapLabel(typeId: 'pipe', seq: 1, lat: kLat, lon: kLon, lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe', seq: 2, lat: kLat, lon: kLon + 0.001, lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe', seq: 3, lat: kLat, lon: kLon + 0.002, lineGroupId: 'g'),
    ];

/// 一份**含数据**的 roads 应答（非空 `elements`，不会被"空答案闸门"拦下）。
String _roadsJson() => jsonEncode({
      'elements': [
        {
          'type': 'way',
          'geometry': [
            {'lat': kLat, 'lon': kLon - 0.002},
            {'lat': kLat, 'lon': kLon + 0.003},
          ],
          'tags': {'highway': 'trunk', 'name': '主干道'},
        },
      ],
    });

BasemapCache _tmpCache(String tag) {
  final dir = Directory.systemTemp.createTempSync(tag);
  addTearDown(() => dir.deleteSync(recursive: true));
  return BasemapCache(dir);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => OverpassClient.httpGetOverride = null);

  // ============ ① resolve 端点解析 ============

  group('① resolve 端点解析', () {
    test("resolve('') == builtin()：未配置语义与既有完全一致", () {
      expect(OverpassEndpoints.resolve(''), OverpassEndpoints.builtin(),
          reason: '空输入 ⇒ 只剩内置、顺序不变');
      expect(OverpassEndpoints.builtin().length, 6,
          reason: '内置固定 6 个（v3.5.0 起首位为自建 hzyt 反代）');
      expect(OverpassEndpoints.builtin().first,
          'https://hzyt.hainasi.eu.org/interpreter',
          reason: '自建反代排首位（国内直连最快；不可达时竞速自动回落）');
    });

    test('自定义在前、内置在后、无重复', () {
      final r = OverpassEndpoints.resolve(
          'https://a.example/api\nhttps://b.example/api');
      final builtin = OverpassEndpoints.builtin();
      expect(r.sublist(0, 2),
          ['https://a.example/api', 'https://b.example/api'],
          reason: '用户自定义端点优先排在最前');
      expect(r.sublist(2), builtin, reason: '内置端点原序退居其后（兜底）');
      expect(r.length, 2 + builtin.length);
      expect(r.toSet().length, r.length, reason: '无重复');
    });

    test('自定义里含内置项 → 去重且不重复追加', () {
      final builtin = OverpassEndpoints.builtin();
      final r = OverpassEndpoints.resolve('${builtin.first};https://x.example/api');
      expect(r.where((e) => e == builtin.first).length, 1, reason: '去重');
      expect(r.first, builtin.first,
          reason: '用户把它写在最前 ⇒ 仍在前（不因是内置而挪位）');
      expect(r.length, builtin.length + 1, reason: '仅新增 x.example 一个');
    });

    test('多分隔符（换行 / 逗号 / 分号）+ 空白行 / 多余空白', () {
      final r = OverpassEndpoints.resolve(
          ' https://a.example/api ,\n\n https://b.example/api ;\r\n  , https://c.example/api ; ');
      expect(r.sublist(0, 3), [
        'https://a.example/api',
        'https://b.example/api',
        'https://c.example/api',
      ], reason: '三类分隔符 + 空白行被正确拆分/忽略');
      expect(r.length, 3 + OverpassEndpoints.builtin().length);
    });

    test('splitCustom：保序、去空白、忽略空行', () {
      expect(OverpassEndpoints.splitCustom(''), isEmpty);
      expect(OverpassEndpoints.splitCustom('  \n  ;  ,  '), isEmpty);
      expect(OverpassEndpoints.splitCustom('x\ny,z;w'), ['x', 'y', 'z', 'w']);
    });
  });

  // ============ ② 接线到生产路径 ============

  group('② 接线（行为级 + 源级）', () {
    test('fetchFor 把自定义端点传给 Overpass 抓取（自定义优先）', () async {
      final cache = _tmpCache('ovp_eps_wire');
      final requestedHosts = <String>[];
      OverpassClient.httpGetOverride = (url, {headers}) async {
        requestedHosts.add(url.host);
        if (url.host == 'ovp.mydomain.example') {
          // ⚠️ http.Response 未声明 charset 时按 Latin-1 编码，含中文的 JSON
          //    会抛 "Contains invalid characters"，导致该端点被误判为失败。
          return http.Response(_roadsJson(), 200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              });
        }
        // 内置境外端点：模拟不可达
        throw const HttpException('mock: 内置境外端点不可达');
      };

      final data = await BasemapFetcher.fetchFor(
        _labels(),
        rangeM: 300,
        cache: cache,
        useTdt: false,
        // 重复项 + 换行，验证 resolve 去重也一并生效
        overpassEndpoints: 'https://ovp.mydomain.example/\n'
            'https://ovp.mydomain.example/',
      );

      expect(requestedHosts, contains('ovp.mydomain.example'),
          reason: '_load 确实把 resolve(userCustom) 传给了 fetchRaw（自定义端点被请求到）');
      expect(data.report.roads.state, FetchState.ok,
          reason: '自定义端点回了数据 ⇒ 抓取成功（若未接线则内置全灭 → failed）');
      expect(data.roads.length, greaterThan(0), reason: '解析出道路');
    });

    test('源级：basemap._load 传入 endpoints；dxf / dialogs 已接线', () async {
      final bm = await File('lib/export/basemap.dart').readAsString();
      expect(bm.contains('OverpassEndpoints.resolve(overpassEndpoints)'), isTrue,
          reason: 'fetchFor 内解析自定义端点');
      expect(bm.contains('fetchRawDetailed(query, endpoints: endpoints)'), isTrue,
          reason: '_load 把端点列表传给 Overpass 抓取');

      final dxf = await File('lib/export/dxf.dart').readAsString();
      expect(dxf.contains("String overpassEndpoints = ''"), isTrue,
          reason: 'export 新增参数（默认空，旧调用点行为不变）');
      expect(dxf.contains('overpassEndpoints: overpassEndpoints'), isTrue,
          reason: 'export 把端点透传给 fetchFor');

      final dlg = await File('lib/ui/dialogs.dart').readAsString();
      expect(dlg.contains('showOverpassEndpointsDialog'), isTrue);
      expect(dlg.contains('overpassEndpoints: overpassEndpoints'), isTrue,
          reason: 'DXF 导出选项：检测与导出都带上自定义端点');
      expect(dlg.contains('isValidEndpoint'), isTrue, reason: 'URL 校验接入');

      final menu = await File('lib/ui/settings_menu.dart').readAsString();
      expect(menu.contains('Overpass 端点'), isTrue, reason: '设置菜单入口');
      expect(menu.contains('showOverpassEndpointsDialog'), isTrue);

      final state = await File('lib/state/app_state.dart').readAsString();
      expect(
          state.contains("static const prefOverpassEndpoints = 'overpassEndpoints'"),
          isTrue);
    });
  });

  // ============ ③ 设置项持久化 ============

  group('③ AppState 设置项持久化', () {
    test('默认空 = 全内置；可存 / 取 / trim / 清空', () async {
      SharedPreferences.setMockInitialValues({});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());

      expect(st.overpassEndpoints, '', reason: '默认空 ⇒ 全走内置镜像');

      st.setOverpassEndpoints(
          'https://ovp.a.example/\nhttps://ovp.b.example/');
      expect(st.overpassEndpoints, contains('ovp.a.example'));
      expect(st.overpassEndpoints, contains('ovp.b.example'));
      expect(st.prefs.getString(AppState.prefOverpassEndpoints),
          contains('ovp.b.example'));

      st.setOverpassEndpoints('  https://ovp.c.example/  ');
      expect(st.overpassEndpoints, 'https://ovp.c.example/', reason: 'trim');

      st.setOverpassEndpoints('');
      expect(st.overpassEndpoints, '', reason: '清空 ⇒ 恢复内置');
      expect(st.prefs.getString(AppState.prefOverpassEndpoints), '');
    });
  });

  // ============ ④ URL 校验 ============

  group('④ URL 校验', () {
    test('仅接受 http:// / https:// 开头', () {
      expect(OverpassEndpoints.isValidEndpoint('https://ovp.xxx.com/'), isTrue);
      expect(OverpassEndpoints.isValidEndpoint('http://ovp.xxx.com'), isTrue);
      expect(OverpassEndpoints.isValidEndpoint('  https://ovp.xxx.com/  '),
          isTrue, reason: 'trim 后判定');
      expect(OverpassEndpoints.isValidEndpoint('ovp.xxx.com'), isFalse,
          reason: '漏协议头（最常见手误）判非法');
      expect(OverpassEndpoints.isValidEndpoint('https:/ovp.xxx.com'), isFalse);
      expect(OverpassEndpoints.isValidEndpoint('ftp://ovp.xxx.com'), isFalse);
      expect(OverpassEndpoints.isValidEndpoint(''), isFalse);
    });

    test('非法项可被逐条挑出（供 UI 中文提示）', () {
      final items = OverpassEndpoints.splitCustom(
          'https://ok.example/api\novp.bad.com\nftp://bad2.example');
      final invalid =
          items.where((e) => !OverpassEndpoints.isValidEndpoint(e)).toList();
      expect(invalid, ['ovp.bad.com', 'ftp://bad2.example']);
    });

    test('源级：设置对话框含中文非法提示与整体拦截分支', () async {
      final dlg = await File('lib/ui/dialogs.dart').readAsString();
      expect(dlg.contains('地址需以 http:// 或 https:// 开头'), isTrue);
      expect(dlg.contains('整体拦截'), isTrue, reason: '保存时非法项整体拦截（含说明）');
    });
  });

  // ============ ⑤ 回归：未配置行为不变 ============

  group('⑤ 回归（未配置）', () {
    test('resolve 结果恰为内置、顺序不变', () {
      expect(OverpassEndpoints.resolve(''), OverpassEndpoints.builtin());
      expect(OverpassEndpoints.resolve('   \n , ;  '),
          OverpassEndpoints.builtin(),
          reason: '纯空白/分隔符 ⇒ 等价未配置');
    });

    test('fetchFor 未配置 ⇒ 请求集合恰为内置端点集合', () async {
      final cache = _tmpCache('ovp_eps_reg');
      final requestedHosts = <String>{};
      OverpassClient.httpGetOverride = (url, {headers}) async {
        requestedHosts.add(url.host);
        throw const HttpException('mock 全灭');
      };

      await BasemapFetcher.fetchFor(_labels(),
          rangeM: 300, cache: cache, useTdt: false);

      final builtinHosts =
          OverpassEndpoints.builtin().map((e) => Uri.parse(e).host).toSet();
      expect(requestedHosts, builtinHosts,
          reason: '未配置 ⇒ 仅内置 6 个端点被请求（集合一致）');
    });

    test('fetchFor 端点列表与 defaults 对齐（内置 6 个，顺序不变）', () {
      final got = OverpassEndpoints.resolve('');
      final builtin = OverpassEndpoints.builtin();
      for (var i = 0; i < builtin.length; i++) {
        expect(got[i], builtin[i], reason: '第 $i 个端点顺序保持一致');
      }
      expect(got.length, builtin.length);
    });
  });
}
