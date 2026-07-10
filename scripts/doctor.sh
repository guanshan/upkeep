#!/usr/bin/env bash

# 只读体检：核对真实工具的存在性与关键契约，不做任何修改。
# 背景：mock 测试只能验证"代码与自己的假设一致"，验证不了"假设与真实工具一致"
# （2026-07-10 评审曾因此漏掉 RubyGems 3.0 不支持 gem env user_gemhome）。

set -uo pipefail

WARN_COUNT=0

note() {
    printf '  OK   %s\n' "$1"
}

warn() {
    printf '  WARN %s\n' "$1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

section() {
    printf '\n== %s ==\n' "$1"
}

tool_version() {
    "$@" 2>/dev/null | head -n 1
}

# 逐级跟随符号链接到最终目标。BSD/macOS readlink 不支持 -f，故手动解析；
# 用纯 bash 取目录（${path%/*}），不依赖外部 dirname，兼容 bash 3.2。
resolve_symlink_chain() {
    local path="$1" target hops=0
    while [[ -L "$path" ]] && ((hops++ < 40)); do
        target="$(readlink "$path" 2>/dev/null)" || break
        [[ -n "$target" ]] || break
        if [[ "$target" == /* ]]; then
            path="$target"
        else
            path="${path%/*}/$target"
        fi
    done
    printf '%s\n' "$path"
}

check_platform() {
    section '平台'
    local kernel_name
    kernel_name="$(uname -s)"
    case "$kernel_name" in
        Darwin | Linux) note "操作系统：$kernel_name" ;;
        *) warn "未支持的操作系统：$kernel_name（make update 会拒绝运行）" ;;
    esac
    note "bash：$BASH_VERSION"
}

check_lock() {
    section '并发锁'
    if command -v flock >/dev/null 2>&1; then
        note 'flock 可用：使用内核锁，进程退出自动释放'
    else
        note '无 flock：使用 mkdir 目录锁（带 PID 陈锁自愈）'
    fi
    local lock_dir=''
    if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
        lock_dir="$XDG_RUNTIME_DIR"
    elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
        lock_dir="$XDG_STATE_HOME/upkeep"
    elif [[ -n "${HOME:-}" ]]; then
        lock_dir="$HOME/.local/state/upkeep"
    fi
    local lock_path="$lock_dir/upkeep-${UID}.lock"
    if [[ -n "$lock_dir" && -e "$lock_path" ]]; then
        warn "存在锁残留：$lock_path（若确认无更新进程可手动删除）"
    else
        note "锁路径：${lock_path:-未知}（当前无残留）"
    fi
}

check_node_managers() {
    section 'Node 包管理器'
    if command -v npm >/dev/null 2>&1; then
        note "npm：$(tool_version npm --version)（registry：$(npm config get registry 2>/dev/null)）"
    else
        warn '未检测到 npm（npm 全局包与配置的私有 CLI 无法更新）'
    fi

    if command -v pnpm >/dev/null 2>&1; then
        local pnpm_path real_path
        pnpm_path="$(command -v pnpm)"
        real_path="$(resolve_symlink_chain "$pnpm_path")"
        if [[ "$real_path" == *corepack* ]]; then
            if COREPACK_ENABLE_NETWORK=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm --version >/dev/null 2>&1; then
                note "pnpm：corepack shim（已激活缓存，版本 $(COREPACK_ENABLE_NETWORK=0 tool_version pnpm --version)）"
            else
                warn 'pnpm 是未激活的 corepack shim：make update 会跳过该步骤'
            fi
        else
            note "pnpm：$(tool_version pnpm --version)"
        fi
    else
        note '未安装 pnpm（步骤会跳过）'
    fi

    if command -v bun >/dev/null 2>&1; then
        note "bun：$(tool_version bun --version)"
    else
        note '未安装 Bun（步骤会跳过）'
    fi
}

check_python() {
    section 'Python'
    if ! command -v python3 >/dev/null 2>&1; then
        warn '未检测到 python3'
        return
    fi
    note "python3：$(tool_version python3 --version)"
    if python3 -m pip --version >/dev/null 2>&1; then
        note "pip：$(tool_version python3 -m pip --version)"
    else
        note '当前 python3 未安装 pip（Python 包步骤会跳过）'
    fi
    if python3 - <<'PY'
import os, sys, sysconfig
marker = os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED")
raise SystemExit(0 if sys.prefix == sys.base_prefix and os.path.exists(marker) else 1)
PY
    then
        note 'PEP 668：受保护环境（make update 会跳过全局 pip 更新）'
    else
        note 'PEP 668：未启用'
    fi
    if [[ -n "${VIRTUAL_ENV:-}" ]]; then
        note "已激活虚拟环境：$VIRTUAL_ENV"
    fi
    if command -v pipx >/dev/null 2>&1; then
        note "pipx：$(tool_version pipx --version)"
    else
        note '未安装 pipx'
    fi
    if command -v uv >/dev/null 2>&1; then
        if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/uv/uv-receipt.json" ]]; then
            note "uv：$(tool_version uv --version)（standalone 安装，self update 可用）"
        else
            note "uv：$(tool_version uv --version)（外部包管理器安装，自更新由系统包步骤负责）"
        fi
    else
        note '未安装 uv'
    fi
}

check_rust_ruby() {
    section 'Rust / Ruby'
    if command -v rustup >/dev/null 2>&1; then
        note "rustup：$(tool_version rustup --version)"
    else
        note '未安装 rustup（步骤会跳过）'
    fi
    if command -v cargo >/dev/null 2>&1; then
        if command -v cargo-install-update >/dev/null 2>&1; then
            note "cargo：$(tool_version cargo --version)（cargo-update 已就绪）"
        else
            warn 'cargo 已装但缺 cargo-update：Cargo 步骤会跳过（cargo install cargo-update 可启用）'
        fi
    else
        note '未安装 Cargo（步骤会跳过）'
    fi
    local gem_bin ruby_bin
    if gem_bin="$(command -v gem 2>/dev/null)"; then
        note "gem：RubyGems $(tool_version "$gem_bin" --version)"
        ruby_bin="${gem_bin%/*}/ruby"
        [[ -x "$ruby_bin" ]] || ruby_bin="$(command -v ruby 2>/dev/null || true)"
        if [[ -n "$ruby_bin" ]]; then
            local user_dir
            user_dir="$("$ruby_bin" -rrubygems -e 'print Gem.user_dir' 2>/dev/null || true)"
            if [[ -n "$user_dir" ]]; then
                note "RubyGems 用户目录：$user_dir"
            else
                warn '无法通过 ruby 解析 Gem.user_dir：RubyGems 步骤会跳过'
            fi
        else
            warn 'gem 存在但找不到配套 ruby：RubyGems 步骤会跳过'
        fi
    else
        note '未安装 RubyGems（步骤会跳过）'
    fi
}

check_system_manager() {
    section '系统包管理器'
    case "$(uname -s)" in
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                note "Homebrew：$(tool_version brew --version)"
            else
                warn '未检测到 Homebrew（macOS 系统包步骤会跳过）'
            fi
            ;;
        Linux)
            if command -v dnf >/dev/null 2>&1; then
                note "dnf：$(tool_version dnf --version)"
            else
                warn '未检测到 dnf（Linux 系统包步骤会跳过）'
            fi
            ;;
    esac
}

main() {
    printf 'upkeep doctor（只读，不修改任何状态）\n'
    check_platform
    check_lock
    check_system_manager
    check_node_managers
    check_python
    check_rust_ruby
    printf '\n结论：%d 项警告\n' "$WARN_COUNT"
    ((WARN_COUNT == 0))
}

main "$@"
