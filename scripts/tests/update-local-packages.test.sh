#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$TEST_DIR/../.." && pwd)"
UPDATE_SCRIPT="$ROOT_DIR/scripts/update-local-packages.sh"
source "$TEST_DIR/update-local-packages.helpers.sh"
test_help_describes_cross_platform_scope() (
    create_fixture
    run_update --help
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'macOS：Homebrew' || exit
    assert_contains "$RUN_OUTPUT" 'Linux：DNF' || exit
    assert_contains "$RUN_OUTPUT" '失败后继续执行' || exit
)

test_unknown_argument_is_rejected() (
    create_fixture
    run_update --unexpected
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '未知参数' || exit
)

test_darwin_selects_macos_platform() (
    create_fixture
    STUB_UNAME='Darwin'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '运行平台：macOS' || exit
)

test_linux_selects_linux_platform() (
    create_fixture
    STUB_UNAME='Linux'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '运行平台：Linux' || exit
)

test_unsupported_platform_fails_before_updates() (
    create_fixture
    STUB_UNAME='FreeBSD'
    enable_tools npm
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '暂不支持的操作系统' || exit
    assert_not_contains "$RUN_CALLS" 'npm ' || exit
)

test_concurrent_directory_lock_is_rejected() (
    create_fixture
    mkdir "$RUNTIME_DIR/upkeep-${UID}.lock"
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '已有更新任务正在运行' || exit
)

test_lock_is_removed_after_success() (
    create_fixture
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    [[ ! -e "$RUNTIME_DIR/upkeep-${UID}.lock" ]] || fail 'lock directory was not removed' || exit
)

test_stale_directory_lock_is_reclaimed() (
    create_fixture
    mkdir "$RUNTIME_DIR/upkeep-${UID}.lock"
    ( : ) & local dead_pid=$!
    wait "$dead_pid"
    printf '%s\n' "$dead_pid" >"$RUNTIME_DIR/upkeep-${UID}.lock/pid"
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '清理残留锁' || exit
    [[ ! -e "$RUNTIME_DIR/upkeep-${UID}.lock" ]] || fail 'reclaimed lock was not removed after run' || exit
)

test_live_directory_lock_is_respected() (
    create_fixture
    mkdir "$RUNTIME_DIR/upkeep-${UID}.lock"
    printf '%s\n' "$$" >"$RUNTIME_DIR/upkeep-${UID}.lock/pid"
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '已有更新任务正在运行' || exit
)

test_flock_mode_is_used_when_available() (
    create_fixture
    [[ -n "$TEST_FLOCK_BIN" ]] || return 77
    ln -s "$TEST_FLOCK_BIN" "$MOCK_BIN/flock"
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    [[ -f "$RUNTIME_DIR/upkeep-${UID}.lock" ]] || fail 'flock lock file was not created' || exit
    exec 8<>"$RUNTIME_DIR/upkeep-${UID}.lock"
    flock -n 8 || fail 'flock lock was not released after exit' || exit
)

test_flock_mode_rejects_concurrent_run() (
    create_fixture
    [[ -n "$TEST_FLOCK_BIN" ]] || return 77
    ln -s "$TEST_FLOCK_BIN" "$MOCK_BIN/flock"
    exec 8<>"$RUNTIME_DIR/upkeep-${UID}.lock"
    flock -n 8 || fail 'test setup could not take the lock' || exit
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '已有更新任务正在运行' || exit
)

test_missing_lock_parent_is_created_on_macos() (
    create_fixture
    STUB_UNAME='Darwin'
    TEST_XDG_RUNTIME_DIR=''
    TEST_XDG_STATE_HOME="$FIXTURE_DIR/new-state-home"
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    [[ -d "$TEST_XDG_STATE_HOME/upkeep" ]] || fail 'lock parent was not created' || exit
    [[ ! -e "$TEST_XDG_STATE_HOME/upkeep/upkeep-${UID}.lock" ]] || fail 'lock was not removed' || exit
)

test_unsafe_lock_parent_is_rejected() (
    create_fixture
    MOCK_STAT_MODE='777'
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '锁目录权限过宽' || exit
)

test_symlink_lock_parent_is_rejected() (
    create_fixture
    mkdir "$FIXTURE_DIR/real-runtime"
    chmod 700 "$FIXTURE_DIR/real-runtime"
    ln -s "$FIXTURE_DIR/real-runtime" "$FIXTURE_DIR/runtime-link"
    TEST_XDG_RUNTIME_DIR="$FIXTURE_DIR/runtime-link"
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '锁目录必须由当前用户独占' || exit
)

test_darwin_uses_homebrew_not_dnf() (
    create_fixture
    STUB_UNAME='Darwin'
    enable_tools brew dnf
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'brew update' || exit
    assert_contains "$RUN_CALLS" 'brew upgrade --formula --no-ask' || exit
    assert_contains "$RUN_CALLS" 'brew upgrade --cask --no-ask' || exit
    assert_not_contains "$RUN_CALLS" 'dnf upgrade' || exit
)

test_linux_uses_dnf_not_homebrew() (
    create_fixture
    STUB_UNAME='Linux'
    MOCK_UID='0'
    enable_tools brew dnf
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'dnf upgrade --refresh --assumeyes --noautoremove' || exit
    assert_not_contains "$RUN_CALLS" 'brew update' || exit
)

test_non_root_linux_uses_sudo_for_dnf() (
    create_fixture
    STUB_UNAME='Linux'
    MOCK_UID='1000'
    enable_tools dnf sudo
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" "sudo -- $MOCK_BIN/dnf upgrade --refresh --assumeyes --noautoremove" || exit
)

test_shared_tools_run_on_macos() (
    create_fixture
    STUB_UNAME='Darwin'
    enable_tools pnpm bun rustup cargo gem ruby
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'pnpm update --global --latest' || exit
    assert_contains "$RUN_CALLS" 'bun update --global --latest' || exit
    assert_contains "$RUN_CALLS" 'rustup update' || exit
    assert_contains "$RUN_CALLS" 'cargo install --list' || exit
    assert_contains "$RUN_CALLS" 'gem outdated' || exit
)

test_failure_continues_and_returns_nonzero_summary() (
    create_fixture
    STUB_UNAME='Darwin'
    enable_tools brew npm pipx uv rustup
    MOCK_FAIL_MANAGER='brew'
    MOCK_FAIL_STATUS='20'
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'npm update --global' || exit
    assert_contains "$RUN_CALLS" 'pipx upgrade-all' || exit
    assert_contains "$RUN_CALLS" 'uv tool upgrade --all' || exit
    assert_contains "$RUN_CALLS" 'rustup update' || exit
    assert_contains "$RUN_OUTPUT" 'Homebrew 系统软件包：失败' || exit
)

test_npm_uses_private_registry_and_extra_args() (
    create_fixture
    write_private_npm_config
    enable_tools npm
    MOCK_NPM_GLOBALS='corepack npm @example/cli @example/strict'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'npm update --global --no-audit --no-fund corepack npm' || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund @example/cli --registry=https://registry.example.com/npm' || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund --engine-strict @example/strict --registry=https://registry.example.com/npm' || exit
)

test_npm_without_global_packages_installs_private_packages() (
    create_fixture
    write_private_npm_config ''
    enable_tools npm
    MOCK_NPM_GLOBALS=''
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_not_contains "$RUN_CALLS" 'npm update --global' || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund @example/cli' || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund --engine-strict @example/strict' || exit
    assert_not_contains "$RUN_CALLS" '--registry=' || exit
)

test_missing_private_packages_are_installed() (
    create_fixture
    write_private_npm_config
    enable_tools npm
    MOCK_NPM_GLOBALS='corepack npm'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund @example/cli --registry=https://registry.example.com/npm' || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund --engine-strict @example/strict --registry=https://registry.example.com/npm' || exit
)

test_npm_ls_nonzero_with_usable_output_is_tolerated() (
    create_fixture
    enable_tools npm
    MOCK_NPM_LS_STATUS='1'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'npm update --global --no-audit --no-fund corepack npm' || exit
    assert_not_contains "$RUN_OUTPUT" '无法枚举 npm 全局包' || exit
)

test_npm_enumeration_failure_still_installs_private_packages() (
    create_fixture
    write_private_npm_config
    enable_tools npm
    MOCK_NPM_GLOBALS=''
    MOCK_NPM_LS_STATUS='1'
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '无法枚举 npm 全局包' || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund @example/cli --registry=https://registry.example.com/npm' || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund --engine-strict @example/strict --registry=https://registry.example.com/npm' || exit
)

test_npm_without_config_updates_every_global_package() (
    create_fixture
    enable_tools npm
    MOCK_NPM_GLOBALS='corepack npm @example/public'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'npm update --global --no-audit --no-fund corepack npm @example/public' || exit
    assert_not_contains "$RUN_CALLS" 'npm install --global' || exit
)

test_invalid_config_stops_before_updates() (
    create_fixture
    mkdir -p "$FIXTURE_DIR/home/.config/upkeep"
    printf 'return 7\n' >"$FIXTURE_DIR/home/.config/upkeep/config.sh"
    enable_tools npm
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '无法加载配置' || exit
    assert_not_contains "$RUN_CALLS" 'npm ' || exit
)

test_pnpm_corepack_shim_probe_failure_is_skipped() (
    create_fixture
    enable_tools pnpm
    MOCK_PNPM_ROOT=''
    MOCK_PNPM_ROOT_STATUS='1'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'pnpm root --global [COREPACK_ENABLE_NETWORK=0] [COREPACK_ENABLE_DOWNLOAD_PROMPT=0]' || exit
    assert_not_contains "$RUN_CALLS" 'pnpm update' || exit
    assert_contains "$RUN_OUTPUT" 'corepack shim' || exit
)

test_pnpm_without_global_manifest_is_skipped() (
    create_fixture
    enable_tools pnpm
    MOCK_PNPM_ROOT="$FIXTURE_DIR/pnpm-empty/node_modules"
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_not_contains "$RUN_CALLS" 'pnpm update' || exit
    assert_contains "$RUN_OUTPUT" '没有 pnpm 全局包' || exit
)

test_pnpm_update_disables_corepack_prompt() (
    create_fixture
    enable_tools pnpm
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'pnpm update --global --latest [COREPACK_ENABLE_NETWORK=] [COREPACK_ENABLE_DOWNLOAD_PROMPT=0]' || exit
)

test_bun_without_global_manifest_is_safe() (
    create_fixture
    enable_tools bun
    MOCK_BUN_NO_MANIFEST='1'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_not_contains "$RUN_CALLS" 'bun update --global' || exit
)

test_uv_rate_limit_still_updates_tools() (
    create_fixture
    enable_tools uv curl
    MOCK_UV_SELF_RATELIMITED='1'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'curl -LsSf https://astral.sh/uv/install.sh' || exit
    assert_contains "$RUN_CALLS" 'uv tool upgrade --all' || exit
    assert_contains "$RUN_OUTPUT" '已改用安装脚本更新 uv' || exit
)

test_rate_limited_uv_at_latest_skips_reinstall() (
    create_fixture
    enable_tools uv curl
    MOCK_UV_SELF_RATELIMITED='1'
    MOCK_UV_VERSION='0.11.28'
    run_update
    if [[ "$RUN_STATUS" -ne 0 ]]; then
        printf '%s\n' "$RUN_OUTPUT" >&2
    fi
    assert_status 0 "$RUN_STATUS" || exit
    assert_not_contains "$RUN_CALLS" 'curl' || exit
    assert_contains "$RUN_OUTPUT" 'uv 已是最新版 0.11.28' || exit
)

test_uv_installer_fallback_failure_is_reported() (
    create_fixture
    enable_tools uv curl
    MOCK_UV_SELF_RATELIMITED='1'
    MOCK_FAIL_MANAGER='curl'
    run_update
    [[ "$RUN_STATUS" -ne 0 ]] || fail 'installer fallback failure unexpectedly succeeded' || exit
    assert_contains "$RUN_OUTPUT" '安装脚本重装 uv 失败' || exit
    assert_contains "$RUN_CALLS" 'uv tool upgrade --all' || exit
)

test_unsupported_uv_self_update_still_updates_tools() (
    create_fixture
    enable_tools uv
    MOCK_UV_SELF_UNSUPPORTED='1'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'uv tool upgrade --all' || exit
    assert_contains "$RUN_OUTPUT" 'uv 不是独立安装版本' || exit
)

test_homebrew_uv_skips_self_update_and_updates_tools() (
    create_fixture
    STUB_UNAME='Darwin'
    MOCK_BREW_UV_PREFIX="$FIXTURE_DIR/homebrew-uv"
    mkdir -p "$MOCK_BREW_UV_PREFIX/bin"
    ln -s "$FIXTURE_DIR/command-driver" "$MOCK_BREW_UV_PREFIX/bin/uv"
    enable_tools brew uv
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'brew --prefix uv' || exit
    assert_not_contains "$RUN_CALLS" 'uv self update' || exit
    assert_contains "$RUN_CALLS" 'uv tool upgrade --all' || exit
    assert_not_contains "$RUN_CALLS" 'curl' || exit
    assert_contains "$RUN_OUTPUT" 'uv 由 Homebrew 管理' || exit
)

test_external_manager_uv_error_is_summarized() (
    create_fixture
    enable_tools uv
    MOCK_UV_EXTERNAL_MANAGER='1'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'uv self update' || exit
    assert_contains "$RUN_CALLS" 'uv tool upgrade --all' || exit
    assert_contains "$RUN_OUTPUT" 'uv 由外部包管理器管理' || exit
    assert_not_contains "$RUN_OUTPUT" 'error: uv was installed through an external package manager' || exit
    assert_not_contains "$RUN_OUTPUT" 'hint: You installed uv using Homebrew' || exit
)

test_cargo_without_helper_is_skipped() (
    create_fixture
    enable_tools cargo
    MOCK_CARGO_LIST=$'ripgrep v14.1.1:\n    rg\n'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_not_contains "$RUN_CALLS" 'cargo install cargo-update' || exit
    assert_contains "$RUN_OUTPUT" '未安装 cargo-update' || exit
)

test_cargo_updates_with_existing_helper() (
    create_fixture
    enable_tools cargo cargo-install-update
    MOCK_CARGO_LIST=$'ripgrep v14.1.1:\n    rg\n'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'cargo-install-update --all' || exit
)

test_rubygems_uses_user_directory_without_sudo() (
    create_fixture
    enable_tools gem ruby sudo
    MOCK_GEM_OUTDATED='rake (3.0.0 < 3.1.0)'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'ruby -rrubygems' || exit
    assert_not_contains "$RUN_CALLS" 'gem env user_gemhome' || exit
    assert_contains "$RUN_CALLS" 'gem update --user-install --no-document' || exit
    assert_contains "$RUN_CALLS" "GEM_HOME=$FIXTURE_DIR/gems" || exit
    assert_not_contains "$RUN_CALLS" 'sudo -- gem' || exit
)

test_rubygems_without_usable_ruby_is_skipped() (
    create_fixture
    enable_tools gem
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '无法确定 RubyGems 用户目录' || exit
    assert_not_contains "$RUN_CALLS" 'gem outdated' || exit
)

test_linux_without_venv_never_installs_pip_packages() (
    create_fixture
    STUB_UNAME='Linux'
    enable_tools python3
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '未激活虚拟环境' || exit
    assert_not_contains "$RUN_CALLS" 'pip install' || exit
)

test_linux_active_venv_updates_top_level_packages() (
    create_fixture
    STUB_UNAME='Linux'
    TEST_VIRTUAL_ENV="$FIXTURE_DIR/venv"
    MOCK_PIP_LIST_JSON='[{"name":"alpha"}]'
    create_venv_python "$TEST_VIRTUAL_ENV"
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'venv-python -m pip install --upgrade --upgrade-strategy only-if-needed alpha' || exit
    assert_contains "$RUN_CALLS" 'venv-python -m pip check' || exit
)

test_macos_updates_writable_python_target() (
    create_fixture
    STUB_UNAME='Darwin'
    enable_tools python3
    MOCK_PIP_OUTDATED=$'alpha\n'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'python3 -m pip install --upgrade alpha' || exit
)

test_macos_unwritable_python_prefers_user_site() (
    create_fixture
    STUB_UNAME='Darwin'
    enable_tools python3 sudo
    MOCK_PIP_OUTDATED=$'alpha\n'
    MOCK_PIP_TARGET="$FIXTURE_DIR/not-created/purelib"
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'python3 -m pip install --user --upgrade alpha' || exit
    assert_not_contains "$RUN_CALLS" 'sudo --' || exit
)

test_macos_pep668_is_skipped_not_failed() (
    create_fixture
    STUB_UNAME='Darwin'
    enable_tools python3 sudo
    MOCK_PIP_OUTDATED=$'alpha\n'
    MOCK_PIP_EXTERNAL='0'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'Python 包：跳过' || exit
    assert_contains "$RUN_OUTPUT" 'PEP 668' || exit
    assert_not_contains "$RUN_CALLS" 'pip install' || exit
    assert_not_contains "$RUN_CALLS" '--break-system-packages' || exit
    assert_not_contains "$RUN_CALLS" 'sudo --' || exit
)

test_macos_python_without_writable_target_skips_without_sudo() (
    create_fixture
    STUB_UNAME='Darwin'
    enable_tools python3 sudo
    MOCK_PIP_OUTDATED=$'alpha\n'
    MOCK_PIP_TARGET="$FIXTURE_DIR/not-created/purelib"
    MOCK_PIP_USER_TARGET=''
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '不使用 sudo' || exit
    assert_contains "$RUN_OUTPUT" 'Python 包：跳过' || exit
    assert_not_contains "$RUN_CALLS" 'pip install --upgrade' || exit
    assert_not_contains "$RUN_CALLS" 'pip install --user --upgrade' || exit
    assert_not_contains "$RUN_CALLS" 'sudo --' || exit
)

test_macos_missing_pipx_installs_with_homebrew() (
    create_fixture
    STUB_UNAME='Darwin'
    enable_tools brew
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'brew install pipx' || exit
    assert_contains "$RUN_CALLS" 'pipx upgrade-all' || exit
)

test_linux_missing_pipx_is_skipped() (
    create_fixture
    STUB_UNAME='Linux'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'pipx 工具：跳过' || exit
)

test_tls_override_is_cleared_without_secret_output() (
    create_fixture
    enable_tools npm
    NODE_TLS_REJECT_UNAUTHORIZED='0'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'NODE_TLS_REJECT_UNAUTHORIZED' || exit
    assert_contains "$RUN_CALLS" 'NODE_TLS_REJECT_UNAUTHORIZED=]' || exit
)

test_makefile_exposes_existing_targets() (
    local output status
    output="$(make --no-print-directory -n -C "$ROOT_DIR" update 2>&1)"
    status=$?
    assert_status 0 "$status" || exit
    assert_contains "$output" 'scripts/update-local-packages.sh' || exit
    output="$(make --no-print-directory -s -C "$ROOT_DIR" update-help 2>&1)"
    assert_contains "$output" 'macOS：Homebrew' || exit
)

run_test task4 'help describes cross-platform scope' test_help_describes_cross_platform_scope
run_test task1 'unknown argument is rejected' test_unknown_argument_is_rejected
run_test task1 'Darwin selects macOS' test_darwin_selects_macos_platform
run_test task1 'Linux selects Linux' test_linux_selects_linux_platform
run_test task1 'unsupported platform fails before updates' test_unsupported_platform_fails_before_updates
run_test task1 'concurrent directory lock is rejected' test_concurrent_directory_lock_is_rejected
run_test task1 'lock is removed after success' test_lock_is_removed_after_success
run_test task1 'stale directory lock is reclaimed' test_stale_directory_lock_is_reclaimed
run_test task1 'live directory lock is respected' test_live_directory_lock_is_respected
run_test task1 'flock mode is used when available' test_flock_mode_is_used_when_available
run_test task1 'flock mode rejects concurrent run' test_flock_mode_rejects_concurrent_run
run_test task1 'missing lock parent is created on macOS' test_missing_lock_parent_is_created_on_macos
run_test task1 'unsafe lock parent is rejected' test_unsafe_lock_parent_is_rejected
run_test task1 'symlink lock parent is rejected' test_symlink_lock_parent_is_rejected
run_test task2 'Darwin uses Homebrew only' test_darwin_uses_homebrew_not_dnf
run_test task2 'Linux uses DNF only' test_linux_uses_dnf_not_homebrew
run_test task2 'non-root Linux uses sudo for DNF' test_non_root_linux_uses_sudo_for_dnf
run_test task2 'shared tools run on macOS' test_shared_tools_run_on_macos
run_test task2 'failures continue and return nonzero' test_failure_continues_and_returns_nonzero_summary
run_test task2 'npm uses private registry and extra args' test_npm_uses_private_registry_and_extra_args
run_test task2 'npm without globals installs private packages' test_npm_without_global_packages_installs_private_packages
run_test task2 'missing private packages are installed' test_missing_private_packages_are_installed
run_test task2 'npm ls nonzero with output is tolerated' test_npm_ls_nonzero_with_usable_output_is_tolerated
run_test task2 'npm enumeration failure still installs private packages' test_npm_enumeration_failure_still_installs_private_packages
run_test task2 'npm without config updates every global package' test_npm_without_config_updates_every_global_package
run_test task2 'invalid config stops before updates' test_invalid_config_stops_before_updates
run_test task2 'pnpm corepack shim probe failure is skipped' test_pnpm_corepack_shim_probe_failure_is_skipped
run_test task2 'pnpm without global manifest is skipped' test_pnpm_without_global_manifest_is_skipped
run_test task2 'pnpm update disables corepack prompt' test_pnpm_update_disables_corepack_prompt
run_test task2 'Bun missing manifest is safe' test_bun_without_global_manifest_is_safe
run_test task2 'uv rate limit still updates tools' test_uv_rate_limit_still_updates_tools
run_test task2 'uv latest version skips reinstall' test_rate_limited_uv_at_latest_skips_reinstall
run_test task2 'uv installer fallback failure is reported' test_uv_installer_fallback_failure_is_reported
run_test task2 'unsupported uv self update still updates tools' test_unsupported_uv_self_update_still_updates_tools
run_test task2 'Homebrew uv skips self update and updates tools' test_homebrew_uv_skips_self_update_and_updates_tools
run_test task2 'external-manager uv error is summarized' test_external_manager_uv_error_is_summarized
run_test task2 'Cargo without helper is skipped' test_cargo_without_helper_is_skipped
run_test task2 'Cargo updates with existing helper' test_cargo_updates_with_existing_helper
run_test task2 'RubyGems uses user directory' test_rubygems_uses_user_directory_without_sudo
run_test task2 'RubyGems without usable ruby is skipped' test_rubygems_without_usable_ruby_is_skipped
run_test task3 'Linux without venv skips pip' test_linux_without_venv_never_installs_pip_packages
run_test task3 'Linux active venv updates top-level packages' test_linux_active_venv_updates_top_level_packages
run_test task3 'macOS updates writable Python target' test_macos_updates_writable_python_target
run_test task3 'macOS prefers Python user site' test_macos_unwritable_python_prefers_user_site
run_test task3 'macOS PEP 668 is skipped not failed' test_macos_pep668_is_skipped_not_failed
run_test task3 'macOS python without writable target skips sudo' test_macos_python_without_writable_target_skips_without_sudo
run_test task3 'macOS installs missing pipx with Homebrew' test_macos_missing_pipx_installs_with_homebrew
run_test task3 'Linux skips missing pipx' test_linux_missing_pipx_is_skipped
run_test task2 'TLS override is cleared' test_tls_override_is_cleared_without_secret_output
run_test task4 'Makefile exposes existing targets' test_makefile_exposes_existing_targets

printf '\n%d passed, %d failed, %d skipped\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
((FAIL_COUNT == 0))
