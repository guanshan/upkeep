#!/usr/bin/env bash
# Python 生态：pip 环境探测（python_query）、pipx、uv、venv 与 macOS 全局 Python。
# 依赖入口脚本声明的共享状态：PIPX_RUNNER / PLATFORM / STEP_DETAIL / STEP_SKIPPED。

python_query() {
    local action="$1"
    local python_bin
    python_bin="$(command -v python3)" || return 1
    if [[ "$action" == 'pip-outdated' ]]; then
        python_query_pip_outdated "$python_bin"
    else
        python_query_environment "$python_bin" "$action"
    fi
}

python_query_pip_outdated() {
    local python_bin="$1"
    "$python_bin" - pip-outdated <<'PY'
import json
import re
import subprocess
import sys

result = subprocess.run(
    [sys.executable, "-m", "pip", "list", "--outdated", "--format=json", "--exclude-editable"],
    capture_output=True,
    text=True,
)
if result.stderr:
    sys.stderr.write(result.stderr)
if result.returncode != 0:
    raise SystemExit(result.returncode)
for package in json.loads(result.stdout):
    name = package.get("name", "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
        raise SystemExit(f"pip 返回了无效包名：{name!r}")
    print(name)
PY
}

python_query_environment() {
    local python_bin="$1" action="$2"
    "$python_bin" - "$action" <<'PY'
import os
import site
import sys
import sysconfig

action = sys.argv[1]
if action == "externally-managed":
    marker = os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED")
    raise SystemExit(0 if sys.prefix == sys.base_prefix and os.path.exists(marker) else 1)
elif action == "purelib-path":
    purelib = sysconfig.get_path("purelib")
    if purelib:
        print(purelib)
elif action == "user-site-path":
    user_site = site.getusersitepackages()
    if isinstance(user_site, str) and os.path.isabs(user_site) and site.ENABLE_USER_SITE is not False:
        candidate = user_site
        while not os.path.exists(candidate):
            parent = os.path.dirname(candidate)
            if parent == candidate:
                candidate = ""
                break
            candidate = parent
        if candidate and os.access(candidate, os.W_OK):
            print(user_site)
elif action == "in-virtualenv":
    raise SystemExit(0 if sys.prefix != sys.base_prefix else 1)
else:
    raise SystemExit(f"未知 Python 查询动作：{action}")
PY
}

ensure_pipx() {
    local python_bin
    if command -v pipx >/dev/null 2>&1; then
        PIPX_RUNNER=("$(command -v pipx)")
        return 0
    fi
    if [[ "$PLATFORM" == 'linux' ]]; then
        skip_step '未检测到 pipx'
        return 0
    fi

    if command -v brew >/dev/null 2>&1; then
        HOMEBREW_NO_INSTALL_CLEANUP=1 brew install pipx || return 1
        hash -r
    elif command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
        # 无法安全安装属于环境属性：跳过而非失败，与 PEP 668 的整体处理一致
        if python_query in-virtualenv; then
            skip_step '当前 python3 位于虚拟环境，不通过 pip --user 安装 pipx，已跳过'
            return 0
        fi
        if python_query externally-managed; then
            skip_step 'PEP 668 保护当前 Python，无法安全安装 pipx，已跳过'
            return 0
        fi
        python_bin="$(command -v python3)"
        "$python_bin" -m pip install --user pipx || return 1
    else
        skip_step '未检测到 pipx，且没有安全的安装方式'
        return 0
    fi

    if command -v pipx >/dev/null 2>&1; then
        PIPX_RUNNER=("$(command -v pipx)")
    elif command -v python3 >/dev/null 2>&1 && python3 -m pipx --version >/dev/null 2>&1; then
        PIPX_RUNNER=("$(command -v python3)" '-m' 'pipx')
    else
        STEP_DETAIL='pipx 安装后仍无法执行，脚本不会自动修改 shell 配置'
        return 1
    fi
}

update_pipx() {
    ensure_pipx || return 1
    if ((STEP_SKIPPED == 1)); then
        return 0
    fi
    "${PIPX_RUNNER[@]}" upgrade-all --include-injected
}

uv_is_homebrew_managed() {
    [[ "$PLATFORM" == 'macos' ]] || return 1
    command -v brew >/dev/null 2>&1 || return 1

    local uv_bin brew_uv_prefix brew_uv_bin
    uv_bin="$(command -v uv)" || return 1
    brew_uv_prefix="$(brew --prefix uv 2>/dev/null)" || return 1
    brew_uv_bin="$brew_uv_prefix/bin/uv"
    [[ -x "$brew_uv_bin" && "$uv_bin" -ef "$brew_uv_bin" ]]
}

update_uv() {
    if ! command -v uv >/dev/null 2>&1; then
        skip_step '未检测到 uv'
        return
    fi

    local result=0
    local self_output self_status
    if uv_is_homebrew_managed; then
        STEP_DETAIL='uv 由 Homebrew 管理，自更新由 Homebrew 步骤负责'
    else
        self_output="$(UV_NO_MODIFY_PATH=1 uv self update 2>&1)"
        self_status=$?
        if ((self_status == 0)); then
            [[ -z "$self_output" ]] || printf '%s\n' "$self_output"
        else
            if [[ "$self_output" == *'uv was installed through an external package manager and cannot update itself.'* ]]; then
                STEP_DETAIL='uv 由外部包管理器管理，已跳过自更新'
            elif [[ "$self_output" == *'Self-update is only available for uv binaries installed via the standalone installation scripts.'* ]]; then
                STEP_DETAIL='uv 不是独立安装版本，已跳过自更新'
            elif [[ "$self_output" == *'was not found for the app uv'* ]]; then
                # 本机出口 IP 的 GitHub 匿名 API 限额经常打满，axoupdater 枚举 release 失败时报这句。
                reinstall_uv_via_installer "$self_output" || result=1
            else
                printf '%s\n' "$self_output" >&2
                result=1
            fi
        fi
    fi
    if ! uv tool upgrade --all; then
        result=1
    fi
    return "$result"
}

# GitHub API 受限时 axoupdater 无法枚举 release，但 release 直链下载可用；
# 报错信息里带最新版本号，已是最新则跳过，否则用安装脚本直链重装（等价于自更新）。
reinstall_uv_via_installer() {
    local self_output="$1"
    local current_version target_version
    current_version="$(uv --version 2>/dev/null | awk '{print $2}')"
    target_version="$(printf '%s' "$self_output" |
        sed -n 's/.*The version \([0-9][^ ]*\) was not found for the app uv.*/\1/p')"
    if [[ -n "$target_version" && "$target_version" == "$current_version" ]]; then
        STEP_DETAIL="uv 已是最新版 ${current_version}（GitHub API 受限，无需重装）"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        STEP_DETAIL='GitHub API 受限且缺少 curl，无法自动重装 uv'
        return 1
    fi
    printf '==> GitHub API 受限，改用安装脚本重装 uv\n'
    if ! curl -LsSf https://astral.sh/uv/install.sh | UV_NO_MODIFY_PATH=1 sh; then
        STEP_DETAIL='GitHub API 受限，且安装脚本重装 uv 失败'
        return 1
    fi
    STEP_DETAIL='GitHub API 受限，已改用安装脚本更新 uv'
}

validate_venv() {
    local python_bin="$1"
    if [[ ! -x "$python_bin" ]]; then
        STEP_DETAIL="虚拟环境解释器不可执行：$python_bin"
        return 1
    fi
    if ! "$python_bin" -c 'import os, sys; raise SystemExit(0 if sys.prefix != sys.base_prefix and os.path.realpath(sys.prefix) == os.path.realpath(os.environ["VIRTUAL_ENV"]) else 1)'; then
        STEP_DETAIL="VIRTUAL_ENV 不是有效的虚拟环境：${VIRTUAL_ENV:-}"
        return 1
    fi
}

parse_package_names() {
    local python_bin="$1"
    "$python_bin" -c 'import json, sys; [print(p["name"]) for p in json.load(sys.stdin) if not p.get("editable_project_location")]'
}

update_macos_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_step '未检测到 python3'
        return
    fi

    local python_bin outdated package pip_target user_target
    local -a packages=()
    python_bin="$(command -v python3)"
    if ! "$python_bin" -m pip --version >/dev/null 2>&1; then
        skip_step '当前 python3 未安装 pip'
        return
    fi
    # PEP 668 是环境属性而非故障：跳过并说明，绝不 --break-system-packages
    if python_query externally-managed; then
        skip_step 'PEP 668 保护当前 Python 环境，已跳过全局 pip 更新'
        return
    fi
    outdated="$(python_query pip-outdated)" || return 1
    while IFS= read -r package; do
        [[ -n "$package" ]] && packages+=("$package")
    done <<<"$outdated"
    if ((${#packages[@]} == 0)); then
        STEP_DETAIL='没有过期的 Python 包'
        return 0
    fi

    pip_target="$(python_query purelib-path)" || return 1
    if [[ -n "$pip_target" && "$pip_target" == /* && -d "$pip_target" && -w "$pip_target" ]]; then
        "$python_bin" -m pip install --upgrade "${packages[@]}"
        return
    fi
    user_target="$(python_query user-site-path)" || return 1
    if [[ -n "$user_target" && "$user_target" == /* ]]; then
        "$python_bin" -m pip install --user --upgrade "${packages[@]}"
        return
    fi
    # 按评审共识不做 sudo pip 兜底：无安全可写目标时跳过
    skip_step 'pip 安装目录不可写且用户 site 不可用，已跳过（不使用 sudo）'
}

update_active_venv() {
    if [[ -z "${VIRTUAL_ENV:-}" ]]; then
        skip_step '未激活虚拟环境，未调用系统 pip'
        return
    fi

    local python_bin="$VIRTUAL_ENV/bin/python"
    validate_venv "$python_bin" || return 1

    local package_json package_lines
    if ! package_json="$("$python_bin" -m pip list --local --outdated --not-required --format=json)"; then
        STEP_DETAIL='无法读取顶层过期包列表'
        return 1
    fi
    if ! package_lines="$(printf '%s' "$package_json" | parse_package_names "$python_bin")"; then
        STEP_DETAIL='无法解析 pip 包列表'
        return 1
    fi

    local result=0 package
    local -a packages=()
    if [[ -n "$package_lines" ]]; then
        while IFS= read -r package; do
            [[ -n "$package" ]] && packages+=("$package")
        done <<<"$package_lines"
        "$python_bin" -m pip install --upgrade --upgrade-strategy only-if-needed "${packages[@]}" || result=1
    else
        STEP_DETAIL='没有可安全更新的顶层过期包'
    fi
    "$python_bin" -m pip check || result=1
    return "$result"
}

update_python_packages() {
    if [[ "$PLATFORM" == 'macos' ]]; then
        update_macos_python
    else
        update_active_venv
    fi
}
