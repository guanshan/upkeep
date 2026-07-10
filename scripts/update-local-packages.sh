#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly LIB_DIR="$SCRIPT_DIR/lib"

# ===== 可选配置：私有 npm 包 =====
PRIVATE_NPM_REGISTRY=''
PRIVATE_NPM_PACKAGES=()
UPKEEP_CONFIG="${UPKEEP_CONFIG:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/upkeep/config.sh}"
if [[ -f "$UPKEEP_CONFIG" ]] && ! source "$UPKEEP_CONFIG"; then
    printf '错误：无法加载配置 %s\n' "$UPKEEP_CONFIG" >&2
    exit 1
fi

# ===== 跨模块共享状态（由 lib/*.sh 读写）=====
declare -a RESULT_LABELS=()
declare -a RESULT_STATES=()
declare -a RESULT_DETAILS=()
declare -a PIPX_RUNNER=()
FAILURE_COUNT=0
STEP_DETAIL=''
STEP_SKIPPED=0
PLATFORM=''
LOCK_PATH=''
LOCK_ACQUIRED=0

for lib_module in step-runner lock node-tools python-tools system-tools; do
    if ! source "$LIB_DIR/$lib_module.sh"; then
        printf '错误：无法加载模块 %s\n' "$LIB_DIR/$lib_module.sh" >&2
        exit 1
    fi
done
unset lib_module

usage() {
    printf '%s\n' \
        '用法：scripts/update-local-packages.sh [--help]' \
        '' \
        '平台更新：' \
        '  - macOS：Homebrew formula 与 cask' \
        '  - Linux：DNF 系统软件包' \
        '' \
        '跨平台更新：' \
        '  - npm、pnpm 与 Bun 全局包（自动补装配置的私有 CLI）' \
        '  - pipx 管理的 Python 命令行工具' \
        '  - uv 及 uv 管理的命令行工具（GitHub API 受限时改用安装脚本更新）' \
        '  - rustup、Cargo（需已装 cargo-update）与 RubyGems 用户工具' \
        '  - macOS 当前 Python 的安全可写包，或 Linux 已激活虚拟环境的顶层包' \
        '' \
        '安全边界：' \
        '  - 不会修改任何子项目依赖或 lockfile' \
        '  - 不会批量更新 Linux 系统 Python；PEP 668 环境自动跳过，不使用 sudo pip' \
        '  - 不会执行 autoremove、Homebrew cleanup 或强制审计修复' \
        '  - 除配置的私有 CLI 与 macOS pipx 外不安装新软件，不隐式编译辅助工具' \
        '  - 单个步骤失败后继续执行，最后统一汇总并返回非零'
}

parse_args() {
    if (($# == 0)); then
        return 0
    fi
    if (($# == 1)) && [[ "$1" == '--help' || "$1" == '-h' ]]; then
        usage
        exit 0
    fi
    printf '错误：未知参数：%s\n' "$*" >&2
    usage >&2
    exit 2
}

detect_platform() {
    local kernel_name
    kernel_name="$(uname -s)" || return 1
    case "$kernel_name" in
        Darwin)
            PLATFORM='macos'
            printf '运行平台：macOS\n'
            ;;
        Linux)
            PLATFORM='linux'
            printf '运行平台：Linux\n'
            ;;
        *)
            printf '错误：暂不支持的操作系统：%s\n' "$kernel_name" >&2
            return 1
            ;;
    esac

    if [[ "${NODE_TLS_REJECT_UNAUTHORIZED:-}" == '0' ]]; then
        printf '警告：检测到 NODE_TLS_REJECT_UNAUTHORIZED=0，已为本次更新恢复 TLS 证书校验。\n' >&2
        unset NODE_TLS_REJECT_UNAUTHORIZED
    fi
}

main() {
    parse_args "$@"
    detect_platform || return 1
    acquire_lock || return 1
    if [[ "$PLATFORM" == 'macos' ]]; then
        run_step 'Homebrew 系统软件包' update_homebrew
    else
        run_step 'DNF 系统软件包' update_dnf
    fi
    run_step 'npm 全局包' update_npm
    run_step 'pnpm 全局包' update_pnpm
    run_step 'Bun 全局包' update_bun
    run_step 'pipx 工具' update_pipx
    run_step 'uv 与 uv 工具' update_uv
    run_step 'Python 包' update_python_packages
    run_step 'rustup 工具链' update_rustup
    run_step 'Cargo 全局包' update_cargo
    run_step 'RubyGems 用户包' update_gems
    print_summary
    ((FAILURE_COUNT == 0))
}

main "$@"
