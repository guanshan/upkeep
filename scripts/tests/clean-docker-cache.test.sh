#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$TEST_DIR/../.." && pwd)"
CLEAN_SCRIPT="$ROOT_DIR/scripts/clean-docker-cache.sh"
PASS_COUNT=0
FAIL_COUNT=0

fail() {
    printf '  %s\n' "$1" >&2
    return 1
}

assert_status() {
    local expected="$1"
    local actual="$2"
    [[ "$actual" == "$expected" ]] || fail "expected status $expected, got $actual"
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

create_fixture() {
    FIXTURE_DIR="$(mktemp -d)"
    trap 'rm -rf -- "$FIXTURE_DIR"' EXIT
    MOCK_BIN="$FIXTURE_DIR/bin"
    CALLS_FILE="$FIXTURE_DIR/calls"
    OUTPUT_FILE="$FIXTURE_DIR/output"
    mkdir -p "$MOCK_BIN"
    : >"$CALLS_FILE"
}

create_docker_mock() {
    cat >"$MOCK_BIN/docker" <<'MOCK'
#!/usr/bin/env bash
set -u
{
    printf 'docker'
    printf ' %s' "$@"
    printf '\n'
} >>"$CALLS_FILE"
if [[ "${MOCK_DOCKER_FAIL:-}" == "${1:-} ${2:-}" ]]; then
    exit 42
fi
MOCK
    chmod +x "$MOCK_BIN/docker"
}

run_clean() {
    PATH="${TEST_PATH:-$MOCK_BIN:/usr/bin:/bin}" \
        CALLS_FILE="$CALLS_FILE" \
        MOCK_DOCKER_FAIL="${MOCK_DOCKER_FAIL:-}" \
        /bin/bash "$CLEAN_SCRIPT" "$@" >"$OUTPUT_FILE" 2>&1
    RUN_STATUS=$?
    RUN_OUTPUT="$(<"$OUTPUT_FILE")"
    RUN_CALLS="$(<"$CALLS_FILE")"
}

test_help_describes_scope() (
    create_fixture
    run_clean --help
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '构建缓存' || exit
    assert_contains "$RUN_OUTPUT" '悬空镜像' || exit
    assert_contains "$RUN_OUTPUT" '不删除有标签的镜像、容器、卷和网络' || exit
)

test_unknown_argument_is_rejected() (
    create_fixture
    create_docker_mock
    run_clean --unexpected
    [[ "$RUN_STATUS" -ne 0 ]] || fail 'unknown argument unexpectedly succeeded' || exit
    assert_contains "$RUN_OUTPUT" '未知参数' || exit
    [[ -z "$RUN_CALLS" ]] || fail 'docker ran despite invalid arguments' || exit
)

test_prunes_build_cache_and_dangling_images() (
    create_fixture
    create_docker_mock
    run_clean
    assert_status 0 "$RUN_STATUS" || exit
    local expected_calls
    expected_calls=$'docker system df\ndocker builder prune --all --force\ndocker image prune --force\ndocker system df'
    assert_equals "$expected_calls" "$RUN_CALLS" || exit
)

test_missing_docker_is_an_error() (
    create_fixture
    TEST_PATH="$MOCK_BIN"
    run_clean
    [[ "$RUN_STATUS" -ne 0 ]] || fail 'missing docker unexpectedly succeeded' || exit
    assert_contains "$RUN_OUTPUT" '未检测到 docker' || exit
)

test_unreachable_daemon_stops_before_prune() (
    create_fixture
    create_docker_mock
    MOCK_DOCKER_FAIL='system df'
    run_clean
    [[ "$RUN_STATUS" -ne 0 ]] || fail 'daemon failure unexpectedly succeeded' || exit
    assert_contains "$RUN_OUTPUT" '无法访问 docker daemon' || exit
    assert_not_contains "$RUN_CALLS" 'builder prune' || exit
)

test_builder_prune_failure_still_prunes_images() (
    create_fixture
    create_docker_mock
    MOCK_DOCKER_FAIL='builder prune'
    run_clean
    [[ "$RUN_STATUS" -ne 0 ]] || fail 'builder prune failure unexpectedly succeeded' || exit
    assert_contains "$RUN_CALLS" 'docker image prune --force' || exit
)

test_makefile_exposes_clean_docker_target() (
    local dry_run_output status
    dry_run_output="$(/usr/bin/make --no-print-directory -n -C "$ROOT_DIR" clean-docker 2>&1)"
    status=$?
    assert_status 0 "$status" || exit
    assert_contains "$dry_run_output" "$ROOT_DIR/scripts/clean-docker-cache.sh" || exit
)

run_test() {
    local name="$1"
    local function_name="$2"
    if "$function_name"; then
        printf 'PASS %s\n' "$name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf 'FAIL %s\n' "$name" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

run_test 'help describes scope' test_help_describes_scope
run_test 'unknown argument is rejected' test_unknown_argument_is_rejected
run_test 'prunes build cache and dangling images' test_prunes_build_cache_and_dangling_images
run_test 'missing docker is an error' test_missing_docker_is_an_error
run_test 'unreachable daemon stops before prune' test_unreachable_daemon_stops_before_prune
run_test 'builder prune failure still prunes images' test_builder_prune_failure_still_prunes_images
run_test 'Makefile exposes clean-docker target' test_makefile_exposes_clean_docker_target

printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
((FAIL_COUNT == 0))
