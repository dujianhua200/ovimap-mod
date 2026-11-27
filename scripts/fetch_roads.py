#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
路网矢量抓取器 —— 输出 ovimap 可直接「导入 GeoJSON 底图」的路网数据。

背景（为什么这样做）
--------------------
高德官方 Web 服务 **没有** 路网矢量下载接口：能用的只有
  · 路径规划 v3/direction/walking、v3/direction/driving
  · POI 搜索 v5/place/text、v5/place/polygon
想要「小路也出来」，可行且稳定的做法是：
  1. amap 源：把目标区域切成网格，对相邻网格点批量请求 walking 路线，
     把所有返回折线合并成路网。walking 模式会走村道/小巷/步道，
     正好覆盖被 Overpass 漏掉的国内小路。
  2. overpass 源（免 key 兜底）：way["highway"] 全量抓取，真实路网，
     含 service/track/path，直接用已验证可用的境外镜像。

坐标系
------
高德路径规划的输入/输出都是 GCJ-02（火星坐标）；项目内部统一 WGS-84。
脚本内移植了 lib/geo/gcj02.dart 的转换算法，输出前统一 GCJ-02 → WGS-84。
Overpass 返回本来就是 WGS-84，不转换。

输出格式（与 lib/export/local_basemap.dart::GeoJsonImporter 完全对齐）
--------------------------------------------------------------------
FeatureCollection，每个要素：
  geometry: LineString / MultiLineString，坐标 [lon, lat]（WGS-84）
  properties.highway: motorway/trunk/.../service/path —— 项目据此分级
  properties.name:    道路名（可能为空，导入器不强制要求）

用法
----
  # 高德源（key 自配， walking 优先抓小路）
  python3 scripts/fetch_roads.py --source amap --key YOUR_AMAP_KEY \
      --bbox 39.908,116.397,39.918,116.407 --mode both \
      -o data/amap_roads/my_village.geojson

  # Overpass 源（免 key；国内数据靠境外镜像，量大时限小 bbox）
  python3 scripts/fetch_roads.py --source overpass \
      --bbox 39.908,116.397,39.918,116.407 \
      -o data/amap_roads/my_village_osm.geojson

  # 两源合并去重（先 overpass 打底，再 amap 补小路）
  python3 scripts/fetch_roads.py --source both --key YOUR_AMAP_KEY \
      --bbox 39.908,116.397,39.918,116.407 \
      -o data/amap_roads/my_village_all.geojson

key 也可放环境变量 AMAP_KEY：不写入任何文件，不入库（公开仓库）。
"""

import argparse
import hashlib
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

# ---------------------------------------------------------------- GCJ-02 ----
A = 6378245.0
EE = 0.00669342162296594323
PI = math.pi


def out_of_china(lat, lon):
    return lon < 72.004 or lon > 137.8347 or lat < 0.8293 or lat > 55.8271


def _transform_lat(x, y):
    ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(abs(x))
    ret += (20.0 * math.sin(6.0 * x * PI) + 20.0 * math.sin(2.0 * x * PI)) * 2.0 / 3.0
    ret += (20.0 * math.sin(y * PI) + 40.0 * math.sin(y / 3.0 * PI)) * 2.0 / 3.0
    ret += (160.0 * math.sin(y / 12.0 * PI) + 320.0 * math.sin(y * PI / 30.0)) * 2.0 / 3.0
    return ret


def _transform_lon(x, y):
    ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(abs(x))
    ret += (20.0 * math.sin(6.0 * x * PI) + 20.0 * math.sin(2.0 * x * PI)) * 2.0 / 3.0
    ret += (20.0 * math.sin(x * PI) + 40.0 * math.sin(x / 3.0 * PI)) * 2.0 / 3.0
    ret += (150.0 * math.sin(x / 12.0 * PI) + 300.0 * math.sin(x / 30.0 * PI)) * 2.0 / 3.0
    return ret


def wgs84_to_gcj02(lat, lon):
    if out_of_china(lat, lon):
        return [lat, lon]
    d_lat = _transform_lat(lon - 105.0, lat - 35.0)
    d_lon = _transform_lon(lon - 105.0, lat - 35.0)
    rad_lat = lat / 180.0 * PI
    magic = math.sin(rad_lat)
    magic = 1 - EE * magic * magic
    sqrt_magic = math.sqrt(magic)
    d_lat = (d_lat * 180.0) / ((A * (1 - EE)) / (magic * sqrt_magic) * PI)
    d_lon = (d_lon * 180.0) / (A / sqrt_magic * math.cos(rad_lat) * PI)
    return [lat + d_lat, lon + d_lon]


def gcj02_to_wgs84(lat, lon):
    if out_of_china(lat, lon):
        return [lat, lon]
    w_lat, w_lon = lat, lon
    for _ in range(2):
        g = wgs84_to_gcj02(w_lat, w_lon)
        w_lat += lat - g[0]
        w_lon += lon - g[1]
    return [w_lat, w_lon]


# ------------------------------------------------------------------ HTTP ----
def http_json(url, timeout=45, retries=2, post_data=None):
    """GET/POST → JSON。失败重试，全部失败抛最后异常。"""
    last = None
    for attempt in range(retries + 1):
        try:
            headers = {
                "User-Agent": "ovimap-mod/3.34 (road data fetch)",
                "Accept": "application/json",
            }
            body = None
            if post_data is not None:
                body = urllib.parse.urlencode(post_data).encode("utf-8")
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            req = urllib.request.Request(url, data=body, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
            return json.loads(raw.decode("utf-8"))
        except Exception as e:  # noqa: BLE001 - 网络错误类型多，统一重试
            last = e
            if attempt < retries:
                time.sleep(1.5 + attempt * 2)
    raise last


# 保留旧名兼容（amap 分支调用）
def http_get_json(url, timeout=20, retries=2):
    return http_json(url, timeout=timeout, retries=retries)


# ------------------------------------------------------------- Overpass ----
# 已实测可用（2026-11）：返回国内 way["highway"] 真实数据。
# overpass-api.de / kumi 在本机网络下超时；这两个可用，留作主用+互为备份。
# 实测（2026-11）：maps.mail.ru 对国内 bbox 稳定返回真实 way 数据（含 service/path）；
# 其余镜像网络波动大，作为并发备份。取"首个成功且元素非空"的结果。
OVERPASS_MIRRORS = [
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    "https://overpass.osm.ch/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]


def _overpass_one(base, q, timeout):
    """单镜像 GET 查询，返回 elements 列表或抛异常。"""
    url = base + "?" + urllib.parse.urlencode({"data": q})
    data = http_json(url, timeout=timeout, retries=0)
    if not isinstance(data, dict) or "elements" not in data:
        raise RuntimeError("响应无 elements")
    return data["elements"]


def _overpass_query(bbox_part, timeout=45):
    """单次 Overpass 查询：并发打多镜像，取首个成功结果（含空结果也接受）。

    并发而非串行，避免某个慢镜像卡住整片（实测 private.coffee 常 26s+ 超时）。
    """
    min_lat, min_lon, max_lat, max_lon = bbox_part
    q = (
        '[out:json][timeout:35];'
        'way["highway"](%s,%s,%s,%s);out geom;' % (min_lat, min_lon, max_lat, max_lon)
    )
    empty_result = None
    with ThreadPoolExecutor(max_workers=len(OVERPASS_MIRRORS)) as ex:
        futs = {ex.submit(_overpass_one, base, q, timeout): base
                for base in OVERPASS_MIRRORS}
        for fut in as_completed(futs):
            base = futs[fut]
            try:
                elems = fut.result()
                if elems:  # 只接受非空结果，避免 osm.ch 的 0 元素抢答
                    print("  overpass 命中 %s（%d 元素）" % (base, len(elems)),
                          file=sys.stderr)
                    return elems
                empty_result = [] if empty_result is None else empty_result
            except Exception as e:  # noqa: BLE001
                print("  overpass %s 失败: %s" % (base, e), file=sys.stderr)
    # 所有镜像都成功但无数据（可能是真郊区），返回空集而非 None
    return empty_result


def _split_bbox(bbox, max_span_deg=0.006):
    """把 bbox 切成 ≤max_span_deg 的小片（约 600m），降低单请求超时概率。"""
    min_lat, min_lon, max_lat, max_lon = bbox
    ny = max(1, int(math.ceil((max_lat - min_lat) / max_span_deg)))
    nx = max(1, int(math.ceil((max_lon - min_lon) / max_span_deg)))
    parts = []
    for j in range(ny):
        la0 = min_lat + (max_lat - min_lat) * j / ny
        la1 = min_lat + (max_lat - min_lat) * (j + 1) / ny
        for i in range(nx):
            lo0 = min_lon + (max_lon - min_lon) * i / nx
            lo1 = min_lon + (max_lon - min_lon) * (i + 1) / nx
            parts.append((la0, lo0, la1, lo1))
    return parts


def fetch_overpass(bbox, timeout=45, max_span_deg=0.01):
    """返回 [(pts_wgs_latlon, highway, name), ...]；自动分片 + 镜像容错。"""
    parts = _split_bbox(bbox, max_span_deg)
    print("  Overpass 分片 %d 块（每块 ≤%.4f°）" % (len(parts), max_span_deg),
          file=sys.stderr)
    lines = []
    seen_ids = set()
    for idx, part in enumerate(parts, 1):
        elements = _overpass_query(part, timeout=timeout)
        if elements is None:
            print("  片 %d/%d 失败（跳过）" % (idx, len(parts)), file=sys.stderr)
            continue
        for el in elements:
            eid = el.get("id")
            if eid is not None and eid in seen_ids:
                continue
            if eid is not None:
                seen_ids.add(eid)
            geom = el.get("geometry") or []
            pts = [[float(p["lat"]), float(p["lon"])] for p in geom
                   if "lat" in p and "lon" in p]
            if len(pts) < 2:
                continue
            tags = el.get("tags") or {}
            hw = tags.get("highway", "")
            name = tags.get("name", "") or tags.get("name:zh", "") or ""
            lines.append((pts, hw, name))
    if not lines:
        raise RuntimeError("所有 Overpass 分片均未取到数据")
    return lines


# ----------------------------------------------------------------- amap ----
def _deg_per_meter(lat):
    """返回 (每米对应纬度度, 每米对应经度度)。"""
    return 1.0 / 111320.0, 1.0 / (111320.0 * max(0.01, math.cos(math.radians(lat))))


def _grid_nodes(bbox_gcj, grid_m, max_nodes=400):
    """在 GCJ-02 bbox 内生成网格节点（lat,lon）。控制总量避免爆请求。"""
    min_lat, min_lon, max_lat, max_lon = bbox_gcj
    mid_lat = (min_lat + max_lat) / 2.0
    dlat, dlon = _deg_per_meter(mid_lat)
    ny = max(2, int(math.ceil((max_lat - min_lat) / (dlat * grid_m))) + 1)
    nx = max(2, int(math.ceil((max_lon - min_lon) / (dlon * grid_m))) + 1)
    while (nx + 1) * (ny + 1) > max_nodes and grid_m < 20000:
        grid_m = int(grid_m * 1.5)
        ny = max(2, int(math.ceil((max_lat - min_lat) / (dlat * grid_m))) + 1)
        nx = max(2, int(math.ceil((max_lon - min_lon) / (dlon * grid_m))) + 1)
    nodes = []
    for j in range(ny + 1):
        lat = min_lat + (max_lat - min_lat) * j / ny
        row = []
        for i in range(nx + 1):
            lon = min_lon + (max_lon - min_lon) * i / nx
            row.append((lat, lon))
        nodes.append(row)
    return nodes, grid_m


def _amap_path(key, mode, origin, dest, timeout=15):
    """请求一段路径规划，返回 GCJ-02 折线列表 [(lat,lon),...]（可能多方案取第一条）。"""
    o = "%s,%s" % (origin[1], origin[0])
    d = "%s,%s" % (dest[1], dest[0])
    endpoint = "walking" if mode == "walking" else "driving"
    url = "https://restapi.amap.com/v3/direction/%s?%s" % (
        endpoint,
        urllib.parse.urlencode({"origin": o, "destination": d, "key": key, "output": "json"}),
    )
    jo = http_get_json(url, timeout=timeout, retries=1)
    if str(jo.get("status")) != "1":
        raise RuntimeError("amap %s %s" % (jo.get("infocode"), jo.get("info")))
    route = jo.get("route") or {}
    paths = route.get("paths") or []
    if not paths:
        return []
    steps = paths[0].get("steps") or []
    pts = []
    for st in steps:
        poly = st.get("polyline") or ""
        for seg in poly.split(";"):
            seg = seg.strip()
            if not seg or "," not in seg:
                continue
            try:
                lon_g, lat_g = [float(x) for x in seg.split(",", 1)]
            except ValueError:
                continue
            # 高德 polyline 是 GCJ-02，出口转 WGS-84
            wlat, wlon = gcj02_to_wgs84(lat_g, lon_g)
            pts.append((wlat, wlon))
    # 去重相邻点（GCJ→WGS 反解可能有微小抖动）
    dedup = []
    for p in pts:
        if not dedup or abs(p[0] - dedup[-1][0]) > 1e-7 or abs(p[1] - dedup[-1][1]) > 1e-7:
            dedup.append(p)
    return dedup


def fetch_amap(bbox, key, mode, grid_m, max_requests, delay, timeout=15):
    """网格化采样路径规划 → 路网折线。返回 [(pts_wgs_latlon, highway, name), ...]。"""
    if not key:
        raise RuntimeError("amap 源需要 key：--key 或环境变量 AMAP_KEY（不入库）")
    min_lat, min_lon, max_lat, max_lon = bbox
    # 输入 bbox 是 WGS，先转 GCJ（高德按 GCJ 解读坐标）。
    corners = [
        wgs84_to_gcj02(min_lat, min_lon), wgs84_to_gcj02(min_lat, max_lon),
        wgs84_to_gcj02(max_lat, min_lon), wgs84_to_gcj02(max_lat, max_lon),
    ]
    g = (
        min(c[0] for c in corners), min(c[1] for c in corners),
        max(c[0] for c in corners), max(c[1] for c in corners),
    )
    nodes, grid_m = _grid_nodes(g, grid_m)
    edges = []
    for j in range(len(nodes)):
        for i in range(len(nodes[j])):
            if i + 1 < len(nodes[j]):
                edges.append((nodes[j][i], nodes[j][i + 1]))
            if j + 1 < len(nodes):
                edges.append((nodes[j][i], nodes[j + 1][i]))
    edges = edges[:max_requests]
    print("  网格间距 ~%dm，节点 %d，请求 %d 段（mode=%s）" % (
        grid_m, sum(len(r) for r in nodes), len(edges), mode), file=sys.stderr)

    modes = ["walking", "driving"] if mode == "both" else [mode]
    lines = []
    for k, (a, b) in enumerate(edges):
        for m in modes:
            try:
                pts = _amap_path(key, m, a, b, timeout=timeout)
                if len(pts) >= 2:
                    # walking → 小路/步道；driving → 一般道路
                    hw = "path" if m == "walking" else "residential"
                    lines.append((pts, hw, ""))
            except Exception as e:  # noqa: BLE001 - 单段失败不中断整体
                print("  段 %d/%d %s 失败: %s" % (k + 1, len(edges), m, e), file=sys.stderr)
        if delay > 0:
            time.sleep(delay)
    return lines


# ---------------------------------------------------------------- output ----
def dedup_lines(lines):
    """按折线几何指纹去重（不同来源/请求可能拿到同一段路）。"""
    seen = set()
    out = []
    for pts, hw, name in lines:
        coords = [(round(p[0], 6), round(p[1], 6)) for p in pts]
        fp = hashlib.md5(
            repr((coords[0], coords[-1], len(coords))).encode("utf-8")
        ).hexdigest()
        if fp in seen:
            continue
        seen.add(fp)
        out.append((pts, hw, name))
    return out


def to_geojson(lines):
    features = []
    for pts, hw, name in lines:
        coords = [[round(p[1], 7), round(p[0], 7)] for p in pts]  # [lon, lat]
        features.append({
            "type": "Feature",
            "properties": {"highway": hw or "other", "name": name},
            "geometry": {"type": "LineString", "coordinates": coords},
        })
    return {
        "type": "FeatureCollection",
        "name": "ovimap-roads",
        "features": features,
    }


def parse_bbox(s):
    parts = [float(x) for x in s.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("bbox 格式：minLat,minLon,maxLat,maxLon")
    min_lat, min_lon, max_lat, max_lon = parts
    if min_lat >= max_lat or min_lon >= max_lon:
        raise argparse.ArgumentTypeError("bbox 必须 min < max")
    return [min_lat, min_lon, max_lat, max_lon]


def main():
    ap = argparse.ArgumentParser(description="抓取路网矢量 → ovimap GeoJSON（WGS-84）")
    ap.add_argument("--source", choices=["overpass", "amap", "both"], default="overpass",
                    help="overpass=免key真实路网；amap=路径规划网格采样(需key)；both=两者合并")
    ap.add_argument("--bbox", type=parse_bbox, required=True,
                    help="区域 [minLat,minLon,maxLat,maxLon]，WGS-84")
    ap.add_argument("--key", default=os.environ.get("AMAP_KEY", ""),
                    help="高德 Web 服务 key（也可设 AMAP_KEY 环境变量；不写入文件）")
    ap.add_argument("--mode", choices=["walking", "driving", "both"], default="walking",
                    help="amap 采样模式；walking 更能抓到小路（默认）")
    ap.add_argument("--grid-m", type=int, default=900, help="amap 网格间距（米），默认 900")
    ap.add_argument("--max-requests", type=int, default=160, help="amap 最大请求数，默认 160")
    ap.add_argument("--delay", type=float, default=0.05, help="amap 每次请求后延时（秒）")
    ap.add_argument("--span", type=float, default=0.01,
                    help="Overpass 分片边长（度），0.01≈1km，默认 0.01；大值更快但可能 504")
    ap.add_argument("-o", "--output", required=True, help="输出 GeoJSON 路径")
    args = ap.parse_args()

    all_lines = []
    if args.source in ("overpass", "both"):
        print("[1/%d] Overpass 抓取真实路网…" % (2 if args.source == "both" else 1),
              file=sys.stderr)
        try:
            got = fetch_overpass(args.bbox, max_span_deg=args.span)
            print("  Overpass: %d 条道路" % len(got), file=sys.stderr)
            all_lines.extend(got)
        except Exception as e:  # noqa: BLE001
            print("  Overpass 失败: %s" % e, file=sys.stderr)

    if args.source in ("amap", "both"):
        print("[%d/%d] 高德网格采样（%s）…" % (
            2 if args.source == "both" else 1, 2 if args.source == "both" else 1, args.mode),
            file=sys.stderr)
        try:
            got = fetch_amap(args.bbox, args.key, args.mode,
                             args.grid_m, args.max_requests, args.delay)
            print("  高德: %d 条折线" % len(got), file=sys.stderr)
            all_lines.extend(got)
        except Exception as e:  # noqa: BLE001
            print("  高德失败: %s" % e, file=sys.stderr)

    if not all_lines:
        print("错误：未抓到任何道路，请检查 bbox / key / 网络。", file=sys.stderr)
        return 2

    all_lines = dedup_lines(all_lines)
    out_dir = os.path.dirname(os.path.abspath(args.output))
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir, exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(to_geojson(all_lines), f, ensure_ascii=False, separators=(",", ":"))

    hw_count = {}
    for _, hw, _ in all_lines:
        hw_count[hw or "other"] = hw_count.get(hw or "other", 0) + 1
    print("完成：%d 条道路 → %s" % (len(all_lines), args.output), file=sys.stderr)
    print("  等级分布：%s" % ", ".join("%s=%d" % kv for kv in sorted(hw_count.items())),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
