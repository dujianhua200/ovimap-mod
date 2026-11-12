// QA 实测脚本（允许联网，仅 QA 验证用，不进 CI）：
// 用内置 key 搜"丰乐园"，基准点信阳 32.1,114.08，验证两段式 mapBound 本地命中。
import 'dart:convert';

import 'package:ovimap/services/tianditu.dart';

Future<void> main(List<String> args) async {
  final key = args.isNotEmpty ? args[0] : kBuiltinTiandituKey;
  final res = await TiandituClient.search('丰乐园', key,
      nearLat: 32.1, nearLon: 114.08);
  print('resultCount=${res.length}');
  for (final r in res) {
    print('${r.displayName} lat=${r.lat.toStringAsFixed(6)} '
        'lon=${r.lon.toStringAsFixed(6)}');
  }
  // 与主理人实测对照：GCJ(32.1,114.08)→WGS≈(32.101947,114.074118)，偏移≈594m
  if (res.isNotEmpty) {
    final first = res.first;
    final dLat = (first.lat - 32.1).abs();
    final dLon = (first.lon - 114.08).abs();
    print('firstOffsetDeg: dLat=$dLat dLon=$dLon');
    print(jsonEncode(res
        .map((r) => {'name': r.name, 'addr': r.address, 'lat': r.lat, 'lon': r.lon})
        .toList()));
  }
}
