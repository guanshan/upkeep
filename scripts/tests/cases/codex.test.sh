#!/usr/bin/env bash
# 独立更新必须覆盖实际使用的入口，不能把另一份安装的成功当作当前 CLI 已更新。

create_native_codex() {
    local launcher="$FIXTURE_DIR/home/.local/bin/codex"
    mkdir -p "${launcher%/*}"
    cat >"$launcher" <<'CODEX'
#!/usr/bin/env bash
printf 'native-codex %s\n' "$*" >>"$CALLS_FILE"
case "${1:-}" in
    --version)
        if [[ -e "${0%/*}/updated-codex" ]]; then
            printf 'codex-cli 0.159.2\n'
        else
            printf 'codex-cli 0.159.1\n'
        fi
        ;;
    update)
        if [[ -e "${0%/*}/unknown-install-method" ]]; then
            printf 'Error: Could not detect the Codex installation method. Please update manually: https://developers.openai.com/codex/cli/\n' >&2
            exit 1
        fi
        if [[ "${MOCK_FAIL_MANAGER:-}" == 'codex' ]]; then
            printf 'Error: download failed\n' >&2
            exit 42
        fi
        : >"${0%/*}/updated-codex"
        ;;
    *) exit 1 ;;
esac
CODEX
    chmod +x "$launcher"
    ln -s "$launcher" "$MOCK_BIN/codex"
}

create_codex_installer() {
    cat >"$MOCK_BIN/curl" <<'CURL'
#!/usr/bin/env bash
printf 'codex-installer-download %s\n' "$*" >>"$CALLS_FILE"
cat <<'INSTALLER'
printf 'codex-installer %s\n' "$*" >>"$CALLS_FILE"
printf 'CODEX_INSTALL_DIR=%s CODEX_NON_INTERACTIVE=%s\n' "$CODEX_INSTALL_DIR" "$CODEX_NON_INTERACTIVE" >>"$CALLS_FILE"
case "$PATH" in
    "$CODEX_INSTALL_DIR":*) ;;
    *) exit 44 ;;
esac
[ ! -e "$CODEX_INSTALL_DIR/fail-installer" ] || exit 43
: >"$CODEX_INSTALL_DIR/updated-codex"
INSTALLER
[[ ! -e "$HOME/.local/bin/fail-download" ]] || exit 22
CURL
    chmod +x "$MOCK_BIN/curl"
    ln -s "$(command -v cat)" "$CORE_BIN/cat"
}

test_codex_missing_native_is_skipped() (
    create_fixture
    enable_tools codex
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'Codex CLI 独立安装：跳过' || exit
    assert_not_contains "$RUN_CALLS" 'codex update' || exit
)

test_codex_native_updates_and_reports_versions() (
    create_fixture
    create_native_codex
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'native-codex update' || exit
    assert_contains "$RUN_OUTPUT" 'Codex CLI 独立安装：完成（codex-cli 0.159.1 → codex-cli 0.159.2）' || exit
)

test_codex_update_failure_continues() (
    create_fixture
    create_native_codex
    enable_tools rustup
    create_codex_installer
    MOCK_FAIL_MANAGER='codex'
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'Codex CLI 独立安装：失败' || exit
    assert_contains "$RUN_OUTPUT" 'codex update 失败（退出状态：42）：Error: download failed' || exit
    assert_not_contains "$RUN_CALLS" 'codex-installer-download' || exit
    assert_contains "$RUN_CALLS" 'rustup update' || exit
)

test_codex_unknown_method_uses_installer() (
    create_fixture
    create_native_codex
    create_codex_installer
    : >"$FIXTURE_DIR/home/.local/bin/unknown-install-method"
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'https://chatgpt.com/codex/install.sh' || exit
    assert_contains "$RUN_CALLS" 'codex-installer --release latest' || exit
    assert_contains "$RUN_CALLS" "CODEX_INSTALL_DIR=$FIXTURE_DIR/home/.local/bin CODEX_NON_INTERACTIVE=1" || exit
    assert_contains "$RUN_OUTPUT" 'Codex CLI 独立安装：完成（codex-cli 0.159.1 → codex-cli 0.159.2；安装方式识别失败，已通过官方安装脚本更新）' || exit
)

test_codex_unknown_method_without_curl_fails() (
    create_fixture
    create_native_codex
    : >"$FIXTURE_DIR/home/.local/bin/unknown-install-method"
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '缺少 curl' || exit
)

test_codex_installer_download_failure_is_not_executed() (
    create_fixture
    create_native_codex
    create_codex_installer
    : >"$FIXTURE_DIR/home/.local/bin/unknown-install-method"
    : >"$FIXTURE_DIR/home/.local/bin/fail-download"
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '官方安装脚本下载失败' || exit
    assert_not_contains "$RUN_CALLS" 'codex-installer --release' || exit
    [[ ! -e "$FIXTURE_DIR/home/.local/bin/updated-codex" ]] || exit 1
)

test_codex_installer_failure_continues() (
    create_fixture
    create_native_codex
    create_codex_installer
    enable_tools rustup
    : >"$FIXTURE_DIR/home/.local/bin/unknown-install-method"
    : >"$FIXTURE_DIR/home/.local/bin/fail-installer"
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '官方安装脚本更新失败' || exit
    assert_contains "$RUN_CALLS" 'rustup update' || exit
)

test_codex_installer_does_not_hide_shadowed_install() (
    create_fixture
    create_native_codex
    create_codex_installer
    enable_tools codex
    : >"$FIXTURE_DIR/home/.local/bin/unknown-install-method"
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'codex-installer --release latest' || exit
    assert_contains "$RUN_OUTPUT" 'PATH 未使用独立安装' || exit
)

test_codex_shadowed_native_is_reported() (
    create_fixture
    create_native_codex
    enable_tools codex
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'native-codex update' || exit
    assert_not_contains "$RUN_CALLS" $'\ncodex update' || exit
    assert_contains "$RUN_OUTPUT" 'PATH 未使用独立安装' || exit
)

test_codex_native_outside_path_is_reported() (
    create_fixture
    create_native_codex
    rm "$MOCK_BIN/codex"
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '当前：未找到' || exit
)

run_test codex 'non-standalone installation is left to package managers' test_codex_missing_native_is_skipped
run_test codex 'standalone update reports before and after versions' test_codex_native_updates_and_reports_versions
run_test codex 'standalone update failure does not stop later steps' test_codex_update_failure_continues
run_test codex 'unknown installation method falls back to official installer' test_codex_unknown_method_uses_installer
run_test codex 'unknown installation method without curl fails clearly' test_codex_unknown_method_without_curl_fails
run_test codex 'failed installer download is never executed' test_codex_installer_download_failure_is_not_executed
run_test codex 'installer failure does not stop later steps' test_codex_installer_failure_continues
run_test codex 'installer fallback still reports a shadowed installation' test_codex_installer_does_not_hide_shadowed_install
run_test codex 'shadowed standalone installation is reported' test_codex_shadowed_native_is_reported
run_test codex 'standalone installation outside PATH is reported' test_codex_native_outside_path_is_reported
