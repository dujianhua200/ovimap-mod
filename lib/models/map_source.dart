/// 地图源。每个图源含唯一 id（决定磁盘缓存目录）、显示名、URL 模板、
/// 坐标基准（0=无转换 WGS84，1=GCJ-02，2=BD-09）、最大级别、是否注记叠加层。
class MapSourceEntry {
  final String id;
  final String name;
  final String url;

  /// 0 WGS84 / 1 GCJ02 / 2 BD09
  final int datum;
  final int maxZoom;

  /// true=透明注记叠加层
  final bool overlay;
  final bool custom;

  const MapSourceEntry({
    required this.id,
    required this.name,
    required this.url,
    required this.datum,
    required this.maxZoom,
    this.overlay = false,
    this.custom = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'datum': datum,
        'maxZoom': maxZoom,
        'overlay': overlay,
        'custom': custom,
      };

  factory MapSourceEntry.fromJson(Map<String, dynamic> j) => MapSourceEntry(
        id: (j['id'] as String?) ?? 'custom',
        name: (j['name'] as String?) ?? '自定义源',
        url: (j['url'] as String?) ?? '',
        datum: (j['datum'] as num?)?.toInt() ?? 0,
        maxZoom: (j['maxZoom'] as num?)?.toInt() ?? 19,
        overlay: (j['overlay'] as bool?) ?? false,
        custom: (j['custom'] as bool?) ?? true,
      );

  /// 把旧版 {$x}/{$y}/{$z}/{$Galileo} 占位符规范化为 {x}/{y}/{z}。
  String get normalizedUrl {
    var u = url
        .replaceAll('{\$x}', '{x}')
        .replaceAll('{\$y}', '{y}')
        .replaceAll('{\$z}', '{z}')
        .replaceAll('s={\$Galileo}&', '')
        .replaceAll('&s={\$Galileo}', '')
        .replaceAll('s={\$Galileo}', '');
    // 谷歌/高德四叉树 TMS 的 {s} 子域：给个默认轮询
    u = u.replaceAll('{s}', '0');
    return u;
  }

  MapSourceEntry copyWith({String? name, String? url, int? datum, int? maxZoom}) =>
      MapSourceEntry(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        datum: datum ?? this.datum,
        maxZoom: maxZoom ?? this.maxZoom,
        overlay: overlay,
        custom: custom,
      );
}

class MapSources {
  MapSources._();

  static const String _sydtBase =
      'https://sydt.hainasi.eu.org/vt/lyrs=s,h&hl=zh-CN&gl=CN&src=app'
      '&x={x}&y={y}&z={z}&scale=1';

  static const MapSourceEntry sydtSatelliteAnn = MapSourceEntry(
      id: 'sydt', name: '联通卫星+注记', url: _sydtBase, datum: 1, maxZoom: 20);
  static const MapSourceEntry sydtSatellite = MapSourceEntry(
      id: 'sydt-s',
      name: '联通纯卫星',
      url: 'https://sydt.hainasi.eu.org/vt/lyrs=s&hl=zh-CN&gl=CN&src=app'
          '&x={x}&y={y}&z={z}&scale=1',
      datum: 1,
      maxZoom: 20);
  static const MapSourceEntry sydtRoad = MapSourceEntry(
      id: 'sydt-m',
      name: '联通街道图',
      url: 'https://sydt.hainasi.eu.org/vt/lyrs=m&hl=zh-CN&gl=CN&src=app'
          '&x={x}&y={y}&z={z}&scale=1',
      datum: 1,
      maxZoom: 20);
  static const MapSourceEntry sydtTerrain = MapSourceEntry(
      id: 'sydt-p',
      name: '联通地形图',
      url: 'https://sydt.hainasi.eu.org/vt/lyrs=p&hl=zh-CN&gl=CN&src=app'
          '&x={x}&y={y}&z={z}&scale=1',
      datum: 1,
      maxZoom: 20);

  static const MapSourceEntry amapSatellite = MapSourceEntry(
      id: 'amap-s',
      name: '高德卫星',
      url: 'https://webst02.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}',
      datum: 1,
      maxZoom: 18);
  static const MapSourceEntry amapAnn = MapSourceEntry(
      id: 'amap-ann',
      name: '高德注记',
      url: 'https://webst01.is.autonavi.com/appmaptile?style=8&x={x}&y={y}&z={z}',
      datum: 1,
      maxZoom: 18,
      overlay: true);
  static const MapSourceEntry amapRoad = MapSourceEntry(
      id: 'amap-road',
      name: '高德街道',
      url:
          'https://webrd02.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
      datum: 1,
      maxZoom: 18);

  static const MapSourceEntry osmStandard = MapSourceEntry(
      id: 'osm',
      name: 'OSM 街道(备援)',
      url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      datum: 0,
      maxZoom: 19);

  /// OSM 街道（自建 Cloudflare 反代加速）。
  ///
  /// 官方 `tile.openstreetmap.org` 在境外，国内加载慢；本条目走用户自建的
  /// 二合一反代（`/tile/{z}/{x}/{y}.png` 分支，边缘缓存 7 天），国内可达且明显更快。
  /// 与 [osmStandard] 并存：反代不可用时仍可切回官方源兜底。
  static const MapSourceEntry osmProxy = MapSourceEntry(
      id: 'osm-proxy',
      name: 'OSM 街道(反代加速)',
      url: 'https://hzyt.hainasi.eu.org/tile/{z}/{x}/{y}.png',
      datum: 0,
      maxZoom: 19);

  /// 星图地球影像（中科星图 GeoVis，公开免费，国内 0.5~0.8m 亚米级，WGS84 无偏移）。
  static const MapSourceEntry geovisSatellite = MapSourceEntry(
      id: 'geovis-img',
      name: '星图地球影像',
      url: 'https://tiles1.geovisearth.com/base/v1/img/{z}/{x}/{y}',
      datum: 0,
      maxZoom: 18);

  /// 预置可选主图源（不含叠加层）。
  static List<MapSourceEntry> presets() => const [
        sydtSatelliteAnn,
        sydtSatellite,
        sydtRoad,
        sydtTerrain,
        amapSatellite,
        amapRoad,
        geovisSatellite,
        osmProxy,
        osmStandard,
      ];

  /// 可勾选的透明注记叠加层。
  static List<MapSourceEntry> overlays() => const [amapAnn];

  static String _tdt(String layer) =>
      'http://t0.tianditu.gov.cn/${layer}_w/wmts?SERVICE=WMTS&REQUEST=GetTile'
      '&VERSION=1.0.0&LAYER=$layer&STYLE=default&TILEMATRIXSET=w&FORMAT=tiles'
      '&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&tk=';

  /// 按天地图 key 生成图源条目（key 为空返回空列表）。
  static List<MapSourceEntry> tianditu(String? key) {
    final k = (key ?? '').trim();
    if (k.isEmpty) return const [];
    return [
      MapSourceEntry(
          id: 'tdt-img', name: '天地图影像', url: '${_tdt('img')}$k', datum: 0, maxZoom: 18),
      MapSourceEntry(
          id: 'tdt-vec', name: '天地图矢量', url: '${_tdt('vec')}$k', datum: 0, maxZoom: 18),
      MapSourceEntry(
          id: 'tdt-cia',
          name: '天地图影像注记',
          url: '${_tdt('cia')}$k',
          datum: 0,
          maxZoom: 18,
          overlay: true),
      MapSourceEntry(
          id: 'tdt-cva',
          name: '天地图矢量注记',
          url: '${_tdt('cva')}$k',
          datum: 0,
          maxZoom: 18,
          overlay: true),
    ];
  }

  static MapSourceEntry byId(List<MapSourceEntry> all, String? id) {
    for (final e in all) {
      if (e.id == id) return e;
    }
    return sydtSatelliteAnn;
  }
}
