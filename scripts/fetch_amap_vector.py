#!/usr/bin/env python3
"""高德矢量瓦片路网抓取器（z14 全量道路几何 + 路名）

原理
----
高德网页版 WebGL 渲染器通过 `POST https://jsapi.amap.com/web_map/get_tile`
换取矢量瓦片 PBF（自定义 protobuf，schema 见 maps.js）。关键规律：

* 瓦片编号是**等距圆柱**（Plate Carrée），不是 Web Mercator：
  x = floor(2^z*(lon+180)/360), y = floor(2^z*(90-lat)/180)
* 只有 z14 级别带道路数据，z15+ 全空，z13- 为奇数级别空
* type=1（flds=transit,road,region,building）→ 全量道路几何，无路名
* type=2（flds=transit,road,region,poi）    → 稀疏主干路，**带路名**
* 两者几何端点完全一致，可端点匹配把路名贴回全量几何

坐标系：瓦片内坐标是 GCJ-02，输出时统一转 WGS84（与项目其余数据一致）。

用法
----
    python3 scripts/fetch_amap_vector.py --workers 16 \
        --cache-dir data/amap_vec/.cache -o data/amap_vec/xinyang_amap_vec.geojson
"""
import argparse
import gzip
import json
import math
import os
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

KEY = '2f282f369e388ef01bae260cbc35edce'
VERSION = '26_10_26_00'
HDR = {
    'Content-Type': 'application/x-www-form-urlencoded',
    'Referer': 'https://www.amap.com/',
    'Origin': 'https://www.amap.com',
    'User-Agent': ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                   'AppleWebKit/537.36 (KHTML, like Gecko) '
                   'Chrome/158.0.0.0 Safari/537.36'),
}

# 信阳全域 bbox（WGS84）：lon 113.72~115.58, lat 31.20~32.58
XINYANG_BBOX = (113.72, 31.20, 115.58, 32.58)
ZOOM = 14

# 高德 mainKey → OSM highway 标签（用于项目既有等级体系）
MAINKEY_HIGHWAY = {
    20001: 'motorway',        # 高速
    20002: 'trunk',           # 环路
    20003: 'primary',         # 国道
    20004: 'secondary',       # 省道
    20007: 'tertiary',        # 二级道路
    20008: 'unclassified',    # 三级道路
    20009: 'residential',     # 四级道路（含村道/小路）
    20026: 'residential',     # 四级道路（另一组）
    20018: 'construction',    # 在建道路
    20023: 'construction',
    20010: 'railway',
    20031: 'tertiary',
    20032: 'tertiary',
}


# ---------------------------------------------------------------- protobuf
def _rv(b, i):
    r = 0
    s = 0
    while True:
        x = b[i]
        i += 1
        r |= (x & 0x7f) << s
        s += 7
        if not x & 0x80:
            return r, i


def _zz(v):
    return (v >> 1) ^ -(v & 1)


def _fields(b):
    out = []
    i = 0
    n = len(b)
    while i < n:
        k, i = _rv(b, i)
        fn = k >> 3
        w = k & 7
        if w == 0:
            v, i = _rv(b, i)
        elif w == 2:
            ln, i = _rv(b, i)
            v = b[i:i + ln]
            i += ln
        elif w == 5:
            v = b[i:i + 4]
            i += 4
        elif w == 1:
            v = b[i:i + 8]
            i += 8
        else:
            break
        out.append((fn, w, v))
    return out


def _g1(b, fn):
    if not isinstance(b, (bytes, bytearray)):
        return []
    return [v for f, w, v in _fields(b) if f == fn]


def _g0(b, fn):
    if not isinstance(b, (bytes, bytearray)):
        return []
    return [v for f, w, v in _fields(b) if f == fn and w == 0]


def _packed(b, fn):
    out = []
    for v in _g1(b, fn):
        if not isinstance(v, (bytes, bytearray)):
            continue
        i = 0
        while i < len(v):
            x, i = _rv(v, i)
            out.append(_zz(x))
    return out


def _lang(b):
    if not isinstance(b, (bytes, bytearray)):
        return ''
    f = _g1(b, 1)
    if not f:
        return ''
    v = f[0]
    return v.decode('utf-8', 'replace') if isinstance(v, (bytes, bytearray)) else ''


# ---------------------------------------------------------------- tiles
def tile_of(lon, lat, z):
    n = float(2 ** z)
    return int((lon + 180) / 360 * n), int((90 - lat) / 180 * n)


def tile_bbox(x, y, z):
    n = float(2 ** z)
    return (x / n * 360 - 180, 90 - (y + 1) / n * 180,
            (x + 1) / n * 360 - 180, 90 - y / n * 180)


def _gunzip(d):
    if d[:2] == b'\x1f\x8b':
        return gzip.decompress(d)
    if len(d) > 4:
        ln = int.from_bytes(d[:4], 'big')
        p = d[4:4 + ln]
        if p[:2] == b'\x1f\x8b':
            return gzip.decompress(p)
    return d


def _post(tiles, timeout=30, retries=4):
    body = urllib.parse.urlencode({
        'version': VERSION, 'pbf_version': 'v2', 'access_oversea': '1',
        'data_source': '1', 'multi_lang': '0', 'tiles': json.dumps(tiles),
    }).encode()
    last = ''
    for k in range(retries):
        try:
            r = urllib.request.urlopen(urllib.request.Request(
                'https://jsapi.amap.com/web_map/get_tile?key=' + KEY,
                data=body, headers=HDR), timeout=timeout)
            return json.loads(r.read())
        except Exception as e:  # noqa: BLE001
            last = str(e)
            time.sleep(1.2 * (k + 1))
    raise RuntimeError(last)


def fetch_tile(x, y, z, typ=1, timeout=30):
    """取单个瓦片的解压后 pbf 字节，失败返回 None。"""
    try:
        j = _post([{'id': '%d_%d_%d' % (x, y, z), 'type': typ,
                    'contain_range': 0}], timeout=timeout)
    except Exception:  # noqa: BLE001
        return None
    urls = j.get('tile_urls') or []
    if not urls:
        return None
    for k in range(3):
        try:
            r = urllib.request.urlopen(
                urllib.request.Request(urls[0], headers=HDR), timeout=timeout)
            return _gunzip(r.read())
        except Exception:  # noqa: BLE001
            time.sleep(1.2 * (k + 1))
    return None


def _decode_pts(ints):
    if len(ints) < 2:
        return []
    pts = [(ints[0], ints[1])]
    cx, cy = ints[0], ints[1]
    i = 2
    while i + 1 < len(ints):
        cx += ints[i]
        cy += ints[i + 1]
        pts.append((cx, cy))
        i += 2
    return pts


def _to_ll(pts, x, y, z, res):
    """瓦片整数坐标 → GCJ-02 经纬度。

    extent：x 用 2^12=4096，y 用 2048。瓦片经度跨度是纬度跨度的 2 倍
    （360/2^z vs 180/2^z），内部网格同比例。实测缓存 10922 瓦片：
    x 原始整数 0~4096、y 原始整数 0~2048，按此换算刚好铺满 bbox。

    y 轴方向：瓦片内 py 从**南边界**向北累积（py=0 对应 bbox 南界 lat0，
    py=2048 对应北界 lat1）。早先版本写成 lat1 - py/2048*(lat1-lat0)，
    方向正好相反，导致整片路网南北镜像。

    坐标系：瓦片坐标是 **GCJ-02**（火星坐标），不是 WGS-84。
    判据：直接用高德路径规划 /v3/direction/driving 返回的精确 GCJ 折线做真值，
    解出的矢量路与其平均距离为 **0.0m**（完全重合）；若当成 WGS-84
    会整体偏东约 555m（信阳），这正是「道路有很大偏移」的原因。
    调用方必须再经 gcj02_to_wgs84 转成 WGS-84 才能与 OSM/建筑底图对齐。
    """
    lon0, lat0, lon1, lat1 = tile_bbox(x, y, z)
    return [(lon0 + (px / 4096.0) * (lon1 - lon0),
             lat0 + (py / 2048.0) * (lat1 - lat0)) for px, py in pts]


def parse_roads(d, x, y, z):
    """解析道路层，返回 [(mainKey, name, uid, [(lon,lat)...])]。"""
    out = []
    if not d:
        return out
    inn = _g1(d, 1)
    if not inn:
        return out
    for L in _g1(inn[0], 4):
        if not isinstance(L, (bytes, bytearray)):
            continue
        if (_g0(L, 4) or [None])[0] != 1:
            continue
        pl = _g1(L, 5)
        if not pl:
            continue
        layer = pl[0]
        for ss in _g1(layer, 1):
            if not isinstance(ss, (bytes, bytearray)):
                continue
            mk = (_g0(ss, 1) or [20004])[0]
            res = (_g0(ss, 3) or [12])[0]
            for m in _g1(ss, 4):
                if not isinstance(m, (bytes, bytearray)):
                    continue
                for ft in _g1(m, 4):
                    if not isinstance(ft, (bytes, bytearray)):
                        continue
                    name = next((n for n in (_lang(b) for b in _g1(ft, 1)) if n), '')
                    uid = (_g0(ft, 7) or [0])[0]
                    pts = _to_ll(_decode_pts(_packed(ft, 5)), x, y, z, res)
                    if len(pts) >= 2:
                        out.append((mk, name, uid, pts))
    return out


# ---------------------------------------------------------------- geo
def gcj02_to_wgs84(lon, lat):
    """GCJ-02 火星坐标 → WGS84。"""
    a = 6378245.0
    ee = 0.00669342162296594323
    dlat = _tlat(lon - 105.0, lat - 35.0)
    dlon = _tlon(lon - 105.0, lat - 35.0)
    rad = lat / 180.0 * math.pi
    magic = 1 - ee * math.sin(rad) ** 2
    sq = math.sqrt(magic)
    dlat = (dlat * 180.0) / ((a * (1 - ee)) / (magic * sq) * math.pi)
    dlon = (dlon * 180.0) / (a / sq * math.cos(rad) * math.pi)
    # 高德矢量瓦片坐标是 GCJ-02，必须做此反偏移才能落到 WGS-84 上。
    # 判据：以 /v3/direction/driving 返回的精确 GCJ 折线为真值，
    # 反偏移后矢量路与其平均距离 0.0m；不做反偏移则整体偏东约 555m（信阳）。
    return lon - dlon, lat - dlat


def wgs84_to_gcj02(lon, lat):
    """WGS84 → GCJ-02（正向加密，用于逆变换迭代）。"""
    a = 6378245.0
    ee = 0.00669342162296594323
    dlat = _tlat(lon - 105.0, lat - 35.0)
    dlon = _tlon(lon - 105.0, lat - 35.0)
    rad = lat / 180.0 * math.pi
    magic = 1 - ee * math.sin(rad) ** 2
    sq = math.sqrt(magic)
    dlat = (dlat * 180.0) / ((a * (1 - ee)) / (magic * sq) * math.pi)
    dlon = (dlon * 180.0) / (a / sq * math.cos(rad) * math.pi)
    return lon + dlon, lat + dlat


def gcj02_to_wgs84_iter(lon, lat, n=2):
    """GCJ-02 → WGS-84 迭代逆变换（精度 1~2m），与项目 Dart 实现等价。"""
    wl, wa = lon, lat
    for _ in range(n):
        g = wgs84_to_gcj02(wl, wa)
        wl += lon - g[0]
        wa += lat - g[1]
    return wl, wa


def _tlat(x, y):
    r = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(abs(x))
    r += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0
    r += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0
    r += (160.0 * math.sin(y / 12.0 * math.pi) + 320 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0
    return r


def _tlon(x, y):
    r = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(abs(x))
    r += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0
    r += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0
    r += (150.0 * math.sin(x / 12.0 * math.pi) + 300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0
    return r


CACHE_DIR = 'data/amap_vec/.cache'


def _cache_path(x, y, z, typ):
    return os.path.join(CACHE_DIR, '%d' % z, str(x), '%d_%d.pbf' % (y, typ))


def _load_cached(x, y, z, typ):
    p = _cache_path(x, y, z, typ)
    if os.path.exists(p):
        try:
            with open(p, 'rb') as f:
                return f.read()
        except OSError:
            return None
    return None


def _save_cached(x, y, z, typ, d):
    p = _cache_path(x, y, z, typ)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(d)
    os.replace(tmp, p)


def tile_job(args):
    x, y, z = args
    out = {'x': x, 'y': y, 'z': z, 'roads': [], 'names': {}}
    # type=1 全量几何
    d = _load_cached(x, y, z, 1)
    if d is None:
        d = fetch_tile(x, y, z, 1)
        if d:
            _save_cached(x, y, z, 1, d)
    for mk, name, uid, pts in parse_roads(d, x, y, z):
        out['roads'].append((mk, uid, pts))
    # type=2 带路名（只留端点键，省内存）
    d2 = _load_cached(x, y, z, 2)
    if d2 is None:
        d2 = fetch_tile(x, y, z, 2)
        if d2:
            _save_cached(x, y, z, 2, d2)
    for mk, name, uid, pts in parse_roads(d2, x, y, z):
        if name:
            out['names'][(round(pts[0][0], 5), round(pts[0][1], 5),
                          round(pts[-1][0], 5), round(pts[-1][1], 5))] = name
    return out


def edge_key(pts):
    a = (round(pts[0][0], 5), round(pts[0][1], 5))
    b = (round(pts[-1][0], 5), round(pts[-1][1], 5))
    if a <= b:
        return (a[0], a[1], b[0], b[1])
    return (b[0], b[1], a[0], a[1])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bbox', default=None,
                    help='lon0,lat0,lon1,lat1 默认信阳全域')
    ap.add_argument('--zoom', type=int, default=ZOOM)
    ap.add_argument('--workers', type=int, default=16)
    ap.add_argument('--cache-dir', default=None)
    ap.add_argument('--limit', type=int, default=0, help='只抓前 N 个瓦片（调试）')
    ap.add_argument('-o', '--out', default='data/amap_vec/xinyang_amap_vec.geojson')
    ap.add_argument('--finalize', action='store_true',
                    help='不抓取，仅从缓存重建 GeoJSON')
    args = ap.parse_args()

    global CACHE_DIR
    if args.cache_dir:
        CACHE_DIR = args.cache_dir

    if args.bbox:
        lon0, lat0, lon1, lat1 = [float(v) for v in args.bbox.split(',')]
    else:
        lon0, lat0, lon1, lat1 = XINYANG_BBOX

    xa, ya = tile_of(lon0, lat1, args.zoom)   # 左上
    xb, yb = tile_of(lon1, lat0, args.zoom)   # 右下
    if xb < xa:
        xa, xb = xb, xa
    if yb < ya:
        ya, yb = yb, ya
    jobs = [(x, y, args.zoom)
            for x in range(xa, xb + 1)
            for y in range(ya, yb + 1)]
    if args.limit:
        jobs = jobs[:args.limit]

    sys.stderr.write('瓦片 %d~%d x %d~%d = %d 片, zoom=%d, workers=%d\n'
                     % (xa, xb, ya, yb, len(jobs), args.zoom, args.workers))

    feats = []
    seen = {}
    named_hits = 0
    done = 0
    t0 = time.time()

    if not args.finalize:
        with ThreadPoolExecutor(max_workers=args.workers) as ex:
            futs = [ex.submit(tile_job, j) for j in jobs]
            for fu in as_completed(futs):
                try:
                    r = fu.result()
                except Exception:  # noqa: BLE001
                    done += 1
                    continue
                done += 1
                for mk, uid, pts in r['roads']:
                    k = edge_key(pts)
                    if k in seen:
                        continue
                    seen[k] = True
                    name = r['names'].get(k, '')
                    if name:
                        named_hits += 1
                    feats.append((mk, name, uid, pts))
                if done % 500 == 0:
                    el = time.time() - t0
                    sys.stderr.write('  %d/%d (%.0f%%) %.0fs 累计线 %d 带名 %d\n'
                                     % (done, len(jobs), 100.0 * done / len(jobs),
                                        el, len(feats), named_hits))
    else:
        for x, y, z in jobs:
            r = tile_job((x, y, z))
            for mk, uid, pts in r['roads']:
                k = edge_key(pts)
                if k in seen:
                    continue
                seen[k] = True
                name = r['names'].get(k, '')
                if name:
                    named_hits += 1
                feats.append((mk, name, uid, pts))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    tmp = args.out + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write('{"type":"FeatureCollection","features":[\n')
        first = True
        for mk, name, uid, pts in feats:
            if not first:
                f.write(',\n')
            first = False
            # 瓦片解出的坐标是 GCJ-02，必须反偏移到 WGS-84 才能与 OSM/建筑底图对齐。
            wpts = [gcj02_to_wgs84(lo, la) for lo, la in pts]
            props = {
                'highway': MAINKEY_HIGHWAY.get(mk, 'unclassified'),
                'source': 'amap',
                'amap_mainkey': mk,
                'amap_uid': uid,
            }
            if name:
                props['name'] = name
            f.write(json.dumps({
                'type': 'Feature',
                'properties': props,
                'geometry': {'type': 'LineString',
                             'coordinates': [[round(a, 7), round(b, 7)] for a, b in wpts]},
            }, ensure_ascii=False))
        f.write('\n]}\n')
    os.replace(tmp, args.out)

    el = time.time() - t0
    size = os.path.getsize(args.out)
    sys.stderr.write('完成: %d 条路, 带名 %d, %.1fMB, %.0fs → %s\n'
                     % (len(feats), named_hits, size / 1048576.0, el, args.out))


if __name__ == '__main__':
    main()
