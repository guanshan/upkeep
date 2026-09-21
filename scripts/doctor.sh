#!/usr/bin/env bash

# 只读体检：核对真实工具的存在性与关键契约，不做任何修改。
# 背景：mock 测试只能验证"代码与自己的假设一致"，验证不了"假设与真实工具一致"
# （2026-07-10 评审曾因此漏掉 RubyGems 3.0 不支持 gem env user_gemhome）。

set -uo pipefail

DOCTOR_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# 只复用站点配置模块：doctor 不需要步骤编排与并发锁，但配置的查找顺序必须与
# make update 完全一致，否则两边迟早漂移。
# shellcheck source=scripts/lib/site-config.sh
if ! source "$DOCTOR_DIR/lib/site-config.sh"; then
    printf '错误：无法加载模块 %s\n' "$DOCTOR_DIR/lib/site-config.sh" >&2
    exit 1
fi

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

check_site_config() {
    section '站点配置'
    if ! load_site_config; then
        warn '站点配置加载失败：make update 会在同一处退出'
        return
    fi
    if [[ -z "$SITE_CONFIG_PATH" ]]; then
        note '未加载站点配置（不处理任何私有包）'
        return
    fi
    note "配置来源：$SITE_CONFIG_PATH"
    note "私有 registry：${PRIVATE_NPM_REGISTRY:-未设置（用 npm 默认 registry）}"
    if ((${#PRIVATE_NPM_SCOPES[@]} > 0)); then
        note "私有 scope：${PRIVATE_NPM_SCOPES[*]}"
    fi
    if ((${#PRIVATE_NPM_PACKAGES[@]} > 0)); then
        local package_spec
        for package_spec in "${PRIVATE_NPM_PACKAGES[@]}"; do
            note "必备私有 CLI：${package_spec%%|*}"
        done
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

# 独立成函数而不是在 if 里内联 heredoc：后者不同 shfmt 版本的排版要求互相矛盾，
# 而且可读性差。
python_has_pep668_marker() {
    python3 - <<'PY'
import os, sys, sysconfig
marker = os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED")
raise SystemExit(0 if sys.prefix == sys.base_prefix and os.path.exists(marker) else 1)
PY
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
    if python_has_pep668_marker; then
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
            # 与 update_linux_packages 的分流顺序保持一致：dnf 优先，其次 apt-get。
            if command -v dnf >/dev/null 2>&1; then
                note "dnf：$(tool_version dnf --version)"
            elif command -v apt-get >/dev/null 2>&1; then
                note "apt-get：$(tool_version apt-get --version)"
                if command -v needrestart >/dev/null 2>&1; then
                    note 'needrestart 已装：更新时设为只列出，不自动重启服务'
                fi
            else
                warn '未检测到 dnf 或 apt-get（Linux 系统包步骤会跳过）'
            fi
            if [[ "$(id -u)" != 0 ]] && ! command -v sudo >/dev/null 2>&1; then
                warn '非 root 且没有 sudo：系统包步骤会失败'
            fi
            ;;
    esac
}

check_docker() {
    section 'Docker'
    if ! command -v docker >/dev/null 2>&1; then
        note '未安装 docker（make clean-docker 会报错退出）'
        return
    fi
    if docker system df >/dev/null 2>&1; then
        note "docker：$(tool_version docker --version)（daemon 可访问）"
    else
        warn 'docker 已装但 daemon 不可访问：make clean-docker 会失败'
    fi
}

main() {
    printf 'upkeep doctor（只读，不修改任何状态）\n'
    check_platform
    check_lock
    check_system_manager
    check_site_config
    check_node_managers
    check_python
    check_rust_ruby
    check_docker
    printf '\n结论：%d 项警告\n' "$WARN_COUNT"
    ((WARN_COUNT == 0))
}

main "$@"
