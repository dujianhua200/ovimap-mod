#!/usr/bin/env bash
# 按符号名整段导出 Dart 源码（花括号配平；逐行输出，不截断、不断流）
#
# ## 为什么需要它
# 看某个函数实现时的常规做法是
#     grep -n 函数名 lib/export/dxf.dart | head -1
#     sed -n '起,起+22p' 文件
# 两个老毛病：
#   1) 取多少行靠手猜，22 行常在函数中间截断，看起来就像"输出断了"；
#   2) grep 会先撞上调用处（`_text(c, ...)`），打印出来的根本不是定义。
# 本脚本只认「定义行」，再按 `{`/`}` 配平跑到函数闭合处；
# 全程逐行 print，中间不挂 head/cut，避免上游提前关管道触发 SIGPIPE 造成断流。
#
# ## 用法
#   scripts/dump_dart_symbol.sh [-f FILE] [-o OUT] [--follow] 符号名...
#
#   -f FILE    源文件（相对项目根或绝对路径），默认 lib/export/dxf.dart
#   -o OUT     结果写入文件；不写则直接打到标准输出
#   --follow   生成的同时用 tail -f 跟随 OUT，边写边看（必须配 -o，Ctrl-C 结束）
#   -h         显示本帮助
#
# ## 例
#   scripts/dump_dart_symbol.sh _text
#   scripts/dump_dart_symbol.sh -o /tmp/t.txt _text _appendStake _roadLabelM
#   scripts/dump_dart_symbol.sh -f lib/export/dxf.dart --follow -o /tmp/t.txt _text

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

FILE="lib/export/dxf.dart"
OUT=""
FOLLOW=0
SYMS=()

usage() {
  sed -n 's/^# \{0,1\}//p' "$0" | sed -n '/^按符号名/,/^   scripts\/dump_dart_symbol.sh -f/p'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -f) FILE="${2:-}"; shift 2 ;;
    -o) OUT="${2:-}"; shift 2 ;;
    --follow) FOLLOW=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do SYMS+=("$1"); shift; done ;;
    -*) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    *) SYMS+=("$1"); shift ;;
  esac
done

# 相对路径按「当前目录」优先、其次「项目根」解析
resolve_file() {
  local p="$1"
  if [ -f "$p" ]; then
    printf '%s\n' "$p"; return 0
  fi
  if [ -f "$PROJECT_ROOT/$p" ]; then
    printf '%s\n' "$PROJECT_ROOT/$p"; return 0
  fi
  return 1
}

# 找定义行：`符号名(` 之前必须还有「修饰符/返回类型」这一类 token。
# 纯调用行（缩进后直接 `符号名(`）没有前导 token，因此被自然排除，
# 不需要靠 `grep -v ';'` 这种粗暴过滤——那会把单行箭头函数
# `static double _mmOf(double mm, int scale) => mm;` 一起误杀。
find_def_line() {
  local sym="$1" f="$2"
  grep -nE "^[[:space:]]*(static[[:space:]]+)?[A-Za-z_][A-Za-z0-9_<>,.? ]*[[:space:]]${sym}\(" "$f" \
    | grep -v '^[0-9]*:[[:space:]]*//' \
    | head -1 | cut -d: -f1
}

# 从定义行打到花括号配平为止
dump_one() {
  local sym="$1" f="$2" start
  start=$(find_def_line "$sym" "$f")
  if [ -z "$start" ]; then
    printf '==== %s 未找到定义 ====\n' "$sym"
    return 1
  fi
  awk -v s="$start" -v name="$sym" '
    NR < s { next }
    NR == s { printf "==== %s @ %s ====\n", name, s }
    {
      print
      # 单行箭头函数（`=> expr;` / 抽象声明 `;`）：本行打完即结束。
      # 没有这层判断，配平永远等不到花括号闭合，会一路输出到文件末尾。
      if (NR == s && $0 ~ /;[[:space:]]*$/ && $0 !~ /\{/) { done = 1; exit }
      line = $0
      t1 = line; o = gsub(/\{/, "", t1)
      t2 = line; c = gsub(/\}/, "", t2)
      depth += o - c
      if (o > 0) started = 1
      if (started && depth <= 0) { done = 1; exit }
    }
    END {
      if (started && !done)
        printf "\n[警告] %s 未检测到闭合花括号，已输出到文件末尾\n", name > "/dev/stderr"
    }
  ' "$f"
}

gen() {
  local sym
  for sym in "${SYMS[@]}"; do
    dump_one "$sym" "$src"
    echo
  done
}

# 边生成边打印：轮询文件行数，只打新增部分。
#
# ## 为什么不用 tail -f
# `tail -f "$OUT" &` 再用 `kill` + `wait` 收尾，在 macOS 的 bash 3.2 上会卡死：
# `wait "$tail_pid"` 迟迟不返回，整条命令挂住不退出（实测 2 分钟仍未结束）。
# 轮询方案只用当前 shell，没有子进程要回收，生成一结束必定退出。
follow_poll() {
  local f="$1" pid="$2" seen=0 total
  while :; do
    total=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    total=${total:-0}
    if [ "$total" -gt "$seen" ]; then
      sed -n "$((seen + 1)),${total}p" "$f"
      seen=$total
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      total=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
      total=${total:-0}
      if [ "$total" -gt "$seen" ]; then
        sed -n "$((seen + 1)),${total}p" "$f"
      fi
      break
    fi
    sleep 0.1
  done
}

if [ ${#SYMS[@]} -eq 0 ]; then
  usage >&2
  exit 2
fi

if ! src=$(resolve_file "$FILE"); then
  echo "找不到源文件：$FILE" >&2
  exit 1
fi

if [ -z "$OUT" ]; then
  if [ "$FOLLOW" -eq 1 ]; then
    echo "--follow 需要同时用 -o 指定输出文件" >&2
    exit 2
  fi
  gen
  exit $?
fi

: > "$OUT"

if [ "$FOLLOW" -eq 1 ]; then
  gen >> "$OUT" 2>&1 &
  gen_pid=$!
  follow_poll "$OUT" "$gen_pid"
  wait "$gen_pid" 2>/dev/null
else
  gen > "$OUT" 2>&1
fi

printf '已写入 %s（%s 行）\n' "$OUT" "$(wc -l < "$OUT" | tr -d ' ')"
