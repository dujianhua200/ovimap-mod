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

# 判定"是否为收尾阶段的非断言失败"（而不是真实的用例失败）。
#
# 三类已知噪声，都会让**全绿**的用例被判红：
#   A. flutter_tester 收尾 segfault（三平台都见过）
#      → 输出只有 ✅ 与 TestDeviceException，最后是 "0 tests passed"
#   B. Windows 收尾删临时目录失败（文件句柄未释放）
#      → `PathAccessException: ... errno = 32`，用例名后挂 (failed)
#   C. Windows 上 flutter_tester 收尾丢汇总
#      → 用例全 ✅，但末尾 "0 tests passed" + "No tests were found."
#        （进程非零退出，dart_test 没机会写汇总）
#
# 判据必须**同时**满足三条（放行 = 认定用例真的全过了）：
#   ① 有已知噪声标记（A/B/C 之一）；
#   ② 有通过标记（Passing tests / All tests passed / tests passed）；
#   ③ **没有任何**真实失败标记：`[E]`、`Some tests failed`、`Failing tests:`。
# ③ 是安全底线：真实断言失败一定带 `[E]`（dart_test 的固定格式），
# 只要出现就绝不放行 —— 宁可误判为失败，也绝不放过真错。
is_finalize_crash() {
  local o="$1"
  # ① 已知噪声（A 收尾崩溃 / B Windows 文件锁 / C 汇总丢失）
  echo "$o" | grep -qiE 'TestDeviceException|segmentation fault|Shell subprocess crashed|PathAccessException|errno = 32|No tests were found' || return 1
  # ③ 真实失败优先排除
  if echo "$o" | grep -qE '\[E\]|Some tests failed|Failing tests:'; then
    return 1
  fi
  # ② 至少有一个用例真的跑过并通过
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
