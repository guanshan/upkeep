#!/usr/bin/env bash
# 站点配置：私有 npm registry、scope 与必备 CLI。
# 由 update-local-packages.sh 与 doctor.sh 共用，保证两边的查找顺序不会漂移。
#
# 对外提供：PRIVATE_NPM_REGISTRY / PRIVATE_NPM_SCOPES / PRIVATE_NPM_PACKAGES /
# SITE_CONFIG_PATH（实际加载的路径，未加载任何配置时为空），以及 load_site_config。

# 默认值等价于「没有私有包」，纯公网环境无需任何配置。
PRIVATE_NPM_REGISTRY=''
declare -a PRIVATE_NPM_SCOPES=()
declare -a PRIVATE_NPM_PACKAGES=()
SITE_CONFIG_PATH=''

SITE_CONFIG_REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SITE_CONFIG_REPO_DIR

# 查找顺序：
#   1. $UPKEEP_CONFIG —— 显式指定。设为空串表示「本次不加载任何站点配置」；
#      指向不存在的文件则报错退出，避免配置写错却被静默忽略。
#   2. 用户级 $XDG_CONFIG_HOME/upkeep/config.sh（默认 ~/.config/upkeep/config.sh）。
#   3. 仓库内 config.sh —— 需要随仓库分发默认配置的部署把它提交进去，clone 下来即可用；
#      公开仓库不提交，只提供 config.example.sh 供复制。
resolve_site_config() {
    if [[ -n "${UPKEEP_CONFIG+set}" ]]; then
        printf '%s\n' "$UPKEEP_CONFIG"
        return 0
    fi
    local user_config="${XDG_CONFIG_HOME:-${HOME:-}/.config}/upkeep/config.sh"
    if [[ -f "$user_config" ]]; then
        printf '%s\n' "$user_config"
        return 0
    fi
    [[ -f "$SITE_CONFIG_REPO_DIR/config.sh" ]] && printf '%s\n' "$SITE_CONFIG_REPO_DIR/config.sh"
    return 0
}

load_site_config() {
    local config_path
    config_path="$(resolve_site_config)"
    [[ -n "$config_path" ]] || return 0

    # 只有经 UPKEEP_CONFIG 显式指定才可能走到这里：自动发现的路径都已确认存在。
    if [[ ! -f "$config_path" ]]; then
        printf '错误：UPKEEP_CONFIG 指向的配置不存在：%s\n' "$config_path" >&2
        return 1
    fi
    # shellcheck disable=SC1090 # 配置路径由运行时决定，无法静态跟随
    if ! source "$config_path"; then
        printf '错误：无法加载站点配置：%s\n' "$config_path" >&2
        return 1
    fi
    SITE_CONFIG_PATH="$config_path"
    validate_site_config
}

# 配置是被 source 的 Bash 片段，等同于可信代码；这里的校验用于及早发现笔误，
# 而不是防御恶意输入——真要防御，source 本身就已经交出了控制权。
validate_site_config() {
    if [[ -n "$PRIVATE_NPM_REGISTRY" ]] &&
        [[ "$PRIVATE_NPM_REGISTRY" != http://* && "$PRIVATE_NPM_REGISTRY" != https://* ]]; then
        printf '错误：PRIVATE_NPM_REGISTRY 必须是 http(s) 地址：%s\n' "$PRIVATE_NPM_REGISTRY" >&2
        return 1
    fi

    local scope package_spec package_name
    for scope in ${PRIVATE_NPM_SCOPES[@]+"${PRIVATE_NPM_SCOPES[@]}"}; do
        if [[ "$scope" != @* || "$scope" == */* ]]; then
            printf '错误：PRIVATE_NPM_SCOPES 每项应形如 @scope：%s\n' "$scope" >&2
            return 1
        fi
    done
    for package_spec in ${PRIVATE_NPM_PACKAGES[@]+"${PRIVATE_NPM_PACKAGES[@]}"}; do
        package_name="${package_spec%%|*}"
        if [[ ! "$package_name" =~ ^(@[A-Za-z0-9._-]+/)?[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            printf '错误：PRIVATE_NPM_PACKAGES 包名无效：%s\n' "$package_spec" >&2
            return 1
        fi
    done
}
