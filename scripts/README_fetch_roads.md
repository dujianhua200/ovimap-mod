# 路网抓取脚本 `fetch_roads.py`

把真实路网（**含小路**）抓成 ovimap 可直接导入的 GeoJSON，解决"道路太少、小路导不出"的问题。纯 Python 标准库，无需 pip 安装任何依赖（Python 3.7+）。

## 为什么小路会少

1. 在线底图默认只抓线路两侧 `rangeM`（默认 50m）缓冲内的道路，超出即裁掉。
2. 部分 Overpass 镜像对国内覆盖差，或大 bbox 直接 504。
3. 一些路名/小路类型（footway / path / steps / cycleway / service）虽会渲染几何，但默认不标名字。

本脚本一次性把"足够宽的一片区域"内**所有 highway 类型**抓全，输出 GeoJSON，用「导入 GeoJSON 底图…」导入即可；导出时把范围档位调大（≥ 抓取半径），小路就齐全了。

## 数据源

| 源 | 是否需 key | 覆盖 | 说明 |
| --- | --- | --- | --- |
| `overpass`（默认） | 否 | 国内真实 OSM 路网，含大量小路 | 并发多镜像取首个非空结果，自动分片，稳定 |
| `amap` | **需高德 Web 服务 key** | 路径规划网格化采样 | 高德官方**没有**"路网矢量下载"接口，只能用 walking/driving 路径规划折线还原；walking 更能抓到小路 |

> 高德 key 不入库：用 `--key YOUR_KEY` 或环境变量 `AMAP_KEY`，脚本不会把它写进任何文件。
> 坐标：Overpass 源原生 WGS-84；高德源是 GCJ-02，脚本内置 `gcj02 → wgs84` 迭代反解（往返误差 < 1e-7°），与项目 `lib/geo/gcj02.dart` 一致。

## 用法

```bash
# 1) 免 key：抓一片区域（bbox = minLat,minLon,maxLat,maxLon，WGS-84）
python3 scripts/fetch_roads.py \
  --source overpass \
  --bbox 39.904,116.397,39.914,116.409 \
  --span 0.01 \
  -o data/amap_roads/my_area.geojson

# 2) 需要高德数据时（先申请 key），walking 模式抓小路
AMAP_KEY=你的key python3 scripts/fetch_roads.py \
  --source amap --mode walking --grid-m 600 \
  --bbox 39.904,116.397,39.914,116.409 \
  -o data/amap_roads/my_area_amap.geojson

# 3) 两者合并（推荐：OSM 真实路网 + 高德小路补充）
AMAP_KEY=你的key python3 scripts/fetch_roads.py \
  --source both --mode both --grid-m 600 \
  --bbox 39.904,116.397,39.914,116.409 \
  -o data/amap_roads/my_area_all.geojson
```

参数：

- `--bbox`：`minLat,minLon,maxLat,maxLon`（WGS-84）。建议比你的杆路范围**各外扩 ≥100m**，保证 `rangeM` 裁剪后小路不丢。
- `--span`：Overpass 分片边长（度），`0.01≈1km`。默认 0.01；调到 0.02 更快但偶发 504。
- `--source`：`overpass` / `amap` / `both`。
- `--mode`：`walking`（抓小路）/ `driving` / `both`。
- `--grid-m`：高德采样网格间距（米），越小路越密但请求越多。
- `--max-requests`：高德最大请求数（默认 160），控制配额消耗。
- `--key` / `AMAP_KEY`：高德 key（不写文件）。

## 导入到 ovimap

1. 打开软件 →「导入 GeoJSON 底图…」→ 选生成的 `.geojson`。
2. 导出 DXF 时，把**范围档位**（沿线路缓冲米数）调到 ≥ 抓取时的外扩距离（例如抓时外扩 100m，就选 100m 档或更大），否则几何会被裁掉。
3. 若想让小路显示名字：在导出设置里打开「显示次要道路名称」（`showMinorRoadNames`），`service`/`path`/`footway` 等才会标字。

## 输出格式

`FeatureCollection`，每条路一个 `LineString`，`properties.highway` 为 OSM 标签值，`properties.name` 为路名（可能为空）。与 `lib/export/local_basemap.dart::GeoJsonImporter.parse` 完全对齐：

- `highway` 经 `OverpassClient.gradeOf` 映射为 `RoadGrade`（footway/steps/cycleway 归 `other`，path/service/track 归 `service`）。
- 所有等级的道路**几何**在 DXF 中一律保留；只有"标注"按等级过滤。

## 已验证

- 北京王府井片区 `39.904,116.397,39.914,116.409`：抓到 **274 条**道路，含 footway=96、service=65、steps=24、residential=27、tertiary=23、path=8、cycleway=8 等，示范文件见 `data/amap_roads/beijing_wangfujing.geojson`（64KB）。
- 坐标 GCJ-02 ↔ WGS-84 往返误差 < 1e-7°（北京/上海/深圳三点验证）。
- Overpass 并发镜像在 `maps.mail.ru` 命中，`overpass-api.de` 等失败时自动跳过，不阻塞。
