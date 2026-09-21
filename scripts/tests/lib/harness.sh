#!/usr/bin/env bash
# 测试框架：计数器、断言与用例执行器。由测试入口加载。

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TEST_TMP="$(mktemp -d)"

cleanup() {
    rm -rf -- "$TEST_TMP"
}

trap cleanup EXIT

fail() {
    printf '  %s\n' "$1" >&2
    return 1
}

assert_status() {
    local expected="$1"
    local actual="$2"
    [[ "$actual" == "$expected" ]] || fail "expected status $expected, got $actual"
}

assert_nonzero() {
    local actual="$1"
    [[ "$actual" -ne 0 ]] || fail 'expected a non-zero status'
}

assert_contains() {
    local content="$1"
    local expected="$2"
    [[ "$content" == *"$expected"* ]] || fail "missing: $expected"
}

assert_not_contains() {
    local content="$1"
    local unexpected="$2"
    [[ "$content" != *"$unexpected"* ]] || fail "unexpected: $unexpected"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    [[ "$actual" == "$expected" ]] || fail "values differ; expected: $expected; actual: $actual"
}

# 第四个参数是可选的前置命令：宿主机没有它时跳过而不是失败。
# flock 是 Linux 自带、macOS 没有的，用真实 flock 验证内核锁无法在 macOS 上模拟。
run_test() {
    local group="$1"
    local name="$2"
    local function_name="$3"
    local requirement="${4:-}"
    if [[ -n "${TEST_FILTER:-}" && "$group" != "$TEST_FILTER" ]]; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi
    if [[ -n "$requirement" ]] && ! command -v "$requirement" >/dev/null 2>&1; then
        printf 'SKIP [%s] %s（宿主机没有 %s）\n' "$group" "$name" "$requirement"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi
    if "$function_name"; then
        printf 'PASS [%s] %s\n' "$group" "$name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        local status=$?
        # 77 是 autotools/TAP 的跳过约定：用例自己判断前置条件不满足时返回它。
        if ((status == 77)); then
            printf 'SKIP [%s] %s\n' "$group" "$name"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            return
        fi
        printf 'FAIL [%s] %s\n' "$group" "$name" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}
