#!/usr/bin/env bash
# 验证容器输出的断言逻辑，不需要 Docker 或网络。

set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$TEST_DIR/../.." && pwd)"
# shellcheck source=scripts/tests/lib/harness.sh
source "$TEST_DIR/lib/harness.sh" || exit 1

mkdir -p "$TEST_TMP/bin"
cat >"$TEST_TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == system ]]; then
    exit 0
fi
# 读完容器输入，避免 pipefail 把生产端的 SIGPIPE 误判为容器失败。
cat >/dev/null
printf '%s\n' 'Linux 系统软件包：完成' "$MOCK_APT_SUMMARY" \
    'PROBE-BEFORE 2024a-2ubuntu1' "PROBE-AFTER $MOCK_APT_AFTER" 'PROBE-UPGRADABLE 0'
MOCK
chmod +x "$TEST_TMP/bin/docker"

test_summary() {
    local summary="$1" expected="$2" after="${3:-2026c-0ubuntu0.24.04.1}"
    local output status=0
    output="$(PATH="$TEST_TMP/bin:$PATH" MOCK_APT_SUMMARY="$summary" MOCK_APT_AFTER="$after" \
        bash "$ROOT_DIR/scripts/verify-apt-container.sh" 2>&1)" || status=$?
    assert_status "$expected" "$status" || {
        printf '%s\n' "$output" >&2
        return 1
    }
}

test_one_upgrade() { test_summary '1 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.' 0; }
test_multiple_upgrades() { test_summary '2 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.' 0; }
test_double_digit_upgrades() { test_summary '12 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.' 0; }
test_zero_upgrades() { test_summary '0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.' 1; }
test_missing_summary() { test_summary '' 1; }
test_unrelated_output() { test_summary 'Fetched 1 upgraded-package' 1; }
test_unchanged_version() { test_summary '2 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.' 1 '2024a-2ubuntu1'; }

run_test apt-contract 'one upgraded package passes' test_one_upgrade
run_test apt-contract 'multiple upgraded packages pass' test_multiple_upgrades
run_test apt-contract 'double-digit upgraded count passes' test_double_digit_upgrades
run_test apt-contract 'zero upgraded packages fail' test_zero_upgrades
run_test apt-contract 'missing apt summary fails' test_missing_summary
run_test apt-contract 'unrelated output cannot satisfy the summary' test_unrelated_output
run_test apt-contract 'unchanged tzdata still fails' test_unchanged_version

printf '\n%d passed, %d failed, %d skipped\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
((FAIL_COUNT == 0))
