import 'dart:io';
import 'dart:math' as math;

import '../models/map_label.dart';
import '../services/store.dart';
/// 谷歌地球 KML 导出：折线 + 标签点 + 每段距离。
class KmlExporter {
  KmlExporter._();

  static const int all = 0;
  static const int labelsOnly = 1;
  static const int tracksOnly = 2;

  static Future<File> export(String name, List<MapLabel> labels,
      [int filter = all]) async {
    final sb = StringBuffer();
    sb.write('<?xml version="1.0" encoding="UTF-8"?>\n');
    sb.write('<kml xmlns="http://www.opengis.net/kml/2.2">\n');
    sb.write('<Document>\n');
    sb.write('  <name>${_xmlEscape(name)}</name>\n');
    sb.write('  <Style id="line">\n'
        '    <LineStyle><color>ff00ffff</color><width>4</width></LineStyle>\n'
        '  </Style>\n');
    sb.write('  <Style id="point">\n'
        '    <IconStyle><scale>0.8</scale></IconStyle>\n'
        '  </Style>\n');
    sb.write('  <Style id="label">\n'
        '    <LabelStyle><scale>1.2</scale></LabelStyle>\n'
        '  </Style>\n');

    // 按统一链口径输出分组折线（与地图/其它导出一致，箱体不打断杆路）。
    if (filter != labelsOnly) {
      for (final chain in buildLabelChains(labels)) {
        final isTrackChain = chain.every(_isTrackPoint);
        if (filter == tracksOnly && !isTrackChain) continue;
        _appendKmlLine(sb, name, chain);
      }
    }

    // 全部导出时保留杆路线的分段距离；轨迹纯线和仅轨迹模式不输出距离节点。
    if (filter == all) {
      for (final chain in buildLabelChains(labels)) {
        if (chain.every(_isTrackPoint)) continue;
        for (var k = 1; k < chain.length; k++) {
          final a = chain[k - 1];
          final b = chain[k];
          final d = b.distanceM ?? _haversine(a.lat, a.lon, b.lat, b.lon);
          final mLat = (a.lat + b.lat) / 2;
          final mLon = (a.lon + b.lon) / 2;
          sb.write('  <Placemark>\n');
          sb.write('    <name>${_formatDist(d)}</name>\n');
          sb.write('    <styleUrl>#label</styleUrl>\n');
          sb.write('    <Point>\n');
          sb.write('      <coordinates>'
              '${mLon.toStringAsFixed(7)},${mLat.toStringAsFixed(7)},0'
              '</coordinates>\n');
          sb.write('    </Point>\n');
          sb.write('  </Placemark>\n');
        }
      }
    }

    // 标签点（name = 标签符号，与地图一致）；仅轨迹模式不输出点。
    if (filter != tracksOnly) {
      for (final l in labels) {
        if (_isTrackPoint(l)) continue;
        final sym =
            l.name.trim().isNotEmpty ? l.name.trim() : l.type.symbol;
        if (sym.isEmpty) continue;
        sb.write('  <Placemark>\n');
        sb.write('    <name>${_xmlEscape(sym)}</name>\n');
        sb.write('    <styleUrl>#point</styleUrl>\n');
        sb.write('    <Point>\n');
        sb.write('      <coordinates>'
            '${l.lon.toStringAsFixed(7)},${l.lat.toStringAsFixed(7)},0'
            '</coordinates>\n');
        sb.write('    </Point>\n');
        sb.write('  </Placemark>\n');
      }
    }

    sb.write('</Document>\n');
    sb.write('</kml>\n');

    final dir = await LabelStore.instance.exportDir();
    final f = File('${dir.path}/${sanitizeName(name)}.kml');
    await robustWriteAsString(f, sb.toString());
    return f;
  }

  static bool _isTrackPoint(MapLabel label) =>
      label.typeId == 'track' || label.typeId == 'none';

  static void _appendKmlLine(StringBuffer sb, String name, List<MapLabel> group) {
    if (group.length < 2) return;
    sb.write('  <Placemark>\n');
    sb.write('    <name>${_xmlEscape(name)}</name>\n');
    sb.write('    <styleUrl>#line</styleUrl>\n');
    sb.write('    <LineString>\n');
    sb.write('      <tessellate>1</tessellate>\n');
    sb.write('      <coordinates>\n');
    for (final label in group) {
      sb.write('        ${label.lon.toStringAsFixed(7)},'
          '${label.lat.toStringAsFixed(7)},0\n');
    }
    sb.write('      </coordinates>\n');
    sb.write('    </LineString>\n');
    sb.write('  </Placemark>\n');
  }

  static double _haversine(double la1, double lo1, double la2, double lo2) {
    const r = 6371000.0;
    final dLat = math.pi * (la2 - la1) / 180;
    final dLon = math.pi * (lo2 - lo1) / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(math.pi * la1 / 180) * math.cos(math.pi * la2 / 180) *
            math.sin(dLon / 2) * math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static String _formatDist(double m) {
    if (m < 1000) return m.toStringAsFixed(1);
    return m.toStringAsFixed(0);
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
