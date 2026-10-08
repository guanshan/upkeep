#!/usr/bin/env bash
# 独立安装不随 fnm 的 Node 版本切换；npm 安装仍由 npm 步骤负责。

resolve_native_codex() {
    local launcher="${HOME:-}/.local/bin/codex"
    [[ -n "${HOME:-}" && -x "$launcher" ]] || return 1
    printf '%s\n' "$launcher"
}

update_codex() {
    local codex_bin before after active update_output update_status
    if ! codex_bin="$(resolve_native_codex)"; then
        skip_step '未检测到 ~/.local/bin/codex；其他安装由对应包管理器更新'
        return
    fi
    before="$("$codex_bin" --version)" || {
        STEP_DETAIL='无法读取 Codex CLI 更新前版本'
        return 1
    }
    update_output="$("$codex_bin" update 2>&1)"
    update_status=$?
    [[ -z "$update_output" ]] || printf '%s\n' "$update_output"
    if ((update_status != 0)); then
        # 旧独立安装布局可能不被 CLI 的安装方式检测识别；其他错误保持失败。
        if [[ "$update_output" == *'Could not detect the Codex installation method.'* ]]; then
            reinstall_codex_via_installer "$codex_bin" || return 1
        else
            STEP_DETAIL="codex update 失败（退出状态：$update_status）：${update_output%%$'\n'*}"
            return "$update_status"
        fi
    fi
    after="$("$codex_bin" --version)" || {
        STEP_DETAIL='无法读取 Codex CLI 更新后版本'
        return 1
    }
    STEP_DETAIL="$before → $after${STEP_DETAIL:+；$STEP_DETAIL}"

    hash -r
    active="$(command -v codex 2>/dev/null)" || active=''
    if [[ -z "$active" || ! "$active" -ef "$codex_bin" ]]; then
        STEP_DETAIL+="；PATH 未使用独立安装（当前：${active:-未找到}），请移除重复安装或将 ~/.local/bin 加入 PATH"
        return 1
    fi
}

reinstall_codex_via_installer() {
    local codex_bin="$1" installer
    if ! command -v curl >/dev/null 2>&1; then
        STEP_DETAIL='Codex CLI 无法识别安装方式，且缺少 curl，无法使用官方安装脚本更新'
        return 1
    fi
    printf '==> Codex CLI 无法识别安装方式，改用官方安装脚本更新\n'
    # 下载完整脚本后才执行，避免 curl 失败时执行部分下载内容。
    if ! installer="$(curl -fsSL --connect-timeout 10 --max-time 60 https://chatgpt.com/codex/install.sh)" || [[ -z "$installer" ]]; then
        STEP_DETAIL='Codex CLI 无法识别安装方式，且官方安装脚本下载失败'
        return 1
    fi
    # 固定原入口，并将它放到子进程 PATH 首位，防止安装器修改 shell 配置。
    # 非交互模式不启动 Codex，也不卸载其他包管理器的副本。
    if ! printf '%s\n' "$installer" | PATH="${codex_bin%/*}:$PATH" \
        CODEX_INSTALL_DIR="${codex_bin%/*}" CODEX_NON_INTERACTIVE=1 sh -s -- --release latest; then
        STEP_DETAIL='Codex CLI 无法识别安装方式，且官方安装脚本更新失败'
        return 1
    fi
    STEP_DETAIL='安装方式识别失败，已通过官方安装脚本更新'
}
