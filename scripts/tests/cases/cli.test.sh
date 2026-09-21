#!/usr/bin/env bash
# 命令行接口：参数解析、帮助文本与 Makefile 目标。
# 由 update-local-packages.test.sh 加载，依赖 lib/harness.sh 与 lib/fixture.sh。

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

test_makefile_exposes_existing_targets() (
    local output status
    output="$(make --no-print-directory -n -C "$ROOT_DIR" update 2>&1)"
    status=$?
    assert_status 0 "$status" || exit
    assert_contains "$output" 'scripts/update-local-packages.sh' || exit
    output="$(make --no-print-directory -s -C "$ROOT_DIR" update-help 2>&1)"
    assert_contains "$output" 'macOS：Homebrew' || exit
)

run_test cli 'help describes cross-platform scope' test_help_describes_cross_platform_scope
run_test cli 'unknown argument is rejected' test_unknown_argument_is_rejected
run_test cli 'Makefile exposes existing targets' test_makefile_exposes_existing_targets
