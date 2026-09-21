#!/usr/bin/env bash
# 测试夹具：mock 命令驱动、隔离的运行目录与被测脚本的调用封装。由测试入口加载。
# 依赖 harness.sh 提供的 TEST_TMP，以及入口声明的 UPDATE_SCRIPT。

create_fixture() {
    FIXTURE_DIR="$(mktemp -d "$TEST_TMP/case.XXXXXX")"
    MOCK_BIN="$FIXTURE_DIR/bin"
    CORE_BIN="$FIXTURE_DIR/core-bin"
    CALLS_FILE="$FIXTURE_DIR/calls"
    OUTPUT_FILE="$FIXTURE_DIR/output"
    RUNTIME_DIR="$FIXTURE_DIR/runtime"
    mkdir -p "$MOCK_BIN" "$CORE_BIN" "$RUNTIME_DIR" "$FIXTURE_DIR/home" \
        "$FIXTURE_DIR/state" "$FIXTURE_DIR/purelib" "$FIXTURE_DIR/user-site" \
        "$FIXTURE_DIR/gems" "$FIXTURE_DIR/pnpm-global"
    chmod 700 "$RUNTIME_DIR" "$FIXTURE_DIR/state"
    printf '{}\n' >"$FIXTURE_DIR/pnpm-global/package.json"
    : >"$CALLS_FILE"
    link_core_commands
    create_command_driver

    STUB_UNAME='Linux'
    MOCK_UID='1000'
    MOCK_STAT_MODE='700'
    MOCK_NPM_GLOBALS='corepack npm'
    MOCK_NPM_LS_STATUS='0'
    MOCK_PNPM_ROOT="$FIXTURE_DIR/pnpm-global/node_modules"
    MOCK_PNPM_ROOT_STATUS='0'
    MOCK_GEM_USER_DIR="$FIXTURE_DIR/gems"
    MOCK_FAIL_MANAGER=''
    MOCK_FAIL_STATUS='42'
    MOCK_UV_SELF_UNSUPPORTED=''
    MOCK_UV_EXTERNAL_MANAGER=''
    MOCK_UV_SELF_RATELIMITED=''
    MOCK_UV_VERSION='0.11.7'
    MOCK_BUN_LIST='global-package@1.0.0'
    MOCK_BUN_NO_MANIFEST=''
    MOCK_CARGO_LIST=''
    MOCK_CARGO_UPDATE_STATUS='0'
    MOCK_GEM_OUTDATED=''
    MOCK_BREW_RUBY_PREFIX=''
    MOCK_BREW_UV_PREFIX=''
    MOCK_PIP_OUTDATED=''
    MOCK_PIP_EXTERNAL='1'
    MOCK_PIP_TARGET="$FIXTURE_DIR/purelib"
    MOCK_PIP_USER_TARGET="$FIXTURE_DIR/user-site"
    MOCK_PYTHON_VENV='1'
    MOCK_PIP_FAIL_COMMAND=''
    TEST_VIRTUAL_ENV=''
    TEST_XDG_RUNTIME_DIR="$RUNTIME_DIR"
    TEST_XDG_STATE_HOME="$FIXTURE_DIR/state"
    TEST_XDG_CONFIG_HOME="$FIXTURE_DIR/home/.config"
    # 空串 = 本次不加载任何站点配置。若不这样兜底，测试会读到仓库自带的 config.sh。
    # 需要验证自动发现顺序的用例请 unset 它（见 write_private_npm_config）。
    TEST_UPKEEP_CONFIG=''
    NODE_TLS_REJECT_UNAUTHORIZED=''
}

link_core_commands() {
    local command_name command_path
    for command_name in awk bash chmod dirname ln mkdir mktemp rm rmdir sed sh; do
        command_path="$(command -v "$command_name")"
        ln -s "$command_path" "$CORE_BIN/$command_name"
    done
    REAL_PYTHON_BIN="$(command -v python3)"
}

create_command_driver() {
    cp "$TEST_DIR/fixtures/command-driver.sh" "$FIXTURE_DIR/command-driver"
    chmod +x "$FIXTURE_DIR/command-driver"
    ln -s "$FIXTURE_DIR/command-driver" "$MOCK_BIN/uname"
    ln -s "$FIXTURE_DIR/command-driver" "$MOCK_BIN/stat"
    ln -s "$FIXTURE_DIR/command-driver" "$MOCK_BIN/id"
}

enable_tools() {
    local tool
    for tool in "$@"; do
        ln -sf "$FIXTURE_DIR/command-driver" "$MOCK_BIN/$tool"
    done
}

create_venv_python() {
    local venv_dir="$1"
    mkdir -p "$venv_dir/bin"
    cat >"$venv_dir/bin/python" <<'PYTHON'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == '-c' && "${2:-}" == *'sys.prefix != sys.base_prefix'* ]]; then
    exit "${MOCK_VENV_VALID_STATUS:-0}"
fi
if [[ "${1:-}" == '-c' ]]; then
    exec "$REAL_PYTHON_BIN" "$@"
fi
{
    printf 'venv-python'
    printf ' %s' "$@"
    printf '\n'
} >>"$CALLS_FILE"
if [[ "${1:-} ${2:-} ${3:-}" == '-m pip list' ]]; then
    printf '%s\n' "${MOCK_PIP_LIST_JSON:-[]}"
elif [[ "${1:-} ${2:-} ${3:-}" == '-m pip install' && "${MOCK_PIP_FAIL_COMMAND:-}" == 'install' ]]; then
    exit 42
elif [[ "${1:-} ${2:-} ${3:-}" == '-m pip check' && "${MOCK_PIP_FAIL_COMMAND:-}" == 'check' ]]; then
    exit 42
fi
exit 0
PYTHON
    chmod +x "$venv_dir/bin/python"
}

# UPKEEP_CONFIG 必须能「完全不设置」，才能测到自动发现顺序；环境变量前缀做不到
# 条件省略，故在外层包一次。测试入口已 unset UPKEEP_CONFIG，避免继承开发者本机的值。
run_update() {
    if [[ -n "${TEST_UPKEEP_CONFIG+set}" ]]; then
        UPKEEP_CONFIG="$TEST_UPKEEP_CONFIG" run_update_impl "$@"
    else
        run_update_impl "$@"
    fi
}

# 往夹具的用户级配置目录写一份站点配置，并让脚本走自动发现来命中它。
write_private_npm_config() {
    local registry="${1-https://registry.example.com/npm}"
    local config_dir="$TEST_XDG_CONFIG_HOME/upkeep"
    mkdir -p "$config_dir"
    printf '%s\n' \
        "PRIVATE_NPM_REGISTRY='$registry'" \
        "PRIVATE_NPM_SCOPES=('@example')" \
        "PRIVATE_NPM_PACKAGES=('@example/cli' '@example/strict|--engine-strict')" \
        >"$config_dir/config.sh"
    unset TEST_UPKEEP_CONFIG
}

# 这一长串前缀赋值里，右侧的 $MOCK_BIN / $FIXTURE_DIR 取的都是外层 create_fixture 设好的值，
# 再原样导出给被测脚本；shellcheck 会提醒"同一前缀内的赋值互不可见"，此处正是期望行为。
# shellcheck disable=SC2097,SC2098
run_update_impl() {
    PATH="$MOCK_BIN:$CORE_BIN" \
        CALLS_FILE="$CALLS_FILE" \
        FIXTURE_DIR="$FIXTURE_DIR" \
        MOCK_BIN="$MOCK_BIN" \
        REAL_PYTHON_BIN="$REAL_PYTHON_BIN" \
        XDG_RUNTIME_DIR="$TEST_XDG_RUNTIME_DIR" \
        XDG_STATE_HOME="$TEST_XDG_STATE_HOME" \
        XDG_CONFIG_HOME="$TEST_XDG_CONFIG_HOME" \
        HOME="$FIXTURE_DIR/home" \
        VIRTUAL_ENV="$TEST_VIRTUAL_ENV" \
        STUB_UNAME="$STUB_UNAME" \
        MOCK_UID="$MOCK_UID" \
        MOCK_STAT_MODE="$MOCK_STAT_MODE" \
        MOCK_NPM_GLOBALS="$MOCK_NPM_GLOBALS" \
        MOCK_NPM_LS_STATUS="$MOCK_NPM_LS_STATUS" \
        MOCK_PNPM_ROOT="$MOCK_PNPM_ROOT" \
        MOCK_PNPM_ROOT_STATUS="$MOCK_PNPM_ROOT_STATUS" \
        MOCK_GEM_USER_DIR="$MOCK_GEM_USER_DIR" \
        MOCK_FAIL_MANAGER="$MOCK_FAIL_MANAGER" \
        MOCK_FAIL_STATUS="$MOCK_FAIL_STATUS" \
        MOCK_UV_SELF_UNSUPPORTED="$MOCK_UV_SELF_UNSUPPORTED" \
        MOCK_UV_EXTERNAL_MANAGER="$MOCK_UV_EXTERNAL_MANAGER" \
        MOCK_UV_SELF_RATELIMITED="$MOCK_UV_SELF_RATELIMITED" \
        MOCK_UV_VERSION="$MOCK_UV_VERSION" \
        MOCK_BUN_LIST="$MOCK_BUN_LIST" \
        MOCK_BUN_NO_MANIFEST="$MOCK_BUN_NO_MANIFEST" \
        MOCK_CARGO_LIST="$MOCK_CARGO_LIST" \
        MOCK_CARGO_UPDATE_STATUS="$MOCK_CARGO_UPDATE_STATUS" \
        MOCK_GEM_OUTDATED="$MOCK_GEM_OUTDATED" \
        MOCK_BREW_RUBY_PREFIX="$MOCK_BREW_RUBY_PREFIX" \
        MOCK_BREW_UV_PREFIX="$MOCK_BREW_UV_PREFIX" \
        MOCK_PIP_OUTDATED="$MOCK_PIP_OUTDATED" \
        MOCK_PIP_EXTERNAL="$MOCK_PIP_EXTERNAL" \
        MOCK_PIP_TARGET="$MOCK_PIP_TARGET" \
        MOCK_PIP_USER_TARGET="$MOCK_PIP_USER_TARGET" \
        MOCK_PYTHON_VENV="$MOCK_PYTHON_VENV" \
        MOCK_PIP_FAIL_COMMAND="$MOCK_PIP_FAIL_COMMAND" \
        MOCK_PIP_LIST_JSON="${MOCK_PIP_LIST_JSON:-[]}" \
        MOCK_VENV_VALID_STATUS="${MOCK_VENV_VALID_STATUS:-0}" \
        NODE_TLS_REJECT_UNAUTHORIZED="$NODE_TLS_REJECT_UNAUTHORIZED" \
        "${UPDATE_BASH:-/bin/bash}" "$UPDATE_SCRIPT" "$@" >"$OUTPUT_FILE" 2>&1
    RUN_STATUS=$?
    RUN_OUTPUT="$(<"$OUTPUT_FILE")"
    RUN_CALLS="$(<"$CALLS_FILE")"
}
