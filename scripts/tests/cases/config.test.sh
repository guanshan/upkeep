#!/usr/bin/env bash
# 站点配置：查找顺序、优先级与校验。
# 由 update-local-packages.test.sh 加载，依赖 lib/harness.sh 与 lib/fixture.sh。

# 往夹具里写一份自定义配置并显式指向它。
write_config_at() {
    local path="$1"
    shift
    mkdir -p "${path%/*}"
    printf '%s\n' "$@" >"$path"
}

# 仓库自带 config.sh 时，不设任何环境变量也应当命中它——这正是「clone 下来即可用」。
# 公开仓库不提交 config.sh，此时跳过。
test_repo_config_is_used_when_nothing_else_is_set() (
    create_fixture
    [[ -f "$ROOT_DIR/config.sh" ]] || return 77
    # shellcheck disable=SC1091 # 路径在运行时才确定
    source "$ROOT_DIR/config.sh"
    ((${#PRIVATE_NPM_PACKAGES[@]} > 0)) || return 77
    local first_package="${PRIVATE_NPM_PACKAGES[0]%%|*}"

    enable_tools npm
    MOCK_NPM_GLOBALS=''
    unset TEST_UPKEEP_CONFIG
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" "npm install --global --no-audit --no-fund $first_package" || exit
)

test_user_config_overrides_repo_config() (
    create_fixture
    write_private_npm_config
    enable_tools npm
    MOCK_NPM_GLOBALS=''
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" '@example/cli --registry=https://registry.example.com/npm' || exit
)

test_explicit_upkeep_config_overrides_user_config() (
    create_fixture
    write_private_npm_config
    write_config_at "$FIXTURE_DIR/explicit.sh" \
        "PRIVATE_NPM_REGISTRY='https://registry.explicit.test/npm'" \
        "PRIVATE_NPM_PACKAGES=('@explicit/cli')"
    TEST_UPKEEP_CONFIG="$FIXTURE_DIR/explicit.sh"
    enable_tools npm
    MOCK_NPM_GLOBALS=''
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" '@explicit/cli --registry=https://registry.explicit.test/npm' || exit
    assert_not_contains "$RUN_CALLS" '@example/cli' || exit
)

# 配置路径写错却被静默忽略，是最难排查的一类问题，因此显式指定时必须报错。
test_missing_explicit_config_is_an_error() (
    create_fixture
    TEST_UPKEEP_CONFIG="$FIXTURE_DIR/does-not-exist.sh"
    enable_tools npm
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'UPKEEP_CONFIG 指向的配置不存在' || exit
    assert_not_contains "$RUN_CALLS" 'npm ' || exit
)

test_empty_upkeep_config_disables_site_config() (
    create_fixture
    write_config_at "$TEST_XDG_CONFIG_HOME/upkeep/config.sh" \
        "PRIVATE_NPM_REGISTRY='https://registry.example.com/npm'" \
        "PRIVATE_NPM_PACKAGES=('@example/cli')"
    TEST_UPKEEP_CONFIG=''
    enable_tools npm
    MOCK_NPM_GLOBALS=''
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_not_contains "$RUN_CALLS" '@example/cli' || exit
)

test_invalid_registry_is_rejected() (
    create_fixture
    write_config_at "$FIXTURE_DIR/bad.sh" "PRIVATE_NPM_REGISTRY='ftp://registry.example.com'"
    TEST_UPKEEP_CONFIG="$FIXTURE_DIR/bad.sh"
    enable_tools npm
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'PRIVATE_NPM_REGISTRY 必须是 http(s) 地址' || exit
)

test_invalid_private_package_name_is_rejected() (
    create_fixture
    write_config_at "$FIXTURE_DIR/bad.sh" "PRIVATE_NPM_PACKAGES=('not a package name')"
    TEST_UPKEEP_CONFIG="$FIXTURE_DIR/bad.sh"
    enable_tools npm
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'PRIVATE_NPM_PACKAGES 包名无效' || exit
)

test_invalid_private_scope_is_rejected() (
    create_fixture
    write_config_at "$FIXTURE_DIR/bad.sh" "PRIVATE_NPM_SCOPES=('acme')"
    TEST_UPKEEP_CONFIG="$FIXTURE_DIR/bad.sh"
    enable_tools npm
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'PRIVATE_NPM_SCOPES 每项应形如 @scope' || exit
)

run_test config 'repo config is used when nothing else is set' test_repo_config_is_used_when_nothing_else_is_set
run_test config 'user config overrides repo config' test_user_config_overrides_repo_config
run_test config 'explicit UPKEEP_CONFIG overrides user config' test_explicit_upkeep_config_overrides_user_config
run_test config 'missing explicit config is an error' test_missing_explicit_config_is_an_error
run_test config 'empty UPKEEP_CONFIG disables site config' test_empty_upkeep_config_disables_site_config
run_test config 'invalid registry is rejected' test_invalid_registry_is_rejected
run_test config 'invalid private package name is rejected' test_invalid_private_package_name_is_rejected
run_test config 'invalid private scope is rejected' test_invalid_private_scope_is_rejected
