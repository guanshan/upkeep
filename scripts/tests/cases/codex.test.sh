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
        [[ "${MOCK_FAIL_MANAGER:-}" != 'codex' ]] || exit 42
        : >"${0%/*}/updated-codex"
        ;;
    *) exit 1 ;;
esac
CODEX
    chmod +x "$launcher"
    ln -s "$launcher" "$MOCK_BIN/codex"
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
    MOCK_FAIL_MANAGER='codex'
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'Codex CLI 独立安装：失败' || exit
    assert_contains "$RUN_CALLS" 'rustup update' || exit
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
run_test codex 'shadowed standalone installation is reported' test_codex_shadowed_native_is_reported
run_test codex 'standalone installation outside PATH is reported' test_codex_native_outside_path_is_reported
