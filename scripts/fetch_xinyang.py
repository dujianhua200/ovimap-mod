#!/usr/bin/env python3
"""抓取信阳全市道路（OSM Overpass，含小路），分片缓存 + 断点续跑 + 低并发重试。

用法：
    python3 scripts/fetch_xinyang.py                       # 抓全市，输出到 data/amap_roads/xinyang_city.geojson
    python3 scripts/fetch_xinyang.py --workers 2 --span 0.10
    python3 scripts/fetch_xinyang.py --finalize            # 仅用已有缓存合并 GeoJSON，不再请求网络

分片缓存写在 data/amap_roads/.xinyang_cache/，每片一个 json；重跑时自动跳过已完成片。
坐标已是 WGS84（OSM 原生），与项目 GeoJsonImporter 直接对齐。
"""
import argparse
import json
import math
import os
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_DIR = os.path.join(ROOT, "data", "amap_roads")
CACHE_DIR = os.path.join(OUT_DIR, ".xinyang_cache")

# 信阳全市外扩一圈（保证沿线路 rangeM 裁剪后边缘小路不丢）
BBOX = (31.20, 113.80, 32.58, 115.60)  # minLat, minLon, maxLat, maxLon

MIRRORS = [
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]


def http_json(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": "ovimap-mod-xinyang/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def overpass_query(part, timeout=90):
    la0, lo0, la1, lo1 = part
    q = ('[out:json][timeout:60];'
         'way["highway"](%s,%s,%s,%s);out geom;' % (la0, lo0, la1, lo1))
    url = MIRRORS[0] + "?" + urllib.parse.urlencode({"data": q})
    data = http_json(url, timeout)
    if "elements" not in data:
        raise RuntimeError("无 elements")
    return data["elements"]


def fetch_part(args, idx, part):
    cache = os.path.join(CACHE_DIR, "part_%04d.json" % idx)
    if os.path.exists(cache):
        try:
            with open(cache, "r", encoding="utf-8") as f:
                return idx, len(json.load(f)), "cache"
        except Exception:
            pass
    last_err = ""
    for attempt in range(1, args.retries + 1):
        for mirror in MIRRORS:
            q = ('[out:json][timeout:60];way["highway"](%s,%s,%s,%s);out geom;'
                 % (part[0], part[1], part[2], part[3]))
            url = mirror + "?" + urllib.parse.urlencode({"data": q})
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "ovimap-mod-xinyang/1.0"})
                with urllib.request.urlopen(req, timeout=args.timeout) as r:
                    data = json.loads(r.read().decode("utf-8"))
                elems = data.get("elements", [])
                os.makedirs(CACHE_DIR, exist_ok=True)
                tmp = cache + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(elems, f, ensure_ascii=False)
                os.replace(tmp, cache)
                return idx, len(elems), mirror.split("/")[2]
            except Exception as e:  # noqa: BLE001
                last_err = "%s:%s" % (mirror.split("/")[2], type(e).__name__)
        time.sleep(min(30, 2 ** attempt))
    return idx, -1, "FAIL " + last_err


def split_bbox(bbox, span):
    la0, lo0, la1, lo1 = bbox
    ny = max(1, int(math.ceil((la1 - la0) / span)))
    nx = max(1, int(math.ceil((lo1 - lo0) / span)))
    parts = []
    for j in range(ny):
        a0 = la0 + (la1 - la0) * j / ny
        a1 = la0 + (la1 - la0) * (j + 1) / ny
        for i in range(nx):
            b0 = lo0 + (lo1 - lo0) * i / nx
            b1 = lo0 + (lo1 - lo0) * (i + 1) / nx
            parts.append((a0, b0, a1, b1))
    return parts


def finalize(out_path):
    parts = split_bbox(BBOX, FINAL_SPAN)
    feats = []
    seen = set()
    grades = {}
    loaded = 0
    for idx in range(len(parts)):
        cache = os.path.join(CACHE_DIR, "part_%04d.json" % idx)
        if not os.path.exists(cache):
            continue
        with open(cache, "r", encoding="utf-8") as f:
            elems = json.load(f)
        loaded += 1
        for el in elems:
            eid = el.get("id")
            key = ("w", eid) if eid is not None else None
            if key and key in seen:
                continue
            if key:
                seen.add(key)
            geom = el.get("geometry") or []
            pts = [[float(p["lon"]), float(p["lat"])] for p in geom
                   if "lon" in p and "lat" in p]
            if len(pts) < 2:
                continue
            tags = el.get("tags") or {}
            hw = tags.get("highway", "") or "unclassified"
            name = tags.get("name", "") or tags.get("name:zh", "") or ""
            grades[hw] = grades.get(hw, 0) + 1
            feats.append({
                "type": "Feature",
                "properties": {"highway": hw, "name": name},
                "geometry": {"type": "LineString", "coordinates": pts},
            })
    fc = {"type": "FeatureCollection", "features": feats}
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(fc, f, ensure_ascii=False)
    size_mb = os.path.getsize(out_path) / 1048576.0
    print("合并完成：%d/%d 片缓存，%d 条路，%.1fMB，输出 %s"
          % (loaded, len(parts), len(feats), size_mb, out_path))
    print("等级分布：" + ", ".join("%s=%d" % (k, grades[k])
                                for k in sorted(grades, key=lambda x: -grades[x])))
    return len(feats)


FINAL_SPAN = 0.10


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bbox", default=",".join(map(str, BBOX)))
    ap.add_argument("--span", type=float, default=0.10)
    ap.add_argument("--workers", type=int, default=2, help="并发片数（低位避免 504）")
    ap.add_argument("--timeout", type=int, default=90)
    ap.add_argument("--retries", type=int, default=4)
    ap.add_argument("--finalize", action="store_true", help="仅合并已有缓存")
    ap.add_argument("--cache-dir", default=None, help="自定义缓存目录（细分片重抓时避免污染旧缓存）")
    ap.add_argument("-o", "--out", default=os.path.join(OUT_DIR, "xinyang_city.geojson"))
    args = ap.parse_args()
    global FINAL_SPAN, CACHE_DIR
    FINAL_SPAN = args.span
    if args.cache_dir:
        CACHE_DIR = args.cache_dir
    bbox = tuple(float(x) for x in args.bbox.split(","))
    parts = split_bbox(bbox, args.span)
    print("信阳路网抓取：bbox=%s  span=%.3f°  分片=%d  并发=%d"
          % (bbox, args.span, len(parts), args.workers), flush=True)
    if args.finalize:
        finalize(args.out)
        return
    os.makedirs(CACHE_DIR, exist_ok=True)
    done = fail = 0
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futures = {ex.submit(fetch_part, args, i, p): i
                   for i, p in enumerate(parts)}
        for fut in as_completed(futures):
            idx, cnt, src = fut.result()
            if cnt >= 0:
                done += 1
            else:
                fail += 1
            if (done + fail) % 10 == 0 or (fail and done + fail <= 5) or cnt < 0:
                print("  进度 %d/%d  片%d=%s元素(%s)  失败%d"
                      % (done + fail, len(parts), idx, str(cnt), src, fail), flush=True)
    print("抓取结束：成功 %d，失败 %d；开始合并..." % (done, fail), flush=True)
    n = finalize(args.out)
    if n == 0:
        print("错误：无有效数据", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
