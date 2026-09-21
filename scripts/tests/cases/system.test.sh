#!/usr/bin/env bash
# 系统包与语言工具链：Homebrew、DNF、apt、Cargo、RubyGems。
# 由 update-local-packages.test.sh 加载，依赖 lib/harness.sh 与 lib/fixture.sh。

test_darwin_uses_homebrew_not_dnf() (
    create_fixture
    STUB_UNAME='Darwin'
    enable_tools brew dnf
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'brew update' || exit
    assert_contains "$RUN_CALLS" 'brew upgrade --formula --no-ask' || exit
    assert_contains "$RUN_CALLS" 'brew upgrade --cask --no-ask' || exit
    assert_not_contains "$RUN_CALLS" 'dnf upgrade' || exit
)

test_linux_uses_dnf_not_homebrew() (
    create_fixture
    STUB_UNAME='Linux'
    MOCK_UID='0'
    enable_tools brew dnf
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'dnf upgrade --refresh --assumeyes --noautoremove' || exit
    assert_not_contains "$RUN_CALLS" 'brew update' || exit
)

test_non_root_linux_uses_sudo_for_dnf() (
    create_fixture
    STUB_UNAME='Linux'
    MOCK_UID='1000'
    enable_tools dnf sudo
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" "sudo -- $MOCK_BIN/dnf upgrade --refresh --assumeyes --noautoremove" || exit
)

test_linux_uses_apt_when_dnf_is_absent() (
    create_fixture
    STUB_UNAME='Linux'
    MOCK_UID='0'
    enable_tools apt-get
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'apt-get update' || exit
    assert_contains "$RUN_CALLS" 'apt-get upgrade --assume-yes --no-remove' || exit
    assert_not_contains "$RUN_CALLS" 'dist-upgrade' || exit
    assert_not_contains "$RUN_CALLS" 'autoremove' || exit
)

test_apt_keeps_local_config_and_defers_restarts() (
    create_fixture
    STUB_UNAME='Linux'
    MOCK_UID='0'
    enable_tools apt-get
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" '-o Dpkg::Options::=--force-confold' || exit
    assert_contains "$RUN_CALLS" '[DEBIAN_FRONTEND=noninteractive]' || exit
    assert_contains "$RUN_CALLS" '[NEEDRESTART_MODE=l]' || exit
)

test_non_root_apt_preserves_only_whitelisted_env() (
    create_fixture
    STUB_UNAME='Linux'
    MOCK_UID='1000'
    enable_tools apt-get sudo
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" \
        "sudo --preserve-env=DEBIAN_FRONTEND,NEEDRESTART_MODE -- $MOCK_BIN/apt-get update" || exit
)

test_dnf_wins_when_both_managers_exist() (
    create_fixture
    STUB_UNAME='Linux'
    MOCK_UID='0'
    enable_tools dnf apt-get
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'dnf upgrade' || exit
    assert_not_contains "$RUN_CALLS" 'apt-get' || exit
)

test_linux_without_system_manager_is_skipped() (
    create_fixture
    STUB_UNAME='Linux'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '未检测到受支持的系统包管理器' || exit
    assert_contains "$RUN_OUTPUT" 'Linux 系统软件包：跳过' || exit
)

test_cargo_without_helper_is_skipped() (
    create_fixture
    enable_tools cargo
    MOCK_CARGO_LIST=$'ripgrep v14.1.1:\n    rg\n'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_not_contains "$RUN_CALLS" 'cargo install cargo-update' || exit
    assert_contains "$RUN_OUTPUT" '未安装 cargo-update' || exit
)

test_cargo_updates_with_existing_helper() (
    create_fixture
    enable_tools cargo cargo-install-update
    MOCK_CARGO_LIST=$'ripgrep v14.1.1:\n    rg\n'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'cargo install-update --all' || exit
)

# 回归：cargo-update 22.x 起，直接执行 cargo-install-update 会把 --all 判为未知参数，
# 必须经 cargo 的子命令分发。
test_cargo_never_invokes_helper_binary_directly() (
    create_fixture
    enable_tools cargo cargo-install-update
    MOCK_CARGO_LIST=$'ripgrep v14.1.1:\n    rg\n'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_not_contains "$RUN_CALLS" 'cargo-install-update --all' || exit
)

test_cargo_update_failure_is_reported() (
    create_fixture
    enable_tools cargo cargo-install-update
    MOCK_CARGO_LIST=$'ripgrep v14.1.1:\n    rg\n'
    MOCK_CARGO_UPDATE_STATUS='2'
    run_update
    assert_nonzero "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" 'Cargo 全局包：失败' || exit
)

test_rubygems_uses_user_directory_without_sudo() (
    create_fixture
    enable_tools gem ruby sudo
    MOCK_GEM_OUTDATED='rake (3.0.0 < 3.1.0)'
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_CALLS" 'ruby -rrubygems' || exit
    assert_not_contains "$RUN_CALLS" 'gem env user_gemhome' || exit
    assert_contains "$RUN_CALLS" 'gem update --user-install --no-document' || exit
    assert_contains "$RUN_CALLS" "GEM_HOME=$FIXTURE_DIR/gems" || exit
    assert_not_contains "$RUN_CALLS" 'sudo -- gem' || exit
)

test_rubygems_without_usable_ruby_is_skipped() (
    create_fixture
    enable_tools gem
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '无法确定 RubyGems 用户目录' || exit
    assert_not_contains "$RUN_CALLS" 'gem outdated' || exit
)

run_test system 'Darwin uses Homebrew only' test_darwin_uses_homebrew_not_dnf
run_test system 'Linux uses DNF only' test_linux_uses_dnf_not_homebrew
run_test system 'non-root Linux uses sudo for DNF' test_non_root_linux_uses_sudo_for_dnf
run_test system 'Linux falls back to apt-get' test_linux_uses_apt_when_dnf_is_absent
run_test system 'apt keeps local config and defers restarts' test_apt_keeps_local_config_and_defers_restarts
run_test system 'non-root apt preserves whitelisted env only' test_non_root_apt_preserves_only_whitelisted_env
run_test system 'DNF wins over apt when both exist' test_dnf_wins_when_both_managers_exist
run_test system 'Linux without system manager is skipped' test_linux_without_system_manager_is_skipped
run_test system 'Cargo without helper is skipped' test_cargo_without_helper_is_skipped
run_test system 'Cargo updates with existing helper' test_cargo_updates_with_existing_helper
run_test system 'Cargo never invokes the helper binary directly' test_cargo_never_invokes_helper_binary_directly
run_test system 'Cargo update failure is reported' test_cargo_update_failure_is_reported
run_test system 'RubyGems uses user directory' test_rubygems_uses_user_directory_without_sudo
run_test system 'RubyGems without usable ruby is skipped' test_rubygems_without_usable_ruby_is_skipped
