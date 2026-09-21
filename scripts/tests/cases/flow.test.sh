#!/usr/bin/env bash
# 整体编排：跨平台共用步骤、失败后继续执行与汇总、TLS 覆盖的清除。
# 由 update-local-packages.test.sh 加载，依赖 lib/harness.sh 与 lib/fixture.sh。

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

test_tls_override_is_cleared_without_secret_output() (
    create_fixture
    enable_tools npm
    NODE_TLS_REJECT_UNAUTHORIZED='0'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'NODE_TLS_REJECT_UNAUTHORIZED' || exit
    assert_contains "$RUN_CALLS" 'NODE_TLS_REJECT_UNAUTHORIZED=]' || exit
)

run_test flow 'shared tools run on macOS' test_shared_tools_run_on_macos
run_test flow 'failures continue and return nonzero' test_failure_continues_and_returns_nonzero_summary
run_test flow 'TLS override is cleared' test_tls_override_is_cleared_without_secret_output
