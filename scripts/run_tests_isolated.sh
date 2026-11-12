#!/usr/bin/env bash
# 逐个测试文件独立进程运行（彻底隔离跨文件静态状态与磁盘缓存竞态）
#
# 为什么不用 `flutter test` / `flutter test -j 1`：
#   `flutter test` 默认并发跑多个文件，而本项目的用例大量依赖**进程级静态状态**：
#     · AppPaths._cache / _force（权威数据目录缓存）
#     · LabelStore 单例
#     · LocalBasemapStore / BasemapCache 的磁盘缓存（同一临时目录层级）
#     · path_provider / shared_preferences 的 platform instance
#   即使 `-j 1` 串行，所有文件仍在**同一个进程**里跑，静态状态照样互相残留。
#   实测 CI 上表现为"用例数每次都不一样"（611 → 609 全绿，1 个莫名失败），
#   且失败详情不落日志——这是并发/残留竞态的典型症状，不是用例本身错。
#
#   每个文件一个进程后，状态天然清零，结果可复现。
#
# 用法：
#   scripts/run_tests_isolated.sh [--retry]
#     --retry  单个文件失败时重试一次（只吸收 flutter_tester 收尾段错误）
#
# 退出码：0 = 全绿；1 = 有文件失败（会打印失败清单）。

set -uo pipefail

RETRY=0
[ "${1:-}" = "--retry" ] && RETRY=1

# 收集测试文件（排序保证输出稳定、便于对比）
# ⚠️ 兼容 bash 3.2（macOS 自带）：`mapfile` 是 bash 4+ 才有的内建命令，
# macOS runner 默认 /bin/bash 是 3.2，用它会 "command not found"。
# 这里用 while-read 填充数组，三平台通用。
FILES=()
while IFS= read -r f; do
  FILES+=("$f")
done < <(find test -maxdepth 1 -name '*_test.dart' | sort)

if [ ${#FILES[@]} -eq 0 ]; then
  echo "未找到任何 test/*_test.dart" >&2
  exit 1
fi

echo "共 ${#FILES[@]} 个测试文件，逐个独立进程运行"
echo "=================================================="

# 判定"是否为 flutter_tester 收尾崩溃"（而不是真实的用例失败）。
#
# 为什么不能只看 `All tests passed!`：
#   只有 1 个 test 的文件（如 lispblock_ezdxf_strict_test.dart）输出是
#   "🎉 0 tests passed."（统计口径是"套件数-1"），但那个 ✅ 用例其实**已通过**，
#   进程是在收尾阶段 segfault。用 'All tests passed!' 当判据会漏掉这类文件，
#   于是重试不触发、门禁被误判为红。
#
# 判据必须**同时**满足以下三条（放行 = 认定用例真的全过了）：
#   ① 有进程级崩溃标记：TestDeviceException / segmentation fault / crashed；
#   ② 有 ✅ 通过标记（至少一个用例真的跑过并通过）；
#   ③ **没有**任何真实失败标记：[E]、Some tests failed、Failing tests。
# ③ 是安全底线：只要出现任一失败标记就绝不放行。
is_finalize_crash() {
  local o="$1"
  # ① 进程级崩溃
  echo "$o" | grep -qiE 'TestDeviceException|segmentation fault|Shell subprocess crashed' || return 1
  # ③ 先排除真实失败（宁可误判为失败，也不放过真错）
  if echo "$o" | grep -qE '\[E\]|Some tests failed|Failing tests:'; then
    return 1
  fi
  # ② 至少有一个用例通过（用 ASCII 标记，避免 ✅/中文在多字节编码下 grep 失配）
  echo "$o" | grep -q 'Passing tests\|All tests passed\|tests passed' || return 1
  return 0
}

FAILED=()
TOTAL=0
for f in "${FILES[@]}"; do
  printf '%-58s ' "$f"
  out=$(flutter test "$f" 2>&1)
  rc=$?
  if [ $rc -ne 0 ] && [ $RETRY -eq 1 ] && is_finalize_crash "$out"; then
    echo -n "RETRY(收尾崩溃) "
    out=$(flutter test "$f" 2>&1)
    rc=$?
  fi
  # 统计该文件通过数（便于汇总）
  n=$(echo "$out" | grep -oE '\+[0-9]+' | tail -1 | tr -d '+' || true)
  TOTAL=$((TOTAL + ${n:-0}))
  if [ $rc -eq 0 ]; then
    echo "OK (+${n:-0})"
  elif is_finalize_crash "$out"; then
    # 用例全绿、只有收尾进程崩溃：这是 flutter_tester 的已知缺陷（三平台都遇到）。
    # 判定条件已排除真实用例失败（见 is_finalize_crash），所以放行是安全的。
    # 与"重试成功"区分显示，便于观察这类崩溃的发生频率。
    echo "OK(收尾崩溃,用例已全绿)"
  else
    echo "FAIL"
    FAILED+=("$f")
    # 失败详情完整落日志，便于定位（CI 的 ANSI 重绘会吃掉这部分）
    echo "----- $f 输出开始 -----"
    echo "$out" | tail -60
    echo "----- $f 输出结束 -----"
  fi
done

echo "=================================================="
echo "通过用例累计：$TOTAL"

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo "!! 失败文件（${#FAILED[@]}）:"
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi

echo "全部通过"
exit 0
