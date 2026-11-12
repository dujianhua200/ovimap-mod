"""用 ezdxf 严格打开导出的 DXF，并核对图例库块是否真的写进去了。

这不是"字符串匹配"式自证：ezdxf 是第三方 DXF 引擎，读不出/读不稳的文件，
AutoCAD / GstarCAD 同样有风险。本项目历史上正是被字符串断言坑过
（"R12 结构贴 AC1015 标签"），所以必须有这道真解析闸门。

用法：
    py -3 tool/validate_lispblock.py out/
"""

import glob
import sys

import ezdxf
from ezdxf import recover


def check(path):
    """严格打开 + 结构体检。返回问题列表（空 = 通过）。"""
    problems = []
    # 1) 严格打开：ezdxf.readfile 不接受结构错误。
    try:
        doc = ezdxf.readfile(path)
    except Exception as exc:  # noqa: BLE001 - 故意抓全部，报告原文
        # 2) 回退：recover 能救回一部分，但要记录"必须靠 recover"这件事
        try:
            doc, auditor = recover.readfile(path)
            problems.append(
                'readfile 失败（%s），只能靠 recover 打开；audit errors=%d'
                % (exc, len(auditor.errors))
            )
        except Exception as exc2:  # noqa: BLE001
            problems.append('recover 也失败：%s / %s' % (exc, exc2))
            return problems

    buf = []
    auditor = doc.audit()
    if auditor.has_errors:
        for e in auditor.errors:
            buf.append('audit error: %s' % (e.message,))
    if auditor.has_fixes:
        for f in auditor.fixes:
            buf.append('audit fix: %s' % (f.message,))

    # 3) 块定义：导出的图例块必须真的存在于 BLOCKS 表
    block_names = {b.name for b in doc.blocks}
    expected = {'gl001', 'gx005_x', 'lx001'}
    missing = expected - block_names
    if missing:
        buf.append('缺少块定义：%s（现有 %s）' % (sorted(missing), sorted(block_names)))

    # 4) 实体段里必须有对这些块的 INSERT（图例栏 + 图上符号）
    msp = doc.modelspace()
    inserted = {}
    for e in msp:
        if e.dxftype() == 'INSERT':
            inserted[e.dxf.name] = inserted.get(e.dxf.name, 0) + 1
    for name in expected:
        if inserted.get(name, 0) == 0:
            buf.append('实体段没有 INSERT %s' % name)

    # 5) 版本相关硬约束：R12 不许出现 R2000 专有实体
    ver = doc.dxfversion
    if ver == 'AC1009':
        bad = [e.dxftype() for e in msp
               if e.dxftype() in ('LWPOLYLINE', 'HATCH', 'SPLINE', 'ELLIPSE')]
        if bad:
            buf.append('R12 里出现 2007 专有实体：%s' % sorted(set(bad)))

    print('%-28s ver=%-7s blocks=%-4d inserts=%s %s'
          % (path.split('/')[-1].split('\\')[-1], ver, len(block_names),
             dict(sorted(inserted.items())), 'OK' if not buf else 'FAIL'))
    problems.extend(buf)
    return problems


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else 'out'
    files = sorted(glob.glob(target + '/*.dxf'))
    if not files:
        print('没有找到 DXF：', target)
        return 2
    failed = 0
    for f in files:
        probs = check(f)
        for p in probs:
            print('   !', p)
        if probs:
            failed += 1
    print('\n%d/%d 通过' % (len(files) - failed, len(files)))
    return 0 if failed == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
