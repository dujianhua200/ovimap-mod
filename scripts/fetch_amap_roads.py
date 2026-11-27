#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
高德路网网格采样器（信阳地区）。

高德没有公开的整片路网矢量下载接口，但网页版本身通过自有域名反向代理
调用路径规划 API：
    https://www.amap.com/_AMapService/v3/direction/driving
配合网页 key 和 Referer 可正常返回 status=1，paths[].steps[].polyline
即真实道路折线（GCJ-02 坐标），instruction 里带道路名。

本脚本把目标区域划成网格，对每条网格边请求 driving 路径，把返回的折线
转成 WGS84，提取路名，去重后输出标准 GeoJSON（与 GeoJsonImporter 对齐）。

用法：
  # 小范围测试（中心城区）
  python3 scripts/fetch_amap_roads.py --bbox 32.12,114.05,32.18,114.15 \\
      --grid-m 800 --max-requests 40 -o data/amap_roads/amap_test.geojson
  # 全市
  python3 scripts/fetch_amap_roads.py --grid-m 2000 --workers 5 \\
      -o data/amap_roads/xinyang_amap.geojson

坐标：网格在 WGS84 空间里生成，请求前 WGS84→GCJ02，返回折线 GCJ02→WGS84。
依赖：仅标准库。坐标转换函数复用 scripts/fetch_roads.py。
"""
import argparse
import hashlib
import json
import math
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fetch_roads import wgs84_to_gcj02, gcj02_to_wgs84

# 高德网页 key（从 www.amap.com 首页提取，Web 端，配合自有域名代理使用）
AMAP_WEB_KEY = "2f282f369e388ef01bae260cbc35edce"
SERVICE = "https://www.amap.com/_AMapService/v3/direction/driving"
REFERER = "https://www.amap.com/"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36")

# 信阳全市 WGS84 bbox
XINYANG_BBOX = (31.20, 113.80, 32.58, 115.60)

CACHE_DIR = "data/amap_roads/.amap_cache"


# --------------------------------------------------------------- HTTP ----
def http_get_json(url, timeout=25, retries=2):
    last = None
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers={
                "Referer": REFERER, "User-Agent": UA, "Accept": "*/*",
            })
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8", "replace"))
        except Exception as ex:
            last = ex
            if attempt < retries:
                time.sleep(1.5 * (attempt + 1))
    raise last


def amap_driving(origin_gcj, dest_gcj, timeout=25, retries=2):
    """origin/dest 都是 [lat,lon] GCJ-02。返回 route.paths 或 None。"""
    params = {
        "key": AMAP_WEB_KEY,
        "platform": "JS",
        "s": "rsv3",
        "logversion": "2.0",
        "sdkversion": "2.3.5.15",
        "origin": "%.6f,%.6f" % (origin_gcj[1], origin_gcj[0]),
        "destination": "%.6f,%.6f" % (dest_gcj[1], dest_gcj[0]),
        "csid": str(uuid.uuid4()).upper(),
        "extensions": "",
        "strategy": "0",
        "ferry": "0",
    }
    url = SERVICE + "?" + urllib.parse.urlencode(params)
    d = http_get_json(url, timeout=timeout, retries=retries)
    if str(d.get("status")) != "1":
        return None
    return d.get("route", {}).get("paths", []) or None


# ----------------------------------------------------------- 路名/等级 ----
_NAME_RE = re.compile(r"沿(.+?)(?:向[东西南北中]|行驶|向前|直行|右转|左转|掉头|进入)")


def extract_name(instruction):
    if not instruction:
        return ""
    m = _NAME_RE.search(instruction)
    if m:
        return m.group(1).strip()
    for kw in ("进入", "转入"):
        idx = instruction.find(kw)
        if idx >= 0:
            tail = instruction[idx + len(kw):]
            m2 = re.search(r"^(.+?)(?:向[东西南北中]|行驶|\d+米|路口|$)", tail)
            if m2:
                return m2.group(1).strip()
    return ""


def infer_highway(name, instruction):
    text = (name or "") + (instruction or "")
    if "高速" in text or re.match(r"^[GHS]\d", name or ""):
        return "motorway"
    if re.match(r"^[XS]\d", name or ""):
        return "secondary"
    if any(k in text for k in ("大道", "快速", "环路")):
        return "tertiary"
    if any(k in text for k in ("大街", "大街", "路", "街", "巷")):
        return "residential"
    return "residential"


def parse_polyline(text):
    """'lon,lat;lon,lat' (GCJ-02) -> WGS84 [[lat,lon],...]"""
    pts = []
    for seg in (text or "").split(";"):
        seg = seg.strip()
        if not seg or "," not in seg:
            continue
        lon_s, lat_s = seg.split(",", 1)
        try:
            glon, glat = float(lon_s), float(lat_s)
        except ValueError:
            continue
        wlat, wlon = gcj02_to_wgs84(glat, glon)
        pts.append([round(wlat, 7), round(wlon, 7)])
    return pts


def paths_to_features(paths):
    """把 paths[].steps[].polyline 转为 feature 列表。"""
    out = []
    for path in paths:
        for step in path.get("steps", []):
            poly = step.get("polyline") or ""
            pts = parse_polyline(poly)
            if len(pts) < 2:
                continue
            inst = step.get("instruction") or ""
            name = extract_name(inst)
            out.append({
                "type": "Feature",
                "properties": {
                    "highway": infer_highway(name, inst),
                    "name": name,
                },
                "geometry": {
                    "type": "LineString",
                    "coordinates": [[p[1], p[0]] for p in pts],  # GeoJSON [lon,lat]
                },
            })
    return out


# --------------------------------------------------------------- 网格 ----
def build_grid(bbox, grid_m):
    """返回 WGS84 网格节点 {(i,j): (lat,lon)}。"""
    lat0, lon0, lat1, lon1 = bbox
    center_lat = (lat0 + lat1) / 2.0
    d_lat = grid_m / 110540.0
    d_lon = grid_m / (111320.0 * math.cos(math.radians(center_lat)))
    ni = max(1, int(math.ceil((lat1 - lat0) / d_lat)))
    nj = max(1, int(math.ceil((lon1 - lon0) / d_lon)))
    nodes = {}
    for i in range(ni + 1):
        la = min(lat1, lat0 + i * d_lat)
        for j in range(nj + 1):
            lo = min(lon1, lon0 + j * d_lon)
            nodes[(i, j)] = (la, lo)
    return nodes, ni, nj


def edges(ni, nj):
    """每条网格边只由左上端点请求一次：右(i,j)->(i,j+1)、下(i,j)->(i+1,j)。"""
    out = []
    for i in range(ni + 1):
        for j in range(nj + 1):
            if j + 1 <= nj:
                out.append(((i, j), (i, j + 1)))
            if i + 1 <= ni:
                out.append(((i, j), (i + 1, j)))
    return out


def cache_path(a, b):
    return os.path.join(CACHE_DIR, "e_%04d_%04d_%04d_%04d.json" % (a[0], a[1], b[0], b[1]))


def sample_edge(a, b, nodes, timeout=25):
    cp = cache_path(a, b)
    if os.path.exists(cp):
        try:
            with open(cp, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    la, lo = nodes[a]
    lb, lb_on = nodes[b]
    o = wgs84_to_gcj02(la, lo)
    d = wgs84_to_gcj02(lb, lb_on)
    paths = amap_driving(o, d, timeout=timeout)
    feats = paths_to_features(paths) if paths else []
    tmp = cp + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(feats, f, ensure_ascii=False)
    os.replace(tmp, cp)
    return feats


# --------------------------------------------------------------- 合并 ----
def dedup_features(features):
    """按路名+中点 50m 网格去重，避免相邻网格重复路段。"""
    buckets = {}
    out = []
    for feat in features:
        coords = feat["geometry"]["coordinates"]
        if len(coords) < 2:
            continue
        mid_lon = (coords[0][0] + coords[-1][0]) / 2.0
        mid_lat = (coords[0][1] + coords[-1][1]) / 2.0
        name = feat["properties"].get("name", "")
        key = (name, round(mid_lat * 1000 / 50), round(mid_lon * 1000 / 50))
        if key in buckets:
            continue
        buckets[key] = 1
        out.append(feat)
    return out


def merge_cache(out_path):
    feats = []
    files = [f for f in os.listdir(CACHE_DIR) if f.startswith("e_") and f.endswith(".json")]
    for fn in files:
        try:
            with open(os.path.join(CACHE_DIR, fn), "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, list):
                feats.extend(data)
        except Exception:
            continue
    feats = dedup_features(feats)
    fc = {"type": "FeatureCollection", "features": feats}
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(fc, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, out_path)
    return len(feats)


# --------------------------------------------------------------- main ----
def main():
    global CACHE_DIR
    ap = argparse.ArgumentParser(description="高德路网网格采样（信阳）")
    ap.add_argument("--bbox", default="%s,%s,%s,%s" % XINYANG_BBOX,
                    help="WGS84 minLat,minLon,maxLat,maxLon")
    ap.add_argument("--grid-m", type=float, default=2000, help="网格边长（米）")
    ap.add_argument("--workers", type=int, default=5)
    ap.add_argument("--timeout", type=int, default=25)
    ap.add_argument("--delay", type=float, default=0.1, help="每次请求后延时（秒）")
    ap.add_argument("--max-requests", type=int, default=0, help="0=不限（测试用小值）")
    ap.add_argument("--cache-dir", default=CACHE_DIR)
    ap.add_argument("-o", "--out", default="data/amap_roads/xinyang_amap.geojson")
    ap.add_argument("--finalize", action="store_true", help="只合并缓存输出，不抓取")
    args = ap.parse_args()

    CACHE_DIR = args.cache_dir
    os.makedirs(CACHE_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)

    if args.finalize:
        n = merge_cache(args.out)
        print("合并完成：%d 条路 -> %s" % (n, args.out))
        return

    lat0, lon0, lat1, lon1 = [float(x) for x in args.bbox.split(",")]
    nodes, ni, nj = build_grid((lat0, lon0, lat1, lon1), args.grid_m)
    edges_list = edges(ni, nj)
    if args.max_requests > 0:
        edges_list = edges_list[:args.max_requests]
    total = len(edges_list)
    print("高德路网采样：网格 %.0fm  节点=(%d,%d)  边=%d  并发=%d"
          % (args.grid_m, ni, nj, total, args.workers))

    done = fail = 0
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {}
        for a, b in edges_list:
            f = ex.submit(sample_edge, a, b, nodes, args.timeout)
            futs[f] = (a, b)
            if args.delay:
                time.sleep(args.delay)
        for fut in as_completed(futs):
            a, b = futs[fut]
            try:
                fut.result()
                done += 1
            except Exception:
                fail += 1
            n = done + fail
            if n % 100 == 0 or n == total:
                print("  进度 %d/%d  失败%d" % (n, total, fail), flush=True)

    print("抓取结束：成功 %d，失败 %d；开始合并..." % (done, fail))
    cnt = merge_cache(args.out)
    print("合并完成：%d 条路 -> %s" % (cnt, args.out))


if __name__ == "__main__":
    main()
