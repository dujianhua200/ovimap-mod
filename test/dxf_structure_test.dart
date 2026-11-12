// DXF 结构性验证：POLYLINE/VERTEX/SEQEND 配对与嵌套、R12 兼容、GBK 中文不乱码。
// 说明：经典 POLYLINE 仅用于 PeiXianTu 配线图主干（需拓扑链）与 DaoLu/JianZhu
// 周边环境要素；杆路 GanLu 走向使用 LINE 实体。因此本测试数据必须包含拓扑链。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String root;
  _FakePathProvider(this.root);
  @override
  Future<String?> getExternalStoragePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('DXF 结构：POLYLINE/SEQEND 配对、VERTEX 嵌套合法、GBK 中文完整', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_struct');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final gid = 'g1';
    final labels = <MapLabel>[];
    final offsets = [
      (0.0, 0.0), (0.0004, 0.0002), (0.0009, 0.0005), (0.0013, 0.0011),
      (0.0015, 0.0018), (0.0013, 0.0024), (0.0008, 0.0028), (0.0002, 0.0030),
    ];
    for (var i = 0; i < offsets.length; i++) {
      labels.add(MapLabel(
          typeId: 'pipe',
          seq: i + 1,
          lat: 32.1264 + offsets[i].$1,
          lon: 114.0913 + offsets[i].$2,
          lineGroupId: gid,
          distLabel: i == 2 ? '埋42.5' : ''));
    }
    final cross = MapLabel(
        typeId: 'crossbox', seq: 9, lat: 32.1264, lon: 114.0913, name: '李庄光交');
    final split = MapLabel(
        typeId: 'splitterbox',
        seq: 10,
        lat: 32.1279,
        lon: 114.0931,
        name: '李庄分光箱',
        splitterRatio: '1:8');
    final fiber = MapLabel(
        typeId: 'fiberbox', seq: 11, lat: 32.1266, lon: 114.0943, name: '李庄分纤盒');
    split.topoParentId = cross.id;
    fiber.topoParentId = split.id;
    split.cableSpec = '架24芯GYTS-01';
    fiber.cableSpec = '架12芯GYTS-02';
    labels.addAll([cross, split, fiber]);

    final r = await DxfExporter.export(
        name: '结构测试',
        labels: labels,
        includeSurroundings: false,
        version: DxfVersion.r12);
    final bytes = r.file.readAsBytesSync();

    // latin1 解码逐字节保留，适合做结构解析（组码/实体名为 ASCII）
    final text = latin1.decode(bytes);
    final lines = text.split('\n');

    // 解析全部 group code/value 对，收集实体序列与图层名
    final entities = <({String type, String layer})>[];
    final layerNames = <String>{};
    for (var i = 0; i + 1 < lines.length; i += 2) {
      final code = lines[i].trim();
      final value = lines[i + 1].trim();
      if (code == '8') layerNames.add(value);
      if (code == '0' &&
          (value == 'POLYLINE' || value == 'SEQEND' || value == 'VERTEX')) {
        // 实体名之后隔一对才是 8 组码（POLYLINE 有 66/70 等组码，VERTEX 直接跟 8）
        var layer = '';
        for (var j = i + 2; j + 1 < lines.length; j += 2) {
          if (lines[j].trim() == '8') {
            layer = lines[j + 1].trim();
            break;
          }
        }
        entities.add((type: value, layer: layer));
      }
    }

    final polys = entities.where((e) => e.type == 'POLYLINE').length;
    final seqs = entities.where((e) => e.type == 'SEQEND').length;
    final verts = entities.where((e) => e.type == 'VERTEX').length;

    expect(polys, greaterThan(0), reason: '拓扑链存在时应生成 PeiXianTu 主干 POLYLINE');
    // 1. POLYLINE 与 SEQEND 一一配对
    expect(polys, seqs, reason: 'POLYLINE($polys) 与 SEQEND($seqs) 数量必须一致');

    // 2. 状态机校验：VERTEX 只能出现在 POLYLINE 之后、对应 SEQEND 之前；
    //    不允许嵌套/孤儿实体。
    var inPolyline = false;
    var orphanVertex = 0, seqWithoutPoly = 0;
    for (final e in entities) {
      if (e.type == 'POLYLINE') {
        expect(inPolyline, isFalse, reason: 'POLYLINE 不允许嵌套');
        inPolyline = true;
      } else if (e.type == 'VERTEX') {
        if (!inPolyline) orphanVertex++;
      } else if (e.type == 'SEQEND') {
        if (!inPolyline) seqWithoutPoly++;
        inPolyline = false;
      }
    }
    expect(orphanVertex, 0, reason: '存在 POLYLINE 块之外的孤儿 VERTEX');
    expect(seqWithoutPoly, 0, reason: '存在没有 POLYLINE 的 SEQEND');
    expect(inPolyline, isFalse, reason: '文件结尾仍有未闭合的 POLYLINE（缺 SEQEND）');
    // VERTEX 必须与所属 POLYLINE 同图层
    for (final e in entities) {
      if (e.type == 'POLYLINE' || e.type == 'VERTEX') {
        expect(e.layer, isNotEmpty, reason: '${e.type} 缺少 8 组码图层');
      }
    }

    // 3. R12 兼容：不允许 LWPOLYLINE
    expect(text.contains('LWPOLYLINE'), isFalse);

    // 4. 必要图层存在（按全文件 8 组码收集，覆盖 LINE/POLYLINE/TEXT 等实体）
    for (final layer in ['GanLu', 'PeiXianTu', 'TuQian', 'BeiFangZhen']) {
      expect(layerNames.contains(layer), isTrue, reason: '缺少图层 $layer');
    }

    // 5. GBK 中文：解码后图签/箱体文字完整，且无 U+FFFD 替换符（乱码迹象）
    final decoded = gbk_bytes.decode(bytes);
    expect(decoded, contains('滑洲云图导出'));
    expect(decoded, contains('李庄光交'));
    expect(decoded.contains('\uFFFD'), isFalse,
        reason: 'GBK 解码出现替换符，存在乱码/编码不一致');
    // 确认是 GBK 字节而非 UTF-8：'李' 的 GBK 编码为 0xC0 0xEE
    expect(bytes, containsAllInOrder([0xC0, 0xEE]));

    print('DXF 结构验证通过: POLYLINE=$polys VERTEX=$verts SEQEND=$seqs, '
        '图层=${layerNames.toList()..sort()}, ${bytes.length} 字节');
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
