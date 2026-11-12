#!/usr/bin/env python3
"""下载指定区域的矢量数据 → GeoJSON（默认信阳市全域）。
- OSM（Overpass）：建筑 Polygon / 道路 LineString / 地名 Point
- 天地图 WFS 居民地面（RESA）：居民地/村落范围 Polygon（农村覆盖完整）
分片并发，多镜像分流 + 失败重试 + 限流退避。
"""
import json
import os
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

import sys as _sys
# 用法：python fetch_osm_geojson.py [lat_min,lon_min,lat_max,lon_max] [输出路径]
#   例：python fetch_osm_geojson.py 31.33,113.66,32.70,116.02 /tmp/xinyang.geojson
_argv = _sys.argv[1:]
if len(_argv) >= 1 and ',' in _argv[0]:
    _b = [float(x) for x in _argv[0].split(',')]
    LAT_MIN, LAT_MAX, LON_MIN, LON_MAX = _b[0], _b[2], _b[1], _b[3]
else:
    LAT_MIN, LAT_MAX, LON_MIN, LON_MAX = 31.33, 32.70, 113.66, 116.02
OUT = _argv[1] if len(_argv) >= 2 else "/tmp/osm_export.geojson"

# 信阳市全域 bbox（含各区县）
STEP = 0.20  # 分片大小（度）

OVERPASS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.openstreetmap.fr/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
TDT_WFS = "https://gisserver.tianditu.gov.cn/TDTService/wfs"

lock = threading.Lock()
seen_ways = set()
buildings, roads, places, residential_areas = [], [], [], []
stat = {"tiles_ok": 0, "tiles_fail": 0}
_mirror_i = [0]


def next_mirror():
    with lock:
        _mirror_i[0] += 1
        return OVERPASS[_mirror_i[0] % len(OVERPASS)]


def overpass(data, timeout=120, tries=3):
    last = None
    for t in range(tries):
        ep = next_mirror()
        try:
            body = urllib.parse.urlencode({"data": data}).encode()
            req = urllib.request.Request(
                ep, data=body,
                headers={"User-Agent": "ovimap-geojson/1.0",
                         "Content-Type": "application/x-www-form-urlencoded"})
            return json.load(urllib.request.urlopen(req, timeout=timeout))
        except Exception as e:
            last = e
            time.sleep(2.0 + t * 3.0)  # 退避
    raise RuntimeError(str(last))


def fetch_tile(bbox):
    q = ("[out:json][timeout:120];("
         f'way["building"]({bbox});'
         f'way["highway"]({bbox});'
         f'node["place"]({bbox});'
         f'way["place"]({bbox});'
         f'way["landuse"="residential"]["name"]({bbox});'
         ");out geom tags;")
    res = overpass(q)
    n = 0
    for el in res.get("elements", []):
        typ = el.get("type")
        tags = el.get("tags", {}) or {}
        if typ == "node":
            if tags.get("place") and tags.get("name"):
                with lock:
                    places.append(_pt(el["lon"], el["lat"], tags["name"], tags.get("place", "")))
                    n += 1
            continue
        if typ != "way":
            continue
        wid = el.get("id")
        with lock:
            if wid in seen_ways:
                continue
            seen_ways.add(wid)
        geom = el.get("geometry") or []
        if len(geom) < 2:
            continue
        coords = [[round(g["lon"], 6), round(g["lat"], 6)] for g in geom]
        if tags.get("building"):
            ring = coords[:]
            if ring[0] != ring[-1]:
                ring.append(ring[0])
            if len(ring) < 4:
                continue
            with lock:
                buildings.append({"type": "Feature",
                                  "geometry": {"type": "Polygon", "coordinates": [ring]},
                                  "properties": {"name": tags.get("name", "")}})
                n += 1
        elif tags.get("highway"):
            hw = tags["highway"]
            if hw in ("footway", "steps", "cycleway", "pedestrian", "bridleway") and not tags.get("name"):
                continue
            with lock:
                roads.append({"type": "Feature",
                              "geometry": {"type": "LineString", "coordinates": coords},
                              "properties": {"name": tags.get("name", ""), "highway": hw}})
                n += 1
        elif tags.get("place") and tags.get("name"):
            with lock:
                places.append(_pt(coords[len(coords) // 2][0], coords[len(coords) // 2][1],
                                  tags["name"], tags.get("place", "")))
                n += 1
        elif tags.get("landuse") == "residential" and tags.get("name"):
            with lock:
                places.append(_pt(coords[len(coords) // 2][0], coords[len(coords) // 2][1],
                                  tags["name"], "residential"))
                n += 1
    return n


def _pt(lon, lat, name, kind):
    return {"type": "Feature",
            "geometry": {"type": "Point", "coordinates": [round(lon, 6), round(lat, 6)]},
            "properties": {"name": name, "kind": kind}}


def fetch_resa(tile_bbox):
    """天地图居民地面（1:100万，村落/居民地范围）——农村覆盖完整。"""
    minlat, minlon, maxlat, maxlon = tile_bbox
    url = (f"{TDT_WFS}?service=WFS&version=1.0.0&request=GetFeature"
           f"&typeName=TDTService:RESA&outputFormat=application/json"
           f"&maxFeatures=2000&bbox={minlon},{minlat},{maxlon},{maxlat}")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ovimap-geojson/1.0"})
        d = json.load(urllib.request.urlopen(req, timeout=60))
    except Exception:
        return 0
    n = 0
    for f in d.get("features", []):
        g = f.get("geometry") or {}
        if g.get("type") != "MultiPolygon":
            continue
        for poly in g.get("coordinates", []):
            # 只保留与本片有交集的环（WFS 可能返回框外要素）
            pts = poly[0] if poly else []
            if not pts:
                continue
            lons = [p[0] for p in pts]
            lats = [p[1] for p in pts]
            if max(lats) < minlat or min(lats) > maxlat:
                continue
            if max(lons) < minlon or min(lons) > maxlon:
                continue
            ring = [[round(p[0], 6), round(p[1], 6)] for p in pts]
            with lock:
                residential_areas.append({"type": "Feature",
                                          "geometry": {"type": "Polygon", "coordinates": [ring]},
                                          "properties": {"kind": "residential_area"}})
                n += 1
    return n


def main():
    tiles = []
    lat = LAT_MIN
    while lat < LAT_MAX:
        lon = LON_MIN
        while lon < LON_MAX:
            tiles.append((round(lat, 4), round(lon, 4),
                          round(min(lat + STEP, LAT_MAX), 4),
                          round(min(lon + STEP, LON_MAX), 4)))
            lon += STEP
        lat += STEP
    print(f"共 {len(tiles)} 片，开始下载...", flush=True)

    done = 0
    with ThreadPoolExecutor(max_workers=4) as ex:
        futs = {}
        for t in tiles:
            bbox = f"{t[0]},{t[1]},{t[2]},{t[3]}"
            futs[ex.submit(fetch_tile, bbox)] = bbox
        for fu in as_completed(futs):
            done += 1
            try:
                fu.result()
                stat["tiles_ok"] += 1
            except Exception as e:
                stat["tiles_fail"] += 1
                if stat["tiles_fail"] <= 5:
                    print(f"  片失败 {futs[fu]}: {str(e)[:80]}", flush=True)
            if done % 10 == 0 or done == len(tiles):
                print(f"  [{done}/{len(tiles)}] 建筑 {len(buildings)} 道路 {len(roads)} "
                      f"地名 {len(places)} 失败 {stat['tiles_fail']}", flush=True)

    print("OSM 完成，开始天地图居民地面...", flush=True)
    r_tiles = []
    lat = LAT_MIN
    while lat < LAT_MAX:
        lon = LON_MIN
        while lon < LON_MAX:
            r_tiles.append((round(lat, 4), round(lon, 4),
                            round(min(lat + 0.4, LAT_MAX), 4),
                            round(min(lon + 0.4, LON_MAX), 4)))
            lon += 0.4
        lat += 0.4
    with ThreadPoolExecutor(max_workers=3) as ex:
        list(ex.map(fetch_resa, r_tiles))
    print(f"居民地面 {len(residential_areas)} 个", flush=True)

    feats = buildings + roads + residential_areas + places
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"type": "FeatureCollection", "features": feats}, f,
                  ensure_ascii=False, separators=(",", ":"))
    mb = os.path.getsize(OUT) / 1048576
    print(f"\n完成：建筑 {len(buildings)} / 道路 {len(roads)} / "
          f"居民地班块 {len(residential_areas)} / 地名 {len(places)}")
    print(f"输出：{OUT}  ({mb:.1f} MB)")


if __name__ == "__main__":
    main()
