// QA 实测 3：mapBound 生效性对照——同一关键词，本地框 vs 全国框，结果是否不同。
import 'package:ovimap/services/tianditu.dart';

Future<void> main(List<String> args) async {
  final key = args.isNotEmpty ? args[0] : kBuiltinTiandituKey;
  final local = await TiandituClient.search('丰乐园', key,
      mapBound: TiandituClient.localBound(32.1, 114.08));
  final national = await TiandituClient.search('丰乐园', key,
      mapBound: TiandituClient.nationalBound);
  String fmt(List<SearchResult> r) => r
      .map((e) => '${e.name}@${e.lat.toStringAsFixed(3)},${e.lon.toStringAsFixed(3)}')
      .join(' | ');
  print('LOCAL(${local.length}): ${fmt(local)}');
  print('NATIONAL(${national.length}): ${fmt(national)}');
}
