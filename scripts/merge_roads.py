#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
合并 OSM 路网与高德采样路网，最大化信阳地区道路覆盖度。

两源互补：
  - OSM：几何全、小路（footway/path/service/track）多，但路名覆盖仅 ~23%。
  - 高德：路名全（~78%）、主干道与新建路多，但小路几何少。
两者均为 WGS84、GeoJSON [lon,lat]，可直接合并。

合并规则：
  1. 清洗高德路名（去“途径XX”冗余，保留真正的道路名）。
  2. 空间网格去重：高德某路 >50% 的点落在已有 OSM 路上 → 视为已覆盖，
     不重复加入；若那条 OSM 路无名则把高德路名补给它。
  3. 高德新增路（OSM 没有的）保留加入。
  4. 几何/属性统一：LineString / MultiLineString，properties={highway,name,source}。

用法：
  python3 scripts/merge_roads.py \\
      --osm data/amap_roads/xinyang_city.geojson \\
      --amap data/amap_roads/xinyang_amap.geojson \\
      -o data/amap_roads/xinyang_merged.geojson
"""
import argparse
import json
import os
from collections import defaultdict

GRID = 0.0003  # ~30-33m 空间网格


def clean_name(n):
    """清洗高德路名里的“途径XX”冗余。"""
    if not n:
        return ""
    n = n.strip()
    if "途径" in n:
        head, tail = n.split("途径", 1)
        if any(k in tail for k in ("桥", "服务区", "互通", "停车区", "收费站", "隧道")):
            return head.strip()
        if any(k in tail for k in ("高速", "国道", "省道", "县道", "乡道", "大道", "大街", "路", "街", "道")):
            return tail.strip()
        return head.strip()
    return n


def rings_of(geom):
    t = geom.get("type")
    c = geom.get("coordinates", [])
    if t == "LineString":
        return [c]
    if t == "MultiLineString":
        return [r for r in c if len(r) >= 2]
    return []


def gkey(la, lo):
    return (int(la / GRID), int(lo / GRID))


def nearby(g):
    for di in (-1, 0, 1):
        for dj in (-1, 0, 1):
            yield (g[0] + di, g[1] + dj)


def load(path, source):
    d = json.load(open(path, encoding="utf-8"))
    out = []
    for f in d.get("features", []):
        rings = rings_of(f.get("geometry", {}))
        if not rings:
            continue
        p = f.get("properties", {})
        out.append({
            "rings": rings,
            "highway": p.get("highway", "road"),
            "name": p.get("name", "") or "",
            "source": source,
        })
    return out


def merge(osm_feats, amap_feats):
    # OSM 点空间索引：网格 -> feature 下标集合
    idx = defaultdict(set)
    for i, f in enumerate(osm_feats):
        for ring in f["rings"]:
            for lo, la in ring:
                idx[gkey(la, lo)].add(i)

    added = named_filled = 0
    for a in amap_feats:
        a["name"] = clean_name(a["name"])
        total = hit = 0
        matched = defaultdict(int)
        for ring in a["rings"]:
            for lo, la in ring:
                total += 1
                got = False
                for k in nearby(gkey(la, lo)):
                    for i in idx.get(k, ()):
                        matched[i] += 1
                        got = True
                if got:
                    hit += 1
        covered = total > 0 and hit / total >= 0.5
        if covered:
            # 把高德路名补给匹配度最高的无名 OSM 路
            if a["name"] and matched:
                best = max(matched, key=matched.get)
                if not osm_feats[best]["name"]:
                    osm_feats[best]["name"] = a["name"]
                    osm_feats[best]["source"] = "osm+amap"
                    named_filled += 1
        else:
            osm_feats.append(a)
            added += 1

    return added, named_filled


def to_featurecollection(feats):
    out = []
    for f in feats:
        rings = f["rings"]
        geom = ({"type": "LineString", "coordinates": rings[0]}
                if len(rings) == 1 else
                {"type": "MultiLineString", "coordinates": rings})
        out.append({
            "type": "Feature",
            "properties": {
                "highway": f["highway"],
                "name": f["name"],
                "source": f["source"],
            },
            "geometry": geom,
        })
    return {"type": "FeatureCollection", "features": out}


def main():
    ap = argparse.ArgumentParser(description="合并 OSM + 高德路网")
    ap.add_argument("--osm", default="data/amap_roads/xinyang_city.geojson")
    ap.add_argument("--amap", default="data/amap_roads/xinyang_amap.geojson")
    ap.add_argument("-o", "--out", default="data/amap_roads/xinyang_merged.geojson")
    args = ap.parse_args()

    osm = load(args.osm, "osm")
    amap = load(args.amap, "amap")
    print("载入：OSM %d 条，高德 %d 条" % (len(osm), len(amap)))
    added, filled = merge(osm, amap)
    print("合并：高德新增 %d 条，补路名 %d 条" % (added, filled))
    fc = to_featurecollection(osm)
    tmp = args.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(fc, fh, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, args.out)
    print("输出：%d 条 -> %s (%.2f MB)" % (
        len(fc["features"]), args.out,
        os.path.getsize(args.out) / 1048576.0))


if __name__ == "__main__":
    main()
