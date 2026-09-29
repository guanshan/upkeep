#!/usr/bin/env bash
# 原生安装独立于 Node 版本；npm 等安装仍由各自包管理器负责。

resolve_native_claude() {
    local launcher="${HOME:-}/.local/bin/claude"
    [[ -n "${HOME:-}" && -x "$launcher" ]] || return 1
    printf '%s\n' "$launcher"
}

update_claude() {
    local claude_bin before after active
    if ! claude_bin="$(resolve_native_claude)"; then
        skip_step '未检测到 ~/.local/bin/claude；其他安装由对应包管理器更新'
        return
    fi
    before="$("$claude_bin" --version)" || return 1
    "$claude_bin" update || return 1
    after="$("$claude_bin" --version)" || return 1
    STEP_DETAIL="$before → $after"

    # 更新成功也可能仍在运行 fnm 等目录里的另一份旧版本，不能静默报完成。
    hash -r
    active="$(command -v claude 2>/dev/null)" || active=''
    if [[ -z "$active" || ! "$active" -ef "$claude_bin" ]]; then
        STEP_DETAIL+="；PATH 未使用原生安装（当前：${active:-未找到}），请移除重复安装或将 ~/.local/bin 加入 PATH"
        return 1
    fi
}
