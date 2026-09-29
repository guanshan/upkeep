#!/usr/bin/env bash
# 原生更新必须覆盖实际使用的入口，不能把另一份安装的成功当作当前 CLI 已更新。

create_native_claude() {
    local launcher="$FIXTURE_DIR/home/.local/bin/claude"
    mkdir -p "${launcher%/*}"
    cat >"$launcher" <<'CLAUDE'
#!/usr/bin/env bash
printf 'native-claude %s\n' "$*" >>"$CALLS_FILE"
case "${1:-}" in
    --version)
        if [[ -e "${0%/*}/updated" ]]; then
            printf '2.1.2 (Claude Code)\n'
        else
            printf '2.1.1 (Claude Code)\n'
        fi
        ;;
    update)
        [[ "${MOCK_FAIL_MANAGER:-}" != 'claude' ]] || exit 42
        : >"${0%/*}/updated"
        ;;
    *) exit 1 ;;
esac
CLAUDE
    chmod +x "$launcher"
    ln -s "$launcher" "$MOCK_BIN/claude"
}

test_claude_missing_native_is_skipped() (
    create_fixture
    enable_tools claude
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'Claude Code 原生安装：跳过' || exit
    assert_not_contains "$RUN_CALLS" 'claude update' || exit
    assert_not_contains "$RUN_CALLS" 'claude install' || exit
)

test_claude_native_updates_and_reports_versions() (
    create_fixture
    create_native_claude
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'native-claude update' || exit
    assert_contains "$RUN_OUTPUT" 'Claude Code 原生安装：完成（2.1.1 (Claude Code) → 2.1.2 (Claude Code)）' || exit
    assert_not_contains "$RUN_CALLS" 'sudo' || exit
)

test_claude_update_failure_continues() (
    create_fixture
    create_native_claude
    enable_tools rustup
    MOCK_FAIL_MANAGER='claude'
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'Claude Code 原生安装：失败' || exit
    assert_contains "$RUN_CALLS" 'rustup update' || exit
)

test_claude_shadowed_native_is_reported() (
    create_fixture
    create_native_claude
    enable_tools claude
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'native-claude update' || exit
    assert_not_contains "$RUN_CALLS" $'\nclaude update' || exit
    assert_contains "$RUN_OUTPUT" 'PATH 未使用原生安装' || exit
)

test_claude_native_outside_path_is_reported() (
    create_fixture
    create_native_claude
    rm "$MOCK_BIN/claude"
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '当前：未找到' || exit
)

run_test claude 'non-native installation is left to package managers' test_claude_missing_native_is_skipped
run_test claude 'native update reports before and after versions' test_claude_native_updates_and_reports_versions
run_test claude 'native update failure does not stop later steps' test_claude_update_failure_continues
run_test claude 'shadowed native installation is reported' test_claude_shadowed_native_is_reported
run_test claude 'native installation outside PATH is reported' test_claude_native_outside_path_is_reported
