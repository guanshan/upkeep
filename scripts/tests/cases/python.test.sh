#!/usr/bin/env bash
# Python 生态：uv 自更新的各种受限路径、pipx、虚拟环境与 macOS 全局 Python。
# 由 update-local-packages.test.sh 加载，依赖 lib/harness.sh 与 lib/fixture.sh。

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

run_test python 'uv rate limit still updates tools' test_uv_rate_limit_still_updates_tools
run_test python 'uv latest version skips reinstall' test_rate_limited_uv_at_latest_skips_reinstall
run_test python 'uv installer fallback failure is reported' test_uv_installer_fallback_failure_is_reported
run_test python 'unsupported uv self update still updates tools' test_unsupported_uv_self_update_still_updates_tools
run_test python 'Homebrew uv skips self update and updates tools' test_homebrew_uv_skips_self_update_and_updates_tools
run_test python 'external-manager uv error is summarized' test_external_manager_uv_error_is_summarized
run_test python 'Linux without venv skips pip' test_linux_without_venv_never_installs_pip_packages
run_test python 'Linux active venv updates top-level packages' test_linux_active_venv_updates_top_level_packages
run_test python 'macOS updates writable Python target' test_macos_updates_writable_python_target
run_test python 'macOS prefers Python user site' test_macos_unwritable_python_prefers_user_site
run_test python 'macOS PEP 668 is skipped not failed' test_macos_pep668_is_skipped_not_failed
run_test python 'macOS python without writable target skips sudo' test_macos_python_without_writable_target_skips_without_sudo
run_test python 'macOS installs missing pipx with Homebrew' test_macos_missing_pipx_installs_with_homebrew
run_test python 'Linux skips missing pipx' test_linux_missing_pipx_is_skipped
