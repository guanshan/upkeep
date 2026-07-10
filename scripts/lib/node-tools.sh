#!/usr/bin/env bash
# Node 生态全局包：npm（含已配置私有 CLI 补装）、pnpm、Bun。
# 依赖入口脚本声明的 PRIVATE_NPM_REGISTRY / PRIVATE_NPM_PACKAGES。

update_npm() {
    if ! command -v npm >/dev/null 2>&1; then
        skip_step '未检测到 npm'
        return
    fi

    # npm ls 在 extraneous/invalid 树上非零退出但 stdout 仍可用；枚举失败也不阻塞私有包补装
    local package_lines enumeration_ok=1 result=0
    if ! package_lines="$(list_npm_global_packages)"; then
        enumeration_ok=0
    fi
    if ((enumeration_ok == 0)) && [[ -z "$package_lines" ]]; then
        STEP_DETAIL='无法枚举 npm 全局包，仍会处理已配置的私有包'
        result=1
    fi
    local -a regular_packages=()
    local package_name
    while IFS= read -r package_name; do
        [[ -n "$package_name" ]] || continue
        if ! is_private_npm_package "$package_name"; then
            regular_packages+=("$package_name")
        fi
    done <<<"$package_lines"

    if ((${#regular_packages[@]} > 0)); then
        npm update --global --no-audit --no-fund "${regular_packages[@]}" || result=1
    fi
    if ((${#PRIVATE_NPM_PACKAGES[@]} > 0)); then
        local package_spec
        for package_spec in "${PRIVATE_NPM_PACKAGES[@]}"; do
            update_private_npm_package "$package_spec" || result=1
        done
    fi
    return "$result"
}

update_pnpm() {
    if ! command -v pnpm >/dev/null 2>&1; then
        skip_step '未检测到 pnpm'
        return
    fi

    # command -v 可能命中未激活的 corepack shim：禁网禁提示探测，失败即跳过，避免卡在交互式下载
    local global_root
    if ! global_root="$(COREPACK_ENABLE_NETWORK=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm root --global 2>/dev/null)" \
        || [[ -z "$global_root" ]]; then
        skip_step 'pnpm 不可用（可能是未激活的 corepack shim），已跳过'
        return
    fi
    if [[ ! -f "${global_root%/node_modules}/package.json" ]]; then
        skip_step '没有 pnpm 全局包'
        return
    fi
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm update --global --latest
}

update_bun() {
    if ! command -v bun >/dev/null 2>&1; then
        skip_step '未检测到 Bun'
        return
    fi

    local list_output list_status
    list_output="$(bun pm ls --global 2>&1)"
    list_status=$?
    if ((list_status != 0)); then
        if [[ "$list_output" == *'No package.json was found'* ]]; then
            STEP_DETAIL='没有 Bun 全局包'
            return 0
        fi
        printf '%s\n' "$list_output" >&2
        return "$list_status"
    fi
    if [[ -z "${list_output//[[:space:]]/}" ]]; then
        STEP_DETAIL='没有 Bun 全局包'
        return 0
    fi
    bun update --global --latest
}

list_npm_global_packages() {
    npm ls --global --depth=0 --parseable 2>/dev/null |
        awk -F'/node_modules/' 'NF >= 2 { print $NF }'
}

is_private_npm_package() {
    local package_name="$1" package_spec private_name
    ((${#PRIVATE_NPM_PACKAGES[@]} > 0)) || return 1
    for package_spec in "${PRIVATE_NPM_PACKAGES[@]}"; do
        private_name="${package_spec%%|*}"
        [[ "$package_name" == "$private_name" ]] && return 0
    done
    return 1
}

update_private_npm_package() {
    local package_spec="$1" package_name extra_flags=''
    package_name="${package_spec%%|*}"
    if [[ "$package_spec" == *'|'* ]]; then
        extra_flags="${package_spec#*|}"
    fi
    if [[ -z "$package_name" ]]; then
        printf '错误：私有 npm 包配置缺少包名：%s\n' "$package_spec" >&2
        return 1
    fi

    local -a install_args=(install --global --no-audit --no-fund)
    if [[ -n "$extra_flags" ]]; then
        local -a extra_args=()
        read -r -a extra_args <<<"$extra_flags"
        if ((${#extra_args[@]} > 0)); then
            install_args+=("${extra_args[@]}")
        fi
    fi
    install_args+=("$package_name")
    if [[ -n "$PRIVATE_NPM_REGISTRY" ]]; then
        install_args+=("--registry=$PRIVATE_NPM_REGISTRY")
    fi
    npm "${install_args[@]}"
}
