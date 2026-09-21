#!/usr/bin/env bash
# 平台识别与并发锁：目录锁、内核锁、陈锁回收与锁目录安全校验。
# 由 update-local-packages.test.sh 加载，依赖 lib/harness.sh 与 lib/fixture.sh。

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
    (:) &
    local dead_pid=$!
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
    ln -s "$(command -v flock)" "$MOCK_BIN/flock"
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    [[ -f "$RUNTIME_DIR/upkeep-${UID}.lock" ]] || fail 'flock lock file was not created' || exit
    exec 8<>"$RUNTIME_DIR/upkeep-${UID}.lock"
    flock -n 8 || fail 'flock lock was not released after exit' || exit
)

test_flock_mode_rejects_concurrent_run() (
    create_fixture
    ln -s "$(command -v flock)" "$MOCK_BIN/flock"
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

run_test lock 'Darwin selects macOS' test_darwin_selects_macos_platform
run_test lock 'Linux selects Linux' test_linux_selects_linux_platform
run_test lock 'unsupported platform fails before updates' test_unsupported_platform_fails_before_updates
run_test lock 'concurrent directory lock is rejected' test_concurrent_directory_lock_is_rejected
run_test lock 'lock is removed after success' test_lock_is_removed_after_success
run_test lock 'stale directory lock is reclaimed' test_stale_directory_lock_is_reclaimed
run_test lock 'live directory lock is respected' test_live_directory_lock_is_respected
run_test lock 'flock mode is used when available' test_flock_mode_is_used_when_available flock
run_test lock 'flock mode rejects concurrent run' test_flock_mode_rejects_concurrent_run flock
run_test lock 'missing lock parent is created on macOS' test_missing_lock_parent_is_created_on_macos
run_test lock 'unsafe lock parent is rejected' test_unsafe_lock_parent_is_rejected
run_test lock 'symlink lock parent is rejected' test_symlink_lock_parent_is_rejected
