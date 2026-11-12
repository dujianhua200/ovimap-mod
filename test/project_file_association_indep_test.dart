// T22：工程文件（.ovimap）——启动参数解析 + 导入/导出闭环。
// .ovimap 格式定义 = `collection_<id>.json` 的原文件（含 name/kind/labels/元信息）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/main.dart' show startupProjectFromArgs;
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';

void main() {
  group('startupProjectFromArgs：从启动参数挑出 .ovimap 路径', () {
    test('命中 .ovimap（含引号包裹 / 大小写不敏感）', () {
      expect(startupProjectFromArgs(<String>[r'C:\a\b.ovimap']),
          r'C:\a\b.ovimap');
      expect(
          startupProjectFromArgs(<String>['--flag', r'C:\x\工程.ovimap']),
          r'C:\x\工程.ovimap');
      expect(startupProjectFromArgs(<String>[r'"C:\x\a.OVIMAP"']),
          r'C:\x\a.OVIMAP');
    });

    test('无 .ovimap 参数 → 空串', () {
      expect(startupProjectFromArgs(<String>['--flag', 'noext']), '');
      expect(startupProjectFromArgs(const <String>[]), '');
      expect(startupProjectFromArgs(<String>[r'C:\x\a.dxf']), '');
    });
  });

  group('importProjectFile / buildProjectFile 闭环', () {
    late Directory dir;
    late AppState st;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('ovimap_ovimap');
      LabelStore.instance.setBaseDirForTest(dir);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
    });

    tearDown(() {
      AppPaths.clearForTest();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<File> writeOvimap(String name, int n) async {
      final f = File('${dir.path}/$name.ovimap');
      final labels = <Map<String, dynamic>>[
        for (var i = 0; i < n; i++)
          <String, dynamic>{
            'id': '$name-$i',
            'typeId': 'pipe',
            'seq': i + 1,
            'lat': 32.0 + i * 0.001,
            'lon': 114.0,
          },
      ];
      await f.writeAsString(jsonEncode(<String, dynamic>{
        'id': 'orig-id',
        'name': name,
        'kind': 'label',
        'folderId': '',
        'editMode': 'design',
        'labels': labels,
      }));
      return f;
    }

    test('导入 .ovimap → 新建工程并自动打开（不覆盖原 id）', () async {
      final f = await writeOvimap('甲工程', 3);
      final msg = await st.importProjectFile(f.path);
      expect(msg.contains('已导入并打开工程「甲工程」'), isTrue);
      expect(st.activeCollectionId.isNotEmpty, isTrue);
      expect(st.labels.length, 3);
      // 落盘为新 id 的 collection_<cid>.json（原文 id 不决定本地 id）。
      final raw = await st.store.readCollectionRaw(st.activeCollectionId);
      expect(raw, isNotNull);

      // 再导入一次 → 重名自动追加 (2)。
      final msg2 = await st.importProjectFile(f.path);
      expect(msg2.contains('甲工程(2)'), isTrue);
    });

    test('导出 .ovimap = collection 原文（可再导入）', () async {
      st.projectName = '乙工程';
      st.labels = <MapLabel>[
        for (var i = 0; i < 2; i++)
          MapLabel(
              typeId: 'pipe',
              seq: i + 1,
              lat: 32.0,
              lon: 114.0 + i * 0.001),
      ];
      final cid = await st.finishCollection();
      final out = await st.buildProjectFile(cid);
      expect(out, isNotNull);
      expect(out!.path.endsWith('.ovimap'), isTrue);
      final o = jsonDecode(await out.readAsString()) as Map;
      expect(o['labels'], isA<List>());
      expect((o['labels'] as List).length, 2);

      // 闭环：把导出的文件再导入，得到同样 2 点。
      final msg = await st.importProjectFile(out.path);
      expect(msg.contains('已导入并打开工程'), isTrue);
      expect(msg.contains('2 点'), isTrue);
    });

    test('不存在的路径 → 中文错误，不抛异常', () async {
      final msg = await st.importProjectFile('${dir.path}/nope.ovimap');
      expect(msg.contains('工程文件不存在'), isTrue);
    });

    test('格式错误（非 JSON / 缺 labels）→ 中文错误，不抛', () async {
      final bad = File('${dir.path}/bad.ovimap')
        ..writeAsStringSync('not-json{');
      final msg1 = await st.importProjectFile(bad.path);
      expect(msg1.contains('导入工程失败'), isTrue);

      final nolabels = File('${dir.path}/nolabels.ovimap')
        ..writeAsStringSync(jsonEncode(<String, dynamic>{'name': 'x'}));
      final msg2 = await st.importProjectFile(nolabels.path);
      expect(msg2.contains('缺少 labels 字段'), isTrue);
    });
  });

  group('openExternalFiles：按扩展名分派', () {
    late Directory dir;
    late AppState st;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('ovimap_drop');
      LabelStore.instance.setBaseDirForTest(dir);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
    });

    tearDown(() {
      AppPaths.clearForTest();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('.dxf / .csv → 明确「暂不支持」中文提示（不假装成功）', () async {
      final msg = await st.openExternalFiles(
          <String>[r'C:\x\a.dxf', r'C:\x\b.csv']);
      expect(msg.contains('DXF 导入暂不支持'), isTrue);
      expect(msg.contains('CSV 导入暂不支持'), isTrue);
    });

    test('未知扩展名 → 中文提示（支持类型列举）', () async {
      final msg = await st.openExternalFiles(<String>[r'C:\x\a.zip']);
      expect(msg.contains('不支持的文件类型'), isTrue);
    });
  });
}
