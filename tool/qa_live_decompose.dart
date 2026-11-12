// QA 实测 2：分解两段式请求 + 对拍 convertGcj 开关的真实偏移。
import 'dart:convert';

import 'package:ovimap/services/tianditu.dart';

Future<void> main(List<String> args) async {
  final key = args.isNotEmpty ? args[0] : kBuiltinTiandituKey;

  // 1) 显式本地范围（±0.3°）查一次：预期为空（证明全国兜底确实发生）
  final local = await TiandituClient.search('丰乐园', key,
      mapBound: TiandituClient.localBound(32.1, 114.08));
  print('LOCAL resultCount=${local.length}');

  // 2) 同一关键词：convertGcj on/off 对拍真实偏移量级
  final on = await TiandituClient.search('丰乐园酒家', key,
      mapBound: TiandituClient.localBound(31.8, 115.4)); // 商城县附近本地框
  final off = await TiandituClient.search('丰乐园酒家', key,
      mapBound: TiandituClient.localBound(31.8, 115.4), convertGcj: false);
  print('onCount=${on.length} offCount=${off.length}');
  for (var i = 0; i < on.length && i < 3; i++) {
    final a = on[i], b = off[i];
    final dLat = (a.lat - b.lat).abs(), dLon = (a.lon - b.lon).abs();
    // 米近似
    final mLat = dLat * 111320, mLon = dLon * 111320 * 0.85;
    print('${a.name}: on=(${a.lat.toStringAsFixed(6)},${a.lon.toStringAsFixed(6)}) '
        'off=(${b.lat.toStringAsFixed(6)},${b.lon.toStringAsFixed(6)}) '
        'offset≈${(mLat * mLat + mLon * mLon).toStringAsFixed(0)}m');
  }
  print(jsonEncode(on.map((r) => r.displayName).toList()));
}
