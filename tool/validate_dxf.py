#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DXF 真实解析器闸门（P0-2）——用 ezdxf **严格** readfile 打开导出样本。

为什么需要它（上一轮的事故教训）：
  仅做「字符串 matching」（如断言文件含 AC1015 / 370 / 420）**证明不了文件合法**。
  曾把「R12 结构贴上 AC1015 标签」直接产出 → 不同 CAD 容错不同 → 用户「碰运气能打开」，
  被强行打开时还静默丢弃解析不了的实体（建筑填充 HATCH 首当其冲）。
  因此本闸门用成熟解析器 ezdxf 做**端到端严格打开**（ezdxf.readfile，非 recover），
  任何文件打不开即非零退出，从而在交付前拦住「打不开的文件」。

用法：
  # 先由 Dart 生成样本：flutter test test/dxf_samples_export_test.dart
  python3 tool/validate_dxf.py                       # 默认校验 build/dxf_samples
  python3 tool/validate_dxf.py path/to/a.dxf dir2/   # 指定文件/目录

退出码：全部严格打开成功 → 0；有任一失败 → 1；未找到样本 → 2。
"""

import os
import sys
import glob

try:
    import ezdxf
except Exception as e:  # pragma: no cover
    print(f"[ERROR] 无法导入 ezdxf：{e}")
    sys.exit(2)


def collect(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            out += sorted(glob.glob(os.path.join(p, "**", "*.dxf"), recursive=True))
        elif os.path.isfile(p):
            out.append(p)
    return out


def main(argv):
    targets = collect(argv[1:] or ["build/dxf_samples"])
    if not targets:
        print("未找到任何 .dxf 样本（先运行: flutter test test/dxf_samples_export_test.dart）")
        return 2

    print(f"ezdxf {getattr(ezdxf, '__version__', '?')} —— 严格 readfile 校验 {len(targets)} 个文件\n")
    bad = 0
    for f in targets:
        try:
            doc = ezdxf.readfile(f)
            msp = list(doc.modelspace())
            layers = sorted({e.dxf.layer for e in msp})
            print(f"OK   {f}\n     ver={doc.dxfversion}  entities={len(msp)}  layers={layers}")
        except Exception as e:
            bad += 1
            print(f"FAIL {f}\n     {type(e).__name__}: {e}")

    print(f"\n通过 {len(targets) - bad}/{len(targets)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
