#!/usr/bin/env python3
"""检查仓库内所有文本文件是否为合法 UTF-8（无 BOM）。

## 为什么需要这个
本项目在 Windows 上开发，Windows 的「默认编码」是 GBK/CP936。
一旦某个文件里出现中文注释，而写它的工具按系统默认编码落盘，
就会出现「GitHub 上构建失败、本机却毫无征兆」的情况。

真实事故（v3.10.0）：
  .gitignore 被我追加了一行中文注释，PowerShell 的 Out-File 按 GBK 写回，
  于是整文件变成 GBK。本机一切正常，但 macOS runner 上
  `flutter build macos` 直接崩在：
    FileSystemException: Failed to decode data using encoding 'utf-8',
    path = '.gitignore'
  —— Flutter/Xcode 工具链会读 .gitignore，读到非法 UTF-8 就整体失败。

这类问题靠人眼 review 抓不住，必须在 CI 上机械地卡住。

## 判据
- 允许：无 BOM 的 UTF-8（本项目全部源码/配置/文档的标准）
- 禁止：GBK/CP936 内容、UTF-8 BOM（`EF BB BF`）
  两者都会让跨平台工具链解析失败或产生多余字节。

二进制文件（图片、dxf、keystore 等）按扩展名跳过。

用法：
    python3 tool/check_encoding.py
退出码：0 = 全部合法；1 = 存在非法文件（列出路径与首个出错字节偏移）。
"""

import subprocess
import sys

# 按扩展名跳过的二进制/不可文本化文件
BINARY_EXT = {
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.bmp',
    '.zip', '.gz', '.tar', '.dmg', '.apk', '.aab', '.ipa',
    '.keystore', '.jks', '.p12', '.pfx',
    '.dxf',        # AutoCAD 图例库（ASCII 组码 + GBK 中文，按设计不是 UTF-8）
    '.dwg', '.bak',
    '.so', '.dll', '.dylib', '.exe', '.bin', '.woff', '.woff2', '.ttf',
}

# 按文件名精确跳过的（无扩展名或有特殊用途）
SKIP_NAMES = {
    'lispblock.dxf',
}

BOM = b'\xef\xbb\xbf'


def tracked_files() -> list[str]:
    out = subprocess.run(
        ['git', 'ls-files', '-z'],
        capture_output=True, check=True,
    ).stdout
    return [p for p in out.decode('utf-8', 'surrogateescape').split('\0') if p]


def check(path: str) -> str | None:
    """返回问题描述；None 表示通过。"""
    try:
        data = open(path, 'rb').read()
    except OSError as exc:
        return f'无法读取：{exc}'

    if data.startswith(BOM):
        return '含 UTF-8 BOM（应为无 BOM）'

    try:
        data.decode('utf-8')
    except UnicodeDecodeError as exc:
        # 给出可定位的信息：失败字节偏移 + 附近字节
        start = max(0, exc.start - 12)
        near = data[start:exc.start + 12]
        hint = ''
        try:
            hint = f'（按 GBK 解码为：{near.decode("gbk", "replace")!r}）'
        except Exception:
            pass
        return (f'非法 UTF-8：偏移 {exc.start}，'
                f'字节 {near.hex(" ")}{hint}')
    return None


def main() -> int:
    files = tracked_files()
    bad: list[tuple[str, str]] = []
    checked = 0

    for f in files:
        name = f.rsplit('/', 1)[-1]
        ext = ''
        if '.' in name:
            ext = '.' + name.rsplit('.', 1)[-1].lower()
        if ext in BINARY_EXT or name in SKIP_NAMES:
            continue
        checked += 1
        problem = check(f)
        if problem:
            bad.append((f, problem))

    print(f'检查了 {checked} 个文本文件（共 {len(files)} 个已跟踪文件）')

    if bad:
        print()
        for f, why in bad:
            print(f'  [FAIL] {f}')
            print(f'         {why}')
        print()
        print(f'!! {len(bad)} 个文件编码非法。')
        print('   修复：把该文件另存为「UTF-8 无 BOM」。')
        print('   Windows 上注意：PowerShell 的 Out-File 默认按系统编码写盘，')
        print('   应显式使用 -Encoding utf8NoBOM 或 [IO.File]::WriteAllText + UTF8Encoding($false)。')
        return 1

    print('全部为合法 UTF-8（无 BOM）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
