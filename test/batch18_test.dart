import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/search.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';

/// 第十八批 4 项（R1 范围档位/R2 保存后默认显示/R3 搜索距离排序/R4 临时标记+收藏）。
void main() {
  group('R3 搜索结果按距离排序', () {
    test('传入基准点：按 haversine 距离升序', () {
      // 基准点 (34.80, 114.35)；三个结果刻意乱序
      final near =
          const SearchResult(name: '近', address: '', lat: 34.8010, lon: 114.3510);
      final mid =
          const SearchResult(name: '中', address: '', lat: 34.8100, lon: 114.3600);
      final far =
          const SearchResult(name: '远', address: '', lat: 34.8300, lon: 114.4000);
      final out = SearchService.sortByDistance([far, near, mid, far],
          nearLat: 34.80, nearLon: 114.35);
      expect(out.map((e) => e.name).toList(), ['近', '中', '远', '远']);
      // 距离严格升序
      for (var i = 1; i < out.length; i++) {
        expect(
            SearchService.haversineM(
                    34.80, 114.35, out[i - 1].lat, out[i - 1].lon)
                .compareTo(SearchService.haversineM(
                    34.80, 114.35, out[i].lat, out[i].lon)),
            isNot(greaterThan(0)));
      }
    });

    test('不传基准点：保持原顺序（防御）', () {
      final a = const SearchResult(name: 'a', address: '', lat: 10, lon: 10);
      final b = const SearchResult(name: 'b', address: '', lat: 20, lon: 20);
      final c = const SearchResult(name: 'c', address: '', lat: 30, lon: 30);
      final out = SearchService.sortByDistance([c, a, b]);
      expect(out.map((e) => e.name).toList(), ['c', 'a', 'b']);
    });

    test('只传纬度/只传经度：不排序（参数成对才生效）', () {
      final a = const SearchResult(name: 'a', address: '', lat: 10, lon: 10);
      final b = const SearchResult(name: 'b', address: '', lat: 20, lon: 20);
      expect(
          SearchService.sortByDistance([b, a], nearLat: 34.80)
              .map((e) => e.name)
              .toList(),
          ['b', 'a']);
      expect(
          SearchService.sortByDistance([b, a], nearLon: 114.35)
              .map((e) => e.name)
              .toList(),
          ['b', 'a']);
    });
  });

  group('R2 保存后默认显示 / 编辑隐藏尊重选择', () {
    late Directory tmp;
    late AppState st;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ovimap_r2');
      LabelStore.instance.setBaseDirForTest(tmp);
      SharedPreferences.setMockInitialValues({});
      st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('新建保存：cid 进入 visibleCids 且持久化，overlayLabels 已加载', () async {
      st.projectName = '测试杆路';
      st.labels = [
        MapLabel(typeId: 'pipe', seq: 1, lat: 34.80, lon: 114.35, lineGroupId: 'g'),
        MapLabel(typeId: 'pipe', seq: 2, lat: 34.801, lon: 114.351, lineGroupId: 'g'),
      ];
      final cid = await st.finishCollection();

      // 自动进入显示列表并持久化
      expect(st.visibleCids.contains(cid), isTrue);
      expect(st.prefs.getString(AppState.prefVisible) ?? '', contains(cid));
      // 数据已加载，地图立刻可见
      expect(st.overlayLabels.containsKey(cid), isTrue);
      expect(st.overlayLabels[cid]!.length, 2);
      // 收藏内容落盘
      expect((await st.store.loadCollection(cid)).length, 2);
    });

    test('用户主动隐藏后编辑保存：尊重选择保持隐藏', () async {
      st.projectName = '隐藏测试';
      st.labels = [MapLabel(typeId: 'pipe', seq: 1, lat: 34.80, lon: 114.35)];
      final cid = await st.finishCollection();
      expect(st.visibleCids.contains(cid), isTrue);

      // 用户主动隐藏
      st.toggleVisible(cid);
      expect(st.visibleCids.contains(cid), isFalse);
      expect(st.overlayLabels.containsKey(cid), isFalse);

      // 从收藏夹打开编辑并再保存：必须保持隐藏
      final meta =
          (await st.store.loadIndex()).firstWhere((m) => m.id == cid);
      await st.openCollection(meta);
      st.labels
          .add(MapLabel(typeId: 'pipe', seq: 2, lat: 34.802, lon: 114.352));
      final cid2 = await st.finishCollection();
      expect(cid2, cid); // 编辑覆盖原工程
      expect(st.visibleCids.contains(cid), isFalse);
      expect(st.overlayLabels.containsKey(cid), isFalse);
      // 但文件内容已更新
      expect((await st.store.loadCollection(cid)).length, 2);
    });

    test('已在显示列表的工程编辑保存：数据刷新且保持显示', () async {
      st.projectName = '刷新测试';
      st.labels = [MapLabel(typeId: 'pipe', seq: 1, lat: 34.80, lon: 114.35)];
      final cid = await st.finishCollection();
      final meta =
          (await st.store.loadIndex()).firstWhere((m) => m.id == cid);
      await st.openCollection(meta);
      st.labels
          .add(MapLabel(typeId: 'pipe', seq: 2, lat: 34.802, lon: 114.352));
      await st.finishCollection();
      expect(st.visibleCids.contains(cid), isTrue);
      expect(st.overlayLabels[cid]!.length, 2);
    });
  });

  group('R4 搜索临时标记加入收藏', () {
    late Directory tmp;
    late AppState st;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ovimap_r4');
      LabelStore.instance.setBaseDirForTest(tmp);
      SharedPreferences.setMockInitialValues({});
      st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('保存为独立收藏：不污染草稿，点落盘，自动显示', () async {
      // 模拟用户正在编辑草稿
      st.labels = [
        MapLabel(typeId: 'pipe', seq: 1, lat: 34.80, lon: 114.35, name: 'GK-1'),
      ];
      final draftId = st.labels.first.id;

      final cid = await st.savePointAsCollection('丰乐园小区', 34.8100, 114.3600,
          note: '幸福路 88 号');

      // 草稿原样保留（长度不变、原点对象未动）
      expect(st.labels.length, 1);
      expect(st.labels.first.id, draftId);

      // 收藏内容：单点、名字、备注
      final saved = await st.store.loadCollection(cid);
      expect(saved.length, 1);
      expect(saved.first.name, '丰乐园小区');
      expect(saved.first.note, '幸福路 88 号');
      expect(saved.first.lat, 34.8100);
      expect(saved.first.lon, 114.3600);

      // 自动在地图显示（复用 R2 逻辑）
      expect(st.visibleCids.contains(cid), isTrue);
      expect(st.prefs.getString(AppState.prefVisible) ?? '', contains(cid));
      expect(st.overlayLabels[cid], isNotEmpty);

      // 收藏夹索引里有这条
      final idx = await st.store.loadIndex();
      expect(idx.any((m) => m.id == cid && m.name == '丰乐园小区'), isTrue);
    });

    test('重名自动追加 (2)：与手动保存同一规则', () async {
      final cid1 = await st.savePointAsCollection('丰乐园小区', 34.81, 114.36);
      final cid2 = await st.savePointAsCollection('丰乐园小区', 34.82, 114.37);
      expect(cid1, isNot(cid2));
      expect((await st.store.loadCollection(cid1)).first.name, '丰乐园小区');
      expect((await st.store.loadCollection(cid2)).first.name, '丰乐园小区(2)');
    });

    test('空名兜底「收藏点」，重名同样追加序号', () async {
      final cid1 = await st.savePointAsCollection('  ', 34.81, 114.36);
      expect((await st.store.loadCollection(cid1)).first.name, '收藏点');
      final cid2 = await st.savePointAsCollection('', 34.82, 114.37);
      expect((await st.store.loadCollection(cid2)).first.name, '收藏点(2)');
    });
  });

  group('R1 底图范围档位与自定义（源级接线断言）', () {
    test('档位含 30/50/100/200/300/500/880，强制回落逻辑已移除，自定义可持久化恢复', () async {
      final src = await File('lib/ui/dialogs.dart').readAsString();
      // 档位：30/50/100/200/300/500/880（v3.9.3 补 30/200 两档，线路设计常用）
      expect(src.contains('[30, 50, 100, 200, 300, 500, 880]'), isTrue);
      // 旧的四档（300/500/880/1000）已替换
      expect(src.contains('[300, 500, 880, 1000]'), isFalse);
      // 强制回落逻辑已移除：自定义值不再被重置为 880
      expect(
          src.contains('if (!rangeOptions.contains(rangeM)) rangeM = 880;'),
          isFalse);
      // 自定义入口 + 输入校验（20~5000）+ 确认即持久化
      expect(src.contains('_promptCustomRange'), isTrue);
      expect(src.contains('v < 20 || v > 5000'), isTrue);
      expect(src.contains("prefs.setDouble('dxfRangeM', v)"), isTrue);
      // 自定义值 UI 恢复显示
      expect(src.contains("自定义(\${rangeM.toInt()}m)"), isTrue);
      // 导出时仍以 rangeM 传给 DxfExporter（链路不变）
      expect(src.contains('rangeM: rangeM'), isTrue);
      // 既有持久化（导出确认时）保持
      expect(src.contains("prefs.setDouble('dxfRangeM', rangeM)"), isTrue);
    });

    test('R3/R4 页面接线断言（home_page）', () async {
      final src = await File('lib/ui/home_page.dart').readAsString();
      // R3：地图中心 WGS84 作为基准点传给搜索 + 距离显示
      expect(src.contains('nearLat: near[0], nearLon: near[1]'), isTrue);
      expect(src.contains('_fmtNearDist'), isTrue);
      // R4：临时标记（页面态）+ 信息面板 + 加入收藏/清除标记动作
      expect(src.contains('SearchResult? _searchMark'), isTrue);
      expect(src.contains('_showSearchMarkPanel'), isTrue);
      expect(src.contains("'清除标记'"), isTrue);
      expect(src.contains("'加入收藏'"), isTrue);
      expect(src.contains('savePointAsCollection'), isTrue);
    });

    test('store 草稿保护参数默认值不改变既有行为（源级断言）', () async {
      final src = await File('lib/services/store.dart').readAsString();
      expect(src.contains('bool clearDraftNow = true'), isTrue);
      expect(src.contains('if (clearDraftNow) await clearDraft();'), isTrue);
    });
  });
}
