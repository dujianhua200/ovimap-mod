// QA 回归：地图首帧不得因 MapController.camera 未就绪而构建失败。
//
// 背景（flutter_map 8.3.2）：MapController.camera 在 FlutterMap 首次渲染前
// 会抛 `Exception: You need to have the FlutterMap widget rendered at least
// once before using the MapController.`（见 map_controller_impl.dart:64-68）。
// 若在 build 路径上**无条件**读取 `controller.camera`，该子树会在首帧构建时抛异常，
// release 包表现为地图区域变成错误占位（ErrorWidget），地图永久不渲染。
//
// 本文件为回归护栏：修复前 RED，修复后应 GREEN。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/services/store.dart';
import 'package:ovimap/services/tile_cache.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/home_page.dart';
import 'package:ovimap/ui/map/map_canvas.dart';

void main() {
  testWidgets('MapCanvas 首帧必须成功挂载 FlutterMap，且回传相机快照',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('qa_canvas_ff');
    LabelStore.instance.setBaseDirForTest(dir);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final st = AppState();
    final mc = MapController();
    MapCamera? seen;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MapCanvas(
          st: st,
          controller: mc,
          baseProvider: CacheTileProvider(
            sourceId: 'qa',
            urlTemplate: 'https://tile.invalid/{z}/{x}/{y}.png',
          ),
          onCameraChanged: (c) => seen = c,
        ),
      ),
    ));

    expect(tester.takeException(), isNull,
        reason: 'MapCanvas.build 不得在首帧抛异常（camera 尚未就绪）');
    expect(find.byType(FlutterMap), findsOneWidget,
        reason: '首帧即应挂载 FlutterMap');

    await tester.pump(const Duration(milliseconds: 400));
    expect(seen, isNotNull, reason: 'onMapReady 后应回传相机快照');
  });

  testWidgets('HomePage 初始化完成后地图应渲染（而非错误占位）', (tester) async {
    final dir = Directory.systemTemp.createTempSync('qa_home_ff');
    LabelStore.instance.setBaseDirForTest(dir);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final st = AppState();
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: st,
      child: const MaterialApp(home: HomePage()),
    ));
    await tester.pump();

    await tester.runAsync(() async {
      await st.init();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(st.inited, isTrue);
    expect(find.text('滑洲云图 启动中…'), findsNothing);
    expect(find.byType(FlutterMap), findsOneWidget,
        reason: '进入主界面后地图必须真实渲染');
  });
}
