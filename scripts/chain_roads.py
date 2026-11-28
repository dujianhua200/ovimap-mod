#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""路网链式合并（v3.40）：把首尾相接、属性相同的碎段连成整条路。

## 为什么

高德 z14 矢量瓦片按瓦片边界裁剪，一条几公里的路会被切成几十段；同一路口
两侧也各是一段。实测信阳全量 205484 条里：

- 平均段长只有 394 米，**7.9% 的段短于 20 米**；
- 76% 的端点只被 1~2 条路共用（说明大量本可以连起来的路被切断了）。

DXF 里每一段都单独画双线（`_offsetPolyline` 逐段算法线），段与段的接缝处
两条边线各自拐弯、对不上，放大看就是"道路乱七八糟、双线断成一截一截"。
路名也按每段重复标注，同一路名密铺一路。

合并后同一条路是一条完整折线，双线连贯、路名按整条长度均匀布置一次。

## 判据

端点相连（容差 JOIN_DEG ≈1.1m）**且** (highway, name) 完全相同才连。
等级或路名不同说明是两条不同的路（哪怕几何相接），不合并。

连接点度数必须恰为 2。三岔口/十字路口（度数 ≥3）一律断开——那是真正的
路口，合并会把不同方向的路串成一条，反而更乱。

## 用法

    python3 scripts/chain_roads.py \
        -i data/amap_vec/xinyang_amap_vec_dedup.geojson \
        -o data/amap_vec/xinyang_amap_vec_final.geojson
"""
import argparse
import collections
import json
import math
import os
import sys
import time

# 端点合并容差：1e-5 度 ≈ 1.1 米（纬度）/ 0.94 米（信阳经度）。
# 比几何去重的 8 米小得多——这里只认同一个节点，不认同"靠得近"。
JOIN_DEG = 1e-5
# 合并后单条路的最大顶点数；超过就切断，避免个别超长要素拖慢下游简化/绘图。
MAX_PTS = 4000


def _plen(pts):
    if len(pts) < 2:
        return 0.0
    kx = math.cos(math.radians(pts[0][1])) * 111320.0
    t = 0.0
    for i in range(len(pts) - 1):
        t += math.hypot((pts[i + 1][0] - pts[i][0]) * kx,
                        (pts[i + 1][1] - pts[i][1]) * 110540.0)
    return t


def _ek(p):
    return (round(p[0] / JOIN_DEG), round(p[1] / JOIN_DEG))


def _props_key(feat):
    p = feat.get('properties') or {}
    return (p.get('highway') or '', (p.get('name') or '').strip(),
            p.get('amap_mainkey'))


def _join(a, b):
    """把 b 接到 a 后面；会自动判断方向并去掉重复的接缝点。"""
    ga = a
    gb = b
    # 判断 b 的哪一端与 a 的末端重合
    if _ek(ga[-1]) == _ek(gb[0]):
        out = ga + gb[1:]
    elif _ek(ga[-1]) == _ek(gb[-1]):
        out = ga + list(reversed(gb))[1:]
    elif _ek(ga[0]) == _ek(gb[-1]):
        out = gb + ga[1:]
    elif _ek(ga[0]) == _ek(gb[0]):
        out = list(reversed(gb)) + ga[1:]
    else:
        return None
    return out


def main():
    global JOIN_DEG, MAX_PTS
    ap = argparse.ArgumentParser()
    ap.add_argument('-i', '--input', required=True)
    ap.add_argument('-o', '--output', required=True)
    ap.add_argument('--join-deg', type=float, default=JOIN_DEG)
    ap.add_argument('--max-pts', type=int, default=MAX_PTS)
    ap.add_argument('--report', default='')
    args = ap.parse_args()

    JOIN_DEG = args.join_deg
    MAX_PTS = args.max_pts

    t0 = time.time()
    with open(args.input, encoding='utf-8') as f:
        src = json.load(f)
    feats = src['features']
    sys.stderr.write('读入 %d 条\n' % len(feats))

    geom = []       # geom[i] = 坐标数组
    meta = []       # meta[i] = 原始 properties
    for f in feats:
        g = (f.get('geometry') or {})
        pts = g.get('coordinates') or []
        geom.append([list(p) for p in pts])
        meta.append(f.get('properties') or {})

    # 端点 → [(idx, end)]；end=0 首端，1 末端
    at = collections.defaultdict(list)
    for i, pts in enumerate(geom):
        if len(pts) < 2:
            continue
        at[_ek(pts[0])].append((i, 0))
        at[_ek(pts[-1])].append((i, 1))

    def partner(idx, end):
        """从 (idx,end) 出发，找可以连接的下一段；不可连返回 None。"""
        pts = geom[idx]
        e = pts[-1] if end == 1 else pts[0]
        lst = at.get(_ek(e)) or []
        if len(lst) != 2:
            return None            # 端点/路口，断开
        other = lst[0] if lst[1][0] == idx else lst[1]
        if other[0] == idx:
            return None            # 自环
        j, jend = other
        if used[j]:
            return None
        if _props_key({'properties': meta[idx]}) != _props_key({'properties': meta[j]}):
            return None            # 等级/路名不同，是不同的路
        # 两侧都要未满
        if len(geom[idx]) >= MAX_PTS or len(geom[j]) >= MAX_PTS:
            return None
        return j, jend

    chains = []
    used = [False] * len(geom)

    # 先从"链头"（一端不可连）出发，能一次性拿到整条路
    order = list(range(len(geom)))
    for start in order:
        if used[start] or len(geom[start]) < 2:
            continue
        if partner(start, 1) is not None and partner(start, 0) is None:
            p0 = None
        else:
            continue            # 中段或环，留给后面处理
        cur = start
        chain = list(geom[cur])
        used[cur] = True
        while True:
            nxt = partner(cur, 1)
            if nxt is None:
                break
            j, jend = nxt
            joined = _join(chain, geom[j])
            if joined is None or len(joined) > MAX_PTS:
                break
            chain = joined
            used[j] = True
            cur = j
        chains.append((chain, start))

    # 剩下的：中段（两头都可连）与环路，按未用顺序各自成链
    for start in order:
        if used[start] or len(geom[start]) < 2:
            continue
        cur = start
        chain = list(geom[cur])
        used[cur] = True
        # 先往末端走
        while True:
            nxt = partner(cur, 1)
            if nxt is None:
                break
            j, jend = nxt
            joined = _join(chain, geom[j])
            if joined is None or len(joined) > MAX_PTS:
                break
            chain = joined
            used[j] = True
            cur = j
        # 再往首端走
        cur = start
        while True:
            back = partner(cur, 0)
            if back is None:
                break
            j, jend = back
            joined = _join(chain, geom[j])
            if joined is None or len(joined) > MAX_PTS:
                break
            chain = joined
            used[j] = True
            cur = j
        chains.append((chain, start))

    # 未参与（点数<2）的原样保留
    for i, pts in enumerate(geom):
        if not used[i] and len(pts) < 2:
            chains.append((pts, i))
            used[i] = True

    out_feats = []
    for pts, src_i in chains:
        if len(pts) < 2:
            continue
        out_feats.append({
            'type': 'Feature',
            'properties': dict(meta[src_i]),
            'geometry': {'type': 'LineString',
                         'coordinates': [[round(p[0], 7), round(p[1], 7)] for p in pts]},
        })

    src['features'] = out_feats
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    tmp = args.output + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(src, f, ensure_ascii=False)
    os.replace(tmp, args.output)

    in_len = sum(_plen(g) for g in geom) / 1000.0
    out_len = sum(_plen(f['geometry']['coordinates']) for f in out_feats) / 1000.0
    rep = [
        '输入 %d 条 / %.0f km' % (len(feats), in_len),
        '输出 %d 条 / %.0f km' % (len(out_feats), out_len),
        '实体数减少 %.1f%%' % (100.0 * (1 - len(out_feats) / max(1, len(feats)))),
        '长度变化 %+.2f%%（应≈0，仅接缝重复点被去掉）'
        % (100.0 * (out_len - in_len) / max(1e-9, in_len)),
        '连接容差 %.1e 度 / 单条上限 %d 点' % (JOIN_DEG, MAX_PTS),
    ]
    text = '\n'.join(rep) + '\n耗时 %.0fs' % (time.time() - t0)
    sys.stderr.write(text + '\n')
    if args.report:
        with open(args.report, 'w', encoding='utf-8') as f:
            f.write(text + '\n')


if __name__ == '__main__':
    main()
