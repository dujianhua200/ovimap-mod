import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import '../geo/geo_util.dart';
import '../models/map_label.dart';
import '../services/photos.dart';
import '../services/store.dart';

/// 竣工照片册一键打包（ZIP）：按点位组织，附坐标距离表（CSV，UTF-8 BOM），
/// 直接发给结算/资料归档。结构：
///   照片册.csv        —— 序号/点位名称/类型/坐标/距上点/备注/照片数
///   photos/1_GK-1_1.jpg —— 每张照片按 "序号_点名_第几张" 命名，可溯源到点
class PhotoBookExporter {
  PhotoBookExporter._();

  static final _badNameChars = RegExp(r'[\\/:*?"<>|\s]');

  static Future<File> export(String name, List<MapLabel> labels) async {
    final hasPhoto = labels.any((l) => l.photoPaths.isNotEmpty);
    if (!hasPhoto) {
      throw Exception('当前项目没有挂接照片的点位（点属性 → 拍照取证）');
    }

    final archive = Archive();
    final sb = StringBuffer();
    sb.write('序号,点位名称,类型,纬度(WGS84),经度(WGS84),距上点(米),备注,照片数\r\n');

    var idx = 0;
    for (var i = 0; i < labels.length; i++) {
      final l = labels[i];
      if (l.photoPaths.isEmpty) continue;
      idx++;
      final disp = (l.name.trim().isNotEmpty ? l.name.trim() : l.type.name)
          .replaceAll(_badNameChars, '_');
      // 距上点：同链相邻点才有效
      var dist = '';
      if (i > 0 &&
          l.lineGroupId.isNotEmpty &&
          labels[i - 1].lineGroupId == l.lineGroupId) {
        final d = l.distanceM ??
            GeoUtil.haversine(
                labels[i - 1].lat, labels[i - 1].lon, l.lat, l.lon);
        dist = d.toStringAsFixed(1);
      }
      sb.write('$idx,${_esc(disp)},${_esc(l.type.name)},'
          '${l.lat.toStringAsFixed(8)},${l.lon.toStringAsFixed(8)},'
          '$dist,${_esc(l.note.trim())},${l.photoPaths.length}\r\n');

      for (var p = 0; p < l.photoPaths.length; p++) {
        final abs = await PhotoService.absPath(l.photoPaths[p]);
        final f = File(abs);
        if (!f.existsSync()) continue; // 文件丢失的引用跳过，不阻塞打包
        final bytes = f.readAsBytesSync();
        final ext = l.photoPaths[p].contains('.')
            ? l.photoPaths[p]
                .substring(l.photoPaths[p].lastIndexOf('.'))
                .toLowerCase()
            : '.jpg';
        final fn = 'photos/${idx}_$disp\_${p + 1}$ext';
        archive.addFile(ArchiveFile(fn, bytes.length, bytes));
      }
    }

    // CSV 带 UTF-8 BOM，Excel 直接打开不乱码
    final csvBytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(sb.toString())];
    archive.addFile(ArchiveFile('照片册.csv', csvBytes.length, csvBytes));

    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null || zipBytes.isEmpty) {
      throw Exception('照片册打包失败');
    }
    final dir = await LabelStore.instance.exportDir();
    final out = File('${dir.path}/${sanitizeName(name)}_照片册.zip');
    await robustWriteBytes(out, zipBytes);
    return out;
  }

  static String _esc(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }
}
