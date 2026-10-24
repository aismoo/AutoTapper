#!/usr/bin/env bash
#
#  build.sh — AutoTapper 一键编译 / 自检（WSL2 / macOS / Linux 通用）
#
#  用法：
#     ./build.sh              # 自检 + 编译 deb
#     ./build.sh dylib        # 自检 + 只编 dylib（不打包）
#     ./build.sh clean        # 清掉 .theos / packages
#     ./build.sh check        # 只跑离线自检，不需要 Theos
#
#  前置：export THEOS=$HOME/theos （含 sdks/）
#
set -uo pipefail
cd "$(dirname "$0")"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

MODE="${1:-package}"

# ---------------------------------------------------------------- 离线自检
run_checks() {
    local py=""
    # 不能只看 command -v：Windows 上 python/python3 常是 Microsoft Store 的
    # 「应用执行别名」占位 exe，存在但一跑就报 "Python was not found"。
    # 必须真正执行一次确认可用。
    for c in python3 python py; do
        if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
            py="$c"; break
        fi
    done
    if [ -z "$py" ]; then
        warn "没找到 python，跳过离线自检（不影响编译）"
        return 0
    fi
    say "离线自检（括号 / 选择子 / 符号）"
    local fail=0
    for s in balance_check sel_check sym_check; do
        if "$py" "tools/$s.py" >/tmp/at_$s.log 2>&1; then
            printf '   %s%s%s %s\n' "$GRN" "ok  " "$RST" "$s"
        else
            printf '   %s%s%s %s\n' "$RED" "FAIL" "$RST" "$s"
            sed 's/^/        /' /tmp/at_$s.log | head -20
            fail=1
        fi
    done
    [ "$fail" -eq 0 ] || die "自检未通过，先修上面报的问题再编译"
}

# ---------------------------------------------------------------- 环境检查
require_theos() {
    [ -n "${THEOS:-}" ] || die "THEOS 未设置：export THEOS=\$HOME/theos"
    [ -d "$THEOS" ]      || die "THEOS 目录不存在：$THEOS"
    [ -f "$THEOS/makefiles/common.mk" ] || die "THEOS 不像 Theos 根目录（缺 makefiles/common.mk）：$THEOS"
    if [ ! -d "$THEOS/sdks" ] || [ -z "$(ls -A "$THEOS/sdks" 2>/dev/null)" ]; then
        die "缺 iOS SDK：$THEOS/sdks 为空。执行
       git clone --depth 1 https://github.com/theos/sdks.git \"\$THEOS/sdks\""
    fi
    command -v make >/dev/null 2>&1 || die "没装 make"
}

# ---------------------------------------------------------------- 主流程
case "$MODE" in
    check)
        run_checks
        say "自检完成"
        exit 0
        ;;
    clean)
        say "清理"
        rm -rf .theos packages
        say "已清理 .theos / packages"
        exit 0
        ;;
    dylib|package) ;;
    *)
        die "未知参数：$MODE（可用：package / dylib / clean / check）"
        ;;
esac

run_checks
require_theos

say "THEOS = $THEOS"
say "SDK   = $(ls "$THEOS/sdks" | tail -1)"

if [ "$MODE" = "dylib" ]; then
    say "编译 dylib（不打包）"
    make clean >/dev/null 2>&1
    make FINALPACKAGE=1 || die "make 失败"
else
    say "编译并打包 deb"
    make clean >/dev/null 2>&1
    make package FINALPACKAGE=1 || die "make package 失败"
fi

echo
say "产物"
found=0
for f in packages/*.deb; do
    [ -f "$f" ] || continue
    printf '   %s (%s)\n' "$f" "$(du -h "$f" | cut -f1)"
    found=1
done
for f in .theos/obj/AutoTapper.dylib .theos/obj/*/AutoTapper.dylib; do
    [ -f "$f" ] || continue
    arch=$(command -v file >/dev/null 2>&1 && file -b "$f" | cut -c1-60 || echo "?")
    printf '   %s (%s)\n' "$f" "$arch"
    found=1
done
[ "$found" -eq 1 ] || die "没有找到产物，看上面的 make 输出"

echo
say "装到设备： export THEOS_DEVICE_IP=<手机IP>; make package install FINALPACKAGE=1"
