#!/usr/bin/env bash
# 系统与语言工具链：平台系统包（DNF / Homebrew）、rustup、Cargo、RubyGems。
# 依赖入口脚本声明的共享状态：STEP_DETAIL；调用 step-runner 的 run_with_sudo / skip_step。

update_dnf() {
    local dnf_bin
    if ! dnf_bin="$(command -v dnf)"; then
        skip_step '未检测到 dnf'
        return
    fi

    local -a args=(upgrade --refresh --assumeyes --noautoremove)
    if [[ "$(id -u)" == 0 ]]; then
        "$dnf_bin" "${args[@]}"
        return
    fi
    run_with_sudo "$dnf_bin" "${args[@]}"
}

update_homebrew() {
    if ! command -v brew >/dev/null 2>&1; then
        skip_step '未检测到 Homebrew'
        return
    fi

    local result=0
    HOMEBREW_NO_INSTALL_CLEANUP=1 brew update || result=1
    HOMEBREW_NO_INSTALL_CLEANUP=1 brew upgrade --formula --no-ask || result=1
    HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 \
        brew upgrade --cask --no-ask || result=1
    return "$result"
}

update_rustup() {
    if ! command -v rustup >/dev/null 2>&1; then
        skip_step '未检测到 rustup'
        return
    fi
    rustup update
}

update_cargo() {
    if ! command -v cargo >/dev/null 2>&1; then
        skip_step '未检测到 Cargo'
        return
    fi

    local installed
    installed="$(cargo install --list)" || return 1
    if [[ -z "${installed//[[:space:]]/}" ]]; then
        STEP_DETAIL='没有 Cargo 全局包'
        return 0
    fi
    # 更新脚本不做分钟级的隐式编译安装；缺 helper 时提示后跳过
    if ! command -v cargo-install-update >/dev/null 2>&1; then
        skip_step '未安装 cargo-update（可手动执行 cargo install cargo-update 后重试）'
        return
    fi
    cargo-install-update --all
}

resolve_gem_bin() {
    local ruby_prefix candidate
    if command -v brew >/dev/null 2>&1 && ruby_prefix="$(brew --prefix ruby 2>/dev/null)"; then
        candidate="$ruby_prefix/bin/gem"
        if [[ "$candidate" == /* && -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi
    command -v gem 2>/dev/null
}

ensure_writable_user_directory() {
    local path="$1"
    local label="$2"
    local parent
    if [[ -z "$path" || "$path" != /* ]]; then
        STEP_DETAIL="无法确认有效的 $label 安装目录"
        return 1
    fi
    if [[ -e "$path" && ! -d "$path" ]]; then
        STEP_DETAIL="$label 安装路径不是目录：$path"
        return 1
    fi
    if [[ ! -d "$path" ]]; then
        parent="$path"
        while [[ ! -e "$parent" ]]; do
            parent="${parent%/*}"
            [[ -n "$parent" ]] || parent='/'
        done
        if [[ ! -d "$parent" || ! -w "$parent" ]]; then
            STEP_DETAIL="$label 安装目录的父目录不可写：$parent"
            return 1
        fi
        mkdir -p -- "$path" || return 1
    fi
    if [[ ! -w "$path" ]]; then
        STEP_DETAIL="$label 安装目录不可写：$path"
        return 1
    fi
}

# gem env user_gemhome 需 RubyGems ≥3.2（macOS 系统 ruby 是 3.0 会报错）；Gem.user_dir 各版本通用
resolve_gem_user_dir() {
    local gem_bin="$1"
    local ruby_bin="${gem_bin%/*}/ruby"
    if [[ ! -x "$ruby_bin" ]]; then
        ruby_bin="$(command -v ruby 2>/dev/null)" || return 1
    fi
    "$ruby_bin" -rrubygems -e 'print Gem.user_dir' 2>/dev/null
}

update_gems() {
    local gem_bin gem_user_home outdated
    if ! gem_bin="$(resolve_gem_bin)"; then
        skip_step '未检测到 RubyGems'
        return
    fi
    if ! gem_user_home="$(resolve_gem_user_dir "$gem_bin")" || [[ -z "$gem_user_home" ]]; then
        skip_step '无法确定 RubyGems 用户目录（缺少可用的 ruby），已跳过'
        return
    fi
    ensure_writable_user_directory "$gem_user_home" 'RubyGems' || return 1
    outdated="$(GEM_HOME="$gem_user_home" GEM_PATH="$gem_user_home" "$gem_bin" outdated)" || return 1
    if [[ -z "${outdated//[[:space:]]/}" ]]; then
        STEP_DETAIL='没有过期的用户 gem'
        return 0
    fi
    GEM_HOME="$gem_user_home" GEM_PATH="$gem_user_home" \
        "$gem_bin" update --user-install --no-document
}
