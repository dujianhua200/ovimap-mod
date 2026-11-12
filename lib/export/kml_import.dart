import '../models/map_label.dart';

/// KML 解析结果：可直接追加进草稿的标签列表。
class KmlParseResult {
  final List<MapLabel> labels;
  final int pointCount;
  final int lineCount;

  KmlParseResult(this.labels, this.pointCount, this.lineCount);
}

/// KML 导入（奥维式双向：本项目也能吃进别人给的 KML）。
/// 零依赖解析：<Placemark> 内取 <name> 与 <coordinates>（lon,lat[,alt]），
/// <Point> → 单点标签，<LineString>/<LinearRing>/<MultiGeometry> 内坐标串 → 连线链。
/// KML 标准坐标即 WGS-84，无需换算。KMZ（zip 压缩包）请先解压出 .kml 再导入。
class KmlImporter {
  static final _placemarkRe = RegExp(r'<Placemark[\s>][\s\S]*?</Placemark>');
  static final _nameRe = RegExp(r'<name[^>]*>([\s\S]*?)</name>');
  static final _coordRe = RegExp(r'<coordinates[^>]*>([\s\S]*?)</coordinates>');
  static final _pointRe = RegExp(r'<Point[\s>]');
  static final _lineRe = RegExp(r'<LineString[\s>]|<LinearRing[\s>]');
  static final _cdataRe = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>');

  /// 解析失败 / 无有效要素返回 null。
  static KmlParseResult? parse(String xml) {
    final out = <MapLabel>[];
    var ptCount = 0, lnCount = 0;
    final placemarks = _placemarkRe.allMatches(xml);
    for (final pm in placemarks) {
      final body = pm.group(0)!;
      final nameMatch = _nameRe.firstMatch(body);
      var name = nameMatch == null ? '' : nameMatch.group(1)!.trim();
      if (name.contains('<')) {
        final cd = _cdataRe.firstMatch(name);
        name = cd != null ? cd.group(1)!.trim() : '';
      }
      // 取所有 coordinates 块（MultiGeometry 会有多个）
      final coordBlocks = _coordRe.allMatches(body).toList();
      if (coordBlocks.isEmpty) continue;
      final isPoint = _pointRe.hasMatch(body) && !_lineRe.hasMatch(body);

      if (isPoint) {
        final c = _parseCoords(coordBlocks.first.group(1)!);
        if (c.isEmpty) continue;
        out.add(MapLabel(
          typeId: 'pipe',
          seq: out.length + 1,
          lat: c[0][0],
          lon: c[0][1],
          name: name,
        ));
        ptCount++;
        continue;
      }

      // 线要素：把每块 coordinates 串成一条链（多块按顺序拼接）
      var added = 0;
      String? gid;
      for (final cb in coordBlocks) {
        final c = _parseCoords(cb.group(1)!);
        if (c.length < 2) continue;
        gid ??= MapLabel().id;
        for (var i = 0; i < c.length; i++) {
          out.add(MapLabel(
            typeId: 'pipe',
            seq: out.length + 1,
            lat: c[i][0],
            lon: c[i][1],
            lineGroupId: gid,
            name: added == 0 ? name : '',
          ));
          added++;
        }
      }
      if (added > 0) lnCount++;
    }
    if (out.isEmpty) return null;
    return KmlParseResult(out, ptCount, lnCount);
  }

  /// "lon,lat[,alt]" 序列（空格/换行分隔）→ [lat, lon] 列表，过滤非法与重复。
  static List<List<double>> _parseCoords(String raw) {
    final out = <List<double>>[];
    final seen = <String>{};
    for (final tok in raw.split(RegExp(r'\s+'))) {
      final t = tok.trim();
      if (t.isEmpty) continue;
      final parts = t.split(',');
      if (parts.length < 2) continue;
      final lon = double.tryParse(parts[0].trim());
      final lat = double.tryParse(parts[1].trim());
      if (lon == null || lat == null) continue;
      if (lat < -90 || lat > 90 || lon < -180 || lon > 180) continue;
      final key =
          '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
      if (!seen.add(key)) continue;
      out.add([lat, lon]);
    }
    return out;
  }
}
