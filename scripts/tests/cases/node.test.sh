#!/usr/bin/env bash
# Node 生态：npm 全局包与私有 CLI、pnpm 的 corepack shim 探测、Bun。
# 由 update-local-packages.test.sh 加载，依赖 lib/harness.sh 与 lib/fixture.sh。

test_npm_without_config_updates_every_global_package() (
    create_fixture
    enable_tools npm
    MOCK_NPM_GLOBALS='corepack npm @example/public'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'npm update --global --no-audit --no-fund corepack npm @example/public' || exit
    assert_not_contains "$RUN_CALLS" 'npm install --global' || exit
    assert_not_contains "$RUN_CALLS" '--registry=' || exit
)

test_npm_uses_private_registry_and_extra_args() (
    create_fixture
    write_private_npm_config
    enable_tools npm
    MOCK_NPM_GLOBALS='corepack npm @example/cli @example/strict'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'npm update --global --no-audit --no-fund corepack npm' || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund @example/cli --registry=https://registry.example.com/npm' || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund --engine-strict @example/strict --registry=https://registry.example.com/npm' || exit
)

test_npm_without_global_packages_installs_private_packages() (
    create_fixture
    write_private_npm_config ''
    enable_tools npm
    MOCK_NPM_GLOBALS=''
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_not_contains "$RUN_CALLS" 'npm update --global' || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund @example/cli' || exit
    assert_not_contains "$RUN_CALLS" '--registry=' || exit
)

test_missing_private_packages_are_installed() (
    create_fixture
    write_private_npm_config
    enable_tools npm
    MOCK_NPM_GLOBALS='corepack npm'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund @example/cli --registry=https://registry.example.com/npm' || exit
)

# 私有 scope 下已装的其余包走私有 registry 更新，公网包仍走普通 npm update。
test_private_scope_packages_use_private_registry() (
    create_fixture
    write_private_npm_config
    enable_tools npm
    MOCK_NPM_GLOBALS='corepack @example/other @public/thing'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'npm update --global --no-audit --no-fund corepack @public/thing' || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund @example/other --registry=https://registry.example.com/npm' || exit
)

# scope 只影响「已装的怎么更新」，不代表「缺了要装」——那是必备清单的职责。
test_private_scope_member_is_not_installed_when_missing() (
    create_fixture
    write_private_npm_config
    enable_tools npm
    MOCK_NPM_GLOBALS='corepack'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_not_contains "$RUN_CALLS" '@example/other' || exit
)

test_npm_ls_nonzero_with_usable_output_is_tolerated() (
    create_fixture
    enable_tools npm
    MOCK_NPM_LS_STATUS='1'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'npm update --global --no-audit --no-fund corepack npm' || exit
    assert_not_contains "$RUN_OUTPUT" '无法枚举 npm 全局包' || exit
)

test_npm_enumeration_failure_still_installs_private_packages() (
    create_fixture
    write_private_npm_config
    enable_tools npm
    MOCK_NPM_GLOBALS=''
    MOCK_NPM_LS_STATUS='1'
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '无法枚举 npm 全局包' || exit
    assert_contains "$RUN_CALLS" 'npm install --global --no-audit --no-fund @example/cli --registry=https://registry.example.com/npm' || exit
)

test_pnpm_corepack_shim_probe_failure_is_skipped() (
    create_fixture
    enable_tools pnpm
    MOCK_PNPM_ROOT=''
    MOCK_PNPM_ROOT_STATUS='1'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'pnpm root --global [COREPACK_ENABLE_NETWORK=0] [COREPACK_ENABLE_DOWNLOAD_PROMPT=0]' || exit
    assert_not_contains "$RUN_CALLS" 'pnpm update' || exit
    assert_contains "$RUN_OUTPUT" 'corepack shim' || exit
)

test_pnpm_without_global_manifest_is_skipped() (
    create_fixture
    enable_tools pnpm
    MOCK_PNPM_ROOT="$FIXTURE_DIR/pnpm-empty/node_modules"
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_not_contains "$RUN_CALLS" 'pnpm update' || exit
    assert_contains "$RUN_OUTPUT" '没有 pnpm 全局包' || exit
)

test_pnpm_update_disables_corepack_prompt() (
    create_fixture
    enable_tools pnpm
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'pnpm update --global --latest [COREPACK_ENABLE_NETWORK=] [COREPACK_ENABLE_DOWNLOAD_PROMPT=0]' || exit
)

test_bun_without_global_manifest_is_safe() (
    create_fixture
    enable_tools bun
    MOCK_BUN_NO_MANIFEST='1'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_not_contains "$RUN_CALLS" 'bun update --global' || exit
)

run_test node 'no config updates every global package' test_npm_without_config_updates_every_global_package
run_test node 'npm uses private registry and extra args' test_npm_uses_private_registry_and_extra_args
run_test node 'npm without globals installs private packages' test_npm_without_global_packages_installs_private_packages
run_test node 'missing private packages are installed' test_missing_private_packages_are_installed
run_test node 'private scope packages use private registry' test_private_scope_packages_use_private_registry
run_test node 'private scope member is not installed when missing' test_private_scope_member_is_not_installed_when_missing
run_test node 'npm ls nonzero with output is tolerated' test_npm_ls_nonzero_with_usable_output_is_tolerated
run_test node 'npm enumeration failure still installs private packages' test_npm_enumeration_failure_still_installs_private_packages
run_test node 'pnpm corepack shim probe failure is skipped' test_pnpm_corepack_shim_probe_failure_is_skipped
run_test node 'pnpm without global manifest is skipped' test_pnpm_without_global_manifest_is_skipped
run_test node 'pnpm update disables corepack prompt' test_pnpm_update_disables_corepack_prompt
run_test node 'Bun missing manifest is safe' test_bun_without_global_manifest_is_safe
