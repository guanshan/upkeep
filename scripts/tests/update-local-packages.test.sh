#!/usr/bin/env bash
# 测试入口：加载框架与夹具，按域执行 cases/ 下的用例文件，最后统一汇总。
# 单独跑一个域：TEST_FILTER=node make test-update

set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$TEST_DIR/../.." && pwd)"
UPDATE_SCRIPT="$ROOT_DIR/scripts/update-local-packages.sh"

# 站点配置的自动发现必须从「未设置」开始，否则会继承开发者本机的值。
unset UPKEEP_CONFIG

for test_module in lib/harness lib/fixture; do
    # shellcheck disable=SC1090 # 路径由循环拼出，shellcheck 无法静态跟随
    if ! source "$TEST_DIR/$test_module.sh"; then
        printf '错误：无法加载测试模块 %s\n' "$TEST_DIR/$test_module.sh" >&2
        exit 1
    fi
done

for case_module in cli config lock system node python flow; do
    # shellcheck disable=SC1090 # 路径由循环拼出，shellcheck 无法静态跟随
    if ! source "$TEST_DIR/cases/$case_module.test.sh"; then
        printf '错误：无法加载用例文件 %s\n' "$TEST_DIR/cases/$case_module.test.sh" >&2
        exit 1
    fi
done

printf '\n%d passed, %d failed, %d skipped\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
((FAIL_COUNT == 0))
