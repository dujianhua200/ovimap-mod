#!/usr/bin/env bash
# 内置路网重建流水线（v3.40）。
#
# 为什么需要这条流水线：随包路网是从高德 z14 矢量瓦片抓来的（见
# scripts/fetch_amap_vector.py），瓦片按网格裁剪，同一条路在相邻瓦片里
# 各存一份、且一条几公里的路被切成几十段。直接打包出图就会出现用户反馈的
# "道路有很多重复的、乱七八糟"：
#   · 重复 —— 同一条路画两遍，双线各偏几厘米，放大看是双影；
#   · 碎片 —— DXF 双线逐段算法线（_offsetPolyline），段越碎接缝越多，
#            两条边线在接缝处各自拐弯对不上。
#
# 所以打包前必须跑：
#   1) dedup_roads.py   去掉跨瓦片重复（8m 容差 + 双向覆盖率 0.80）
#   2) chain_roads.py   把首尾相接、属性相同的碎段连成整条路
#   3) simplify_pack.py Douglas-Peucker 1.5m + 确定性 gzip（旧 GeoJSON 回退路径）
#   4) build_road_index.py  分块二进制索引（导出实际读这个）
#
# 用法：
#   bash scripts/rebuild_roads.sh              # 用 data/amap_vec 里的全量
#   PY=python3 bash scripts/rebuild_roads.sh   # 指定解释器
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${PY:-python3}"
SRC="${SRC:-data/amap_vec/xinyang_amap_vec.geojson}"
WORK="${WORK:-data/amap_vec}"
TOL="${TOL:-1.5}"
CELL="${CELL:-0.08}"

if [ ! -f "$SRC" ]; then
  echo "缺少源数据：$SRC" >&2
  echo "先跑：$PY scripts/fetch_amap_vector.py --workers 20" >&2
  exit 1
fi

echo "=== 1/4 去重（跨瓦片重复拷贝）==="
"$PY" scripts/dedup_roads.py -i "$SRC" \
  -o "$WORK/xinyang_amap_vec_dedup.geojson" --report "$WORK/dedup.log"

echo "=== 2/4 链式合并（碎段连成整条路）==="
"$PY" scripts/chain_roads.py -i "$WORK/xinyang_amap_vec_dedup.geojson" \
  -o "$WORK/xinyang_amap_vec_clean.geojson" --report "$WORK/chain.log"

echo "=== 3/4 简化打包（GeoJSON 回退路径）==="
"$PY" scripts/simplify_pack.py -i "$WORK/xinyang_amap_vec_clean.geojson" \
  -o assets/buildings/xinyang_roads.geojson.gz --tol "$TOL"

echo "=== 4/4 重建分块索引 ==="
"$PY" tool/build_road_index.py --cell "$CELL"

echo
echo "完成。检查清单："
echo "  · chain.log 里「长度变化」应≈0.00%（非 0 说明链合并逻辑出错，勿提交）"
echo "  · 索引体积应小于 eq 源 gz；若明显变大，调大 --cell"
