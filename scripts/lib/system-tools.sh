#!/usr/bin/env bash
# 系统与语言工具链：平台系统包（DNF / Homebrew）、rustup、Cargo、RubyGems。
# 依赖入口脚本声明的共享状态：STEP_DETAIL；调用 step-runner 的 run_with_sudo / skip_step。

# Linux 发行版按包管理器分流；两者都没有时跳过而非失败（与"缺工具即跳过"一致）。
update_linux_packages() {
    if command -v dnf >/dev/null 2>&1; then
        update_dnf
    elif command -v apt-get >/dev/null 2>&1; then
        update_apt
    else
        skip_step '未检测到受支持的系统包管理器（dnf 或 apt-get）'
    fi
}

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

# 固定用 apt-get：apt(8) 自己声明其命令行接口不保证在脚本间稳定，apt-get 才是稳定契约。
update_apt() {
    local apt_bin
    if ! apt_bin="$(command -v apt-get)"; then
        skip_step '未检测到 apt-get'
        return
    fi

    # upgrade 本身不卸载软件包；--no-remove 让"必须卸载才能升级"的情况直接中止，
    # 而不是退化成 dist-upgrade 式的自作主张。等价于 DNF 那侧的 --noautoremove。
    # force-confold 保留本机已改过的配置文件，force-confdef 处理无人值守时的其余分支。
    local -a refresh_args=(update)
    local -a upgrade_args=(
        upgrade --assume-yes --no-remove
        -o Dpkg::Options::=--force-confdef
        -o Dpkg::Options::=--force-confold
    )

    local result=0
    run_apt "$apt_bin" "${refresh_args[@]}" || result=1
    run_apt "$apt_bin" "${upgrade_args[@]}" || result=1
    return "$result"
}

# DEBIAN_FRONTEND 关掉 debconf 交互问答；NEEDRESTART_MODE=l 只列出需重启的服务，
# 不自动重启——与 macOS 侧"不强制退出正在运行的 cask 应用"是同一条边界。
run_apt() {
    local apt_bin="$1"
    shift
    if [[ "$(id -u)" == 0 ]]; then
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l "$apt_bin" "$@"
        return
    fi
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
        run_with_sudo --preserve-env=DEBIAN_FRONTEND,NEEDRESTART_MODE "$apt_bin" "$@"
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
    # 必须走 cargo 的子命令分发。直接执行 cargo-install-update 时，它的顶层解析器
    # 仍要求 install-update 子命令（cargo-update 22.x 实测），`--all` 会被判为未知参数。
    cargo install-update --all
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
