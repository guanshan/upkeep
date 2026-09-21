#!/usr/bin/env bash

# apt 路径的真机契约验证。
#
# mock 测试验证不了这些：sudo 会不会接受 --preserve-env、debconf 会不会把无人值守的
# 升级卡住、--no-remove 与 force-confold 组合下真实升级能否完成。这里在一次性容器里
# 跑真实的 apt，逐条断言。
#
# 需要 Docker 与网络，因此不属于 make test，单独用 make verify-apt 触发。
# 容器是 --rm 的，不会改动宿主机任何状态。

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly SCRIPT_DIR REPO_DIR

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    printf '  PASS %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    printf '  FAIL %s\n' "$1" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_contains() {
    local content="$1" expected="$2" label="$3"
    if [[ "$content" == *"$expected"* ]]; then
        pass "$label"
    else
        fail "$label（输出里找不到：$expected）"
    fi
}

assert_not_contains() {
    local content="$1" unexpected="$2" label="$3"
    if [[ "$content" != *"$unexpected"* ]]; then
        pass "$label"
    else
        fail "$label（输出里出现了不该有的：$unexpected）"
    fi
}

# 容器内脚本：把 tzdata 降级制造真实待升级状态，再用被测脚本升回去。
# 选 tzdata 是因为它依赖简单，且升级时会触发 debconf 时区问答——正是要验证的那条路径。
container_script() {
    local mode="$1"
    cat <<CONTAINER
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends make sudo needrestart >/dev/null 2>&1

OLD="\$(apt-cache madison tzdata | awk '{print \$3}' | uniq | tail -1)"
NEW="\$(apt-cache madison tzdata | awk '{print \$3}' | uniq | head -1)"
if [ "\$OLD" = "\$NEW" ]; then
    echo 'PROBE-SKIP 仓库里只有一个 tzdata 版本，无法制造待升级状态'
    exit 0
fi
apt-get install -y -qq --allow-downgrades "tzdata=\$OLD" >/dev/null 2>&1 || {
    echo 'PROBE-SKIP tzdata 降级失败'
    exit 0
}
echo "PROBE-BEFORE \$(dpkg-query -W -f='\${Version}' tzdata)"

cp -r /src /work && rm -f /work/config.sh
# 清掉本脚本设的 DEBIAN_FRONTEND：必须由被测脚本自己透传，否则验证没有意义
unset DEBIAN_FRONTEND
if [ "$mode" = sudo ]; then
    useradd -m dev
    echo 'dev ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/dev
    chown -R dev /work
    su dev -c 'cd /work && make update'
else
    (cd /work && make update)
fi

echo "PROBE-AFTER \$(dpkg-query -W -f='\${Version}' tzdata)"
echo "PROBE-UPGRADABLE \$(apt list --upgradable 2>/dev/null | grep -c upgradable)"
CONTAINER
}

run_case() {
    local image="$1" mode="$2"
    printf '\n== %s（%s）==\n' "$image" "$mode"

    local output
    if ! output="$(container_script "$mode" |
        docker run -i --rm -v "$REPO_DIR:/src:ro" "$image" bash -s 2>&1)"; then
        fail "容器执行失败：$image/$mode"
        printf '%s\n' "$output" | tail -20 >&2
        return
    fi

    if [[ "$output" == *'PROBE-SKIP'* ]]; then
        printf '  SKIP %s\n' "$(printf '%s\n' "$output" | grep 'PROBE-SKIP')"
        return
    fi

    local before after
    before="$(printf '%s\n' "$output" | sed -n 's/^PROBE-BEFORE //p')"
    after="$(printf '%s\n' "$output" | sed -n 's/^PROBE-AFTER //p')"

    assert_contains "$output" 'Linux 系统软件包：完成' '系统包步骤汇总为完成'
    assert_contains "$output" '1 upgraded' '真实升级了一个软件包'

    if [[ -n "$before" && -n "$after" && "$before" != "$after" ]]; then
        pass "版本确实前进：$before -> $after"
    else
        fail "版本没有前进：${before:-?} -> ${after:-?}"
    fi
    assert_contains "$output" 'PROBE-UPGRADABLE 0' '升级后无残留待升级包'

    # debconf 若退化成交互式，会打印配置问答界面并卡住直到超时
    assert_not_contains "$output" 'Configuring tzdata' 'debconf 未进入交互式问答'
    assert_not_contains "$output" 'dist-upgrade' '未退化为 dist-upgrade'
    assert_not_contains "$output" 'autoremove' '未执行 autoremove'

    if [[ "$mode" == sudo ]]; then
        assert_not_contains "$output" 'sorry, you are not allowed to preserve the environment' \
            'sudo 接受了 --preserve-env'
    fi
}

main() {
    if ! command -v docker >/dev/null 2>&1; then
        printf '错误：未检测到 docker，无法执行 apt 真机验证。\n' >&2
        return 1
    fi
    if ! docker system df >/dev/null 2>&1; then
        printf '错误：docker daemon 不可访问。\n' >&2
        return 1
    fi

    printf 'apt 真机契约验证（一次性容器，不改动宿主机）\n'
    run_case debian:bookworm-slim root
    run_case ubuntu:24.04 sudo

    printf '\n%d 项通过，%d 项失败\n' "$PASS_COUNT" "$FAIL_COUNT"
    ((FAIL_COUNT == 0))
}

main "$@"
