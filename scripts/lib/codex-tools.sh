#!/usr/bin/env bash
# 独立安装不随 fnm 的 Node 版本切换；npm 安装仍由 npm 步骤负责。

resolve_native_codex() {
    local launcher="${HOME:-}/.local/bin/codex"
    [[ -n "${HOME:-}" && -x "$launcher" ]] || return 1
    printf '%s\n' "$launcher"
}

update_codex() {
    local codex_bin before after active
    if ! codex_bin="$(resolve_native_codex)"; then
        skip_step '未检测到 ~/.local/bin/codex；其他安装由对应包管理器更新'
        return
    fi
    before="$("$codex_bin" --version)" || return 1
    "$codex_bin" update || return 1
    after="$("$codex_bin" --version)" || return 1
    STEP_DETAIL="$before → $after"

    hash -r
    active="$(command -v codex 2>/dev/null)" || active=''
    if [[ -z "$active" || ! "$active" -ef "$codex_bin" ]]; then
        STEP_DETAIL+="；PATH 未使用独立安装（当前：${active:-未找到}），请移除重复安装或将 ~/.local/bin 加入 PATH"
        return 1
    fi
}
