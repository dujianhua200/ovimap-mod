// v3.18 验收：字体不乱码 / 符号随线路旋转 / 间隙随倍率 / 字高可调。
import 'dart:convert' show latin1;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_validate.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/models/label_type.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/symbols/symbol_catalog.dart';

void main() {
  late Directory tmp;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = Directory.systemTemp.createTempSync('ov_v318');
    LabelStore.instance.setBaseDirForTest(tmp);
    AppPaths.setBaseForTest(tmp);
    LabelType.installCatalog(SymbolCatalog.fromTextSync(
        File('assets/dxf/lispblock.dxf').readAsStringSync()));
  });

  tearDown(() => AppPaths.clearForTest());

  /// 斜向线路：每段方向不同，用来验旋转。
  List<MapLabel> zigzag() => [
        MapLabel(
            typeId: 'gl003', seq: 1, lat: 32.0000, lon: 114.0000,
            lineGroupId: 'g', name: 'P1', distanceM: 52.7),
        MapLabel(
            typeId: 'gl003', seq: 2, lat: 32.0008, lon: 114.0020,
            lineGroupId: 'g', name: 'P2', distanceM: 32.6),
        MapLabel(
            typeId: 'gl003', seq: 3, lat: 32.0022, lon: 114.0025,
            lineGroupId: 'g', name: 'P3', distanceM: 40.5),
        MapLabel(
            typeId: 'gl003', seq: 4, lat: 32.0030, lon: 114.0048,
            lineGroupId: 'g', name: 'P4', distanceM: 41.5),
        MapLabel(
            typeId: 'gl003', seq: 5, lat: 32.0022, lon: 114.0058,
            lineGroupId: 'g', name: 'P5', distanceM: 38.6),
      ];

  group('中文不再乱码（所有 TEXT 必须带中文样式）', () {
    test('每一处 TEXT 都写了 7<样式>，且样式是 SimSun/SongTi', () async {
      final r = await DxfExporter.export(
        name: 'font_ok',
        labels: zigzag(),
        version: DxfVersion.r12,
        fixedScale: 3000,
        showLegend: true,
        showStakes: true,
      );
      final txt = latin1.decode(r.file.readAsBytesSync());
      final texts = _texts(txt);

      expect(texts, isNotEmpty);
      var noStyle = 0;
      final styleNames = <String>{};
      for (final body in texts) {
        final m = RegExp(r'^7\n([^\n]*)$', multiLine: true).firstMatch(body);
        if (m == null) {
          noStyle++;
        } else {
          styleNames.add(m.group(1)!);
        }
      }
      expect(noStyle, 0,
          reason: '所有 TEXT 都必须显式指定样式；'
              '否则落回 Standard(txt.shx) → 中文乱码。'
              '实际有 $noStyle 个没写样式');
      expect(styleNames.every((s) => s == 'SimSun' || s == 'SongTi'), isTrue,
          reason: '中文样式应只用 SimSun / SongTi，实际：$styleNames');
    });
  });

  group('符号随线路方向旋转', () {
    test('井随线旋转，杆保持正立', () async {
      // 斜向线路，交替放「杆」和「井」：杆正立、井跟线
      final mixed = <MapLabel>[];
      for (var i = 0; i < 6; i++) {
        mixed.add(MapLabel(
          typeId: i.isEven ? 'gl003' : 'gx005_y',
          seq: i + 1,
          lat: 32.0 + i * 0.0004,
          lon: 114.0 + i * 0.0005,
          lineGroupId: 'g',
          name: i.isEven ? 'P${i + 1}' : 'J${i + 1}',
        ));
      }
      final r = await DxfExporter.export(
        name: 'rot_mixed',
        labels: mixed,
        version: DxfVersion.r12,
        fixedScale: 3000,
        showLegend: false,
      );
      final txt = latin1.decode(r.file.readAsBytesSync());

      final byBlock = <String, Set<double>>{};
      for (final body in _inserts(txt)) {
        final nm = RegExp(r'^2\n([^\n]*)$', multiLine: true).firstMatch(body);
        final rot =
            RegExp(r'^50\n([-\d.]+)$', multiLine: true).firstMatch(body);
        if (nm != null && rot != null) {
          byBlock.putIfAbsent(nm.group(1)!, () => <double>{})
              .add(double.parse(rot.group(1)!));
        }
      }
      expect(byBlock['gl003'], isNotNull);
      expect(byBlock['gx005_y'], isNotNull);
      expect(byBlock['gl003']!.every((v) => v.abs() < 1e-6), isTrue,
          reason: '杆应正立（0°），实际 ${byBlock['gl003']}');
      expect(byBlock['gx005_y']!.any((v) => v.abs() > 5), isTrue,
          reason: '井应随线路方向旋转，实际 ${byBlock['gx005_y']}');
    });

    test('水平线路上井也不出现异常角度', () async {
      final flat = [
        for (var i = 0; i < 4; i++)
          MapLabel(
            typeId: 'gx005_y', seq: i + 1,
            lat: 32.0, lon: 114.0 + i * 0.0005,
            lineGroupId: 'g', name: 'J${i + 1}',
          ),
      ];
      final r = await DxfExporter.export(
        name: 'rot_flat',
        labels: flat,
        version: DxfVersion.r12,
        fixedScale: 3000,
        showLegend: false,
      );
      final txt = latin1.decode(r.file.readAsBytesSync());
      for (final body in _inserts(txt, 'BiaoQian')) {
        final m = RegExp(r'^50\n([-\d.]+)$', multiLine: true).firstMatch(body);
        if (m != null) {
          final v = double.parse(m.group(1)!);
          final ok = v < 5 || v > 355;
          expect(ok, isTrue, reason: '水平线路上井应≈0°，实际 $v');
        }
      }
    });
  });

  group('字高与标签倍率可调', () {
    test('distFontMm 生效：改 4.0 后 JuLi 字高为 4.0', () async {
      final r = await DxfExporter.export(
        name: 'font4',
        labels: zigzag(),
        version: DxfVersion.r12,
        fixedScale: 3000,
        distFontMm: 4.0,
        showLegend: false,
        showStakes: false,
      );
      final txt = latin1.decode(r.file.readAsBytesSync());
      final hs = <double>[];
      for (final body in _texts(txt, 'JuLi')) {
        final m = RegExp(r'^40\n([-\d.]+)$', multiLine: true).firstMatch(body);
        if (m != null) hs.add(double.parse(m.group(1)!));
      }
      expect(hs, isNotEmpty);
      for (final h in hs) {
        expect(h, closeTo(4.0, 0.01), reason: '字高应等于用户设定 4.0，实际 $h');
      }
    });

    test('symbolScale 生效：改 2.0 后 INSERT 缩放为 2.0', () async {
      final r = await DxfExporter.export(
        name: 'sym2',
        labels: zigzag(),
        version: DxfVersion.r12,
        fixedScale: 3000,
        symbolScale: 2.0,
        showLegend: false,
      );
      final txt = latin1.decode(r.file.readAsBytesSync());
      for (final body in _inserts(txt, 'BiaoQian')) {
        final m = RegExp(r'^41\n([-\d.]+)$', multiLine: true).firstMatch(body);
        if (m != null) {
          expect(double.parse(m.group(1)!), closeTo(2.0, 0.01),
              reason: '符号缩放应等于用户设定 2.0');
        }
      }
    });

    test('倍率变大时断开间隙同步变大（线始终贴着符号）', () async {
      Future<double> gapAt(double scale) async {
        final r = await DxfExporter.export(
          name: 'gap_$scale',
          labels: zigzag(),
          version: DxfVersion.r12,
          fixedScale: 3000,
          symbolScale: scale,
          showLegend: false,
        );
        final txt = latin1.decode(r.file.readAsBytesSync());
        final segs = _polylineSpans(txt, 'GanLu');
        if (segs.length < 2) return 0;
        // 第一段终点到第二段起点的距离 = 间隙
        final a = segs[0][1];
        final b = segs[1][0];
        final dx = b[0] - a[0], dy = b[1] - a[1];
        return (dx * dx + dy * dy) == 0 ? 0 : _hypot(dx, dy);
      }

      final g1 = await gapAt(1.0);
      final g2 = await gapAt(2.0);
      expect(g2, greaterThan(g1 * 1.5),
          reason: '倍率翻倍，间隙应明显变大（保证线不穿进符号）：'
              '1x=$g1 2x=$g2');
    });
  });

  group('结构合法', () {
    test('R12 / R2000 结构校验通过', () async {
      for (final v in [DxfVersion.r12, DxfVersion.r2000]) {
        final r = await DxfExporter.export(
          name: 'ok_${v.name}',
          labels: zigzag(),
          version: v,
          fixedScale: 3000,
          distFontMm: 2.5,
          symbolScale: 1.0,
        );
        final txt = latin1.decode(r.file.readAsBytesSync());
        expect(DxfStructureValidator.validate(txt, version: v), isEmpty,
            reason: '${v.name} 结构应合法');
      }
    });
  });
}

double _hypot(double a, double b) {
  final s = a * a + b * b;
  var x = s;
  if (x <= 0) return 0;
  var g = x;
  while ((g * g - x).abs() > 1e-9 * (x > 1 ? x : 1)) {
    g = (g + x / g) / 2;
  }
  return g;
}

/// 所有 TEXT 实体（可指定图层）的组码体。
List<String> _texts(String dxf, [String? layer]) =>
    _ents(dxf, 'TEXT', layer);

List<String> _inserts(String dxf, [String? layer]) =>
    _ents(dxf, 'INSERT', layer);

List<String> _ents(String dxf, String type, String? layer) {
  final out = <String>[];
  final lines = dxf.split('\n');
  String cur = '';
  var body = <String>[];
  void flush() {
    if (cur != type) {
      cur = '';
      body = [];
      return;
    }
    final joined = body.join('\n');
    if (layer != null) {
      final m = RegExp(r'^8\n([^\n]*)$', multiLine: true).firstMatch(joined);
      if ((m?.group(1) ?? '') != layer) {
        cur = '';
        body = [];
        return;
      }
    }
    out.add(joined);
    cur = '';
    body = [];
  }

  for (var i = 0; i + 1 < lines.length; i += 2) {
    if (lines[i].trim() == '0') {
      flush();
      cur = lines[i + 1].trim();
      continue;
    }
    body.add('${lines[i].trim()}\n${lines[i + 1]}');
  }
  flush();
  return out;
}

/// 指定图层每条多段线的 [首点, 末点]。
List<List<List<double>>> _polylineSpans(String dxf, String layer) {
  final out = <List<List<double>>>[];
  final ents = _ents(dxf, 'POLYLINE', layer);
  final lines = dxf.split('\n');
  // 简化：按 VERTEX 顺序取，遇到 SEQEND 收尾
  var pts = <List<double>>[];
  var inTarget = false;
  var type = '';
  var body = <String>[];
  void flush() {
    if (type == 'POLYLINE') {
      inTarget = false;
      final m = RegExp(r'^8\n([^\n]*)$', multiLine: true)
          .firstMatch(body.join('\n'));
      if ((m?.group(1) ?? '') == layer) inTarget = true;
      pts = <List<double>>[];
      type = '';
      body = [];
      return;
    }
    if (type == 'VERTEX' && inTarget) {
      final j = body.join('\n');
      final xm = RegExp(r'^10\n([-\d.]+)$', multiLine: true).firstMatch(j);
      final ym = RegExp(r'^20\n([-\d.]+)$', multiLine: true).firstMatch(j);
      if (xm != null && ym != null) {
        pts.add([double.parse(xm.group(1)!), double.parse(ym.group(1)!)]);
      }
      type = '';
      body = [];
      return;
    }
    if (type == 'SEQEND') {
      if (inTarget && pts.length >= 2) {
        out.add([pts.first, pts.last]);
      }
      inTarget = false;
      pts = <List<double>>[];
    }
    type = '';
    body = [];
  }

  for (var i = 0; i + 1 < lines.length; i += 2) {
    if (lines[i].trim() == '0') {
      flush();
      type = lines[i + 1].trim();
      continue;
    }
    body.add('${lines[i].trim()}\n${lines[i + 1]}');
  }
  flush();
  // 引用 ents 避免未使用告警
  assert(ents.length >= 0);
  return out;
}
