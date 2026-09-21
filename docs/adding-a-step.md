# 扩展指南：新增一个更新步骤

本文说明如何给 `make update` 加一个新的工具链更新步骤。前置阅读：[架构说明](architecture.md) 里的共享状态契约与步骤状态机。

## 步骤函数的契约

一个步骤函数不接收参数，不输出结构化结果，只需要做到三件事：

- 工具不存在时调用 `skip_step '未检测到 xxx'` 并返回。
- 成功时返回 0；有值得记录的补充信息时写入 `STEP_DETAIL`。
- 失败时返回非 0；尽量写入 `STEP_DETAIL` 说明原因，留空则汇总里只显示退出码。

骨架如下：

```bash
update_deno() {
    if ! command -v deno >/dev/null 2>&1; then
        skip_step '未检测到 Deno'
        return
    fi

    local installed
    installed="$(deno info --json 2>/dev/null)" || return 1
    if [[ -z "${installed//[[:space:]]/}" ]]; then
        STEP_DETAIL='没有 Deno 全局包'
        return 0
    fi
    deno upgrade
}
```

几条来自现有步骤的经验：

- `skip_step` 返回 0，所以 `skip_step '...'; return` 会带着 0 退出，跳过状态由 `STEP_SKIPPED` 表达，不要额外写 `return 1`。
- 需要多条子命令都执行完再汇总时，用 `local result=0` 累积，不要遇错即返回。`update_homebrew` 和 `update_apt` 都是这个写法。
- 判断字符串是否只有空白，用 `[[ -z "${value//[[:space:]]/}" ]]`，不要依赖外部命令。
- 探测某个工具是否可用时，如果探测本身可能触发交互式下载，先把网络和提示关掉再探。`update_pnpm` 对 corepack shim 就是这样处理的。

## 挂到编排里

在 `scripts/update-local-packages.sh` 的 `main()` 中加一行，并同步 `usage()` 里的更新范围说明：

```bash
run_step 'Deno 全局包' update_deno
```

标签会原样出现在汇总里，用「工具名 + 对象」的形式，与现有各行保持一致。

## 需要 sudo 的步骤

只有系统包管理器会用 sudo。`run_with_sudo` 只接受已确认存在的绝对可执行路径，这是刻意的限制，不要绕开：

```bash
local dnf_bin
dnf_bin="$(command -v dnf)" || { skip_step '未检测到 dnf'; return; }
run_with_sudo "$dnf_bin" upgrade --refresh --assumeyes --noautoremove
```

如果子进程必须拿到某些环境变量，用 `--preserve-env=` 前缀按白名单透传。sudo 默认 `env_reset` 会丢弃调用方环境，整体放行则失去了限制的意义：

```bash
DEBIAN_FRONTEND=noninteractive run_with_sudo \
    --preserve-env=DEBIAN_FRONTEND "$apt_bin" upgrade --assume-yes
```

RubyGems 和 pip 永远不走 sudo。相关取舍见 [设计决策](decisions.md)。

## 补测试

测试用 mock 命令驱动，不触碰真实包管理器，按域分成多个文件：

```
scripts/tests/update-local-packages.test.sh  # 入口，只负责加载与汇总
scripts/tests/lib/harness.sh                 # 计数器、断言、run_test
scripts/tests/lib/fixture.sh                 # 隔离的运行目录与调用封装
scripts/tests/fixtures/command-driver.sh     # mock 命令驱动
scripts/tests/cases/*.test.sh                # cli、config、lock、system、node、python、flow
```

1. **让 mock 认识新命令。** 在 `fixtures/command-driver.sh` 里给 `case "$name" in` 加分支，返回该工具的典型输出；需要观察环境变量时，在记录调用的那段 `printf` 里补一行。可调节的行为通过 `MOCK_*` 变量控制，在 `create_fixture` 里给默认值，并加进 `run_update` 的环境变量前缀列表。

2. **写用例。** 放进 `cases/` 下对应域的文件，没有合适的域就新建一个，并加进入口脚本的 `case_module` 列表。每个用例是一个子 shell（用 `(` 而非 `{`），这样 `create_fixture` 设的变量不会串到下一个用例：

```bash
test_deno_without_globals_is_reported() (
    create_fixture
    enable_tools deno
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '没有 Deno 全局包' || exit
)
```

3. **注册。** 在同一文件末尾加 `run_test node 'deno without globals is reported' test_deno_without_globals_is_reported`。第一个参数是域名，与文件名一致，`TEST_FILTER` 按它过滤。第四个参数可选，填一个命令名，宿主机缺少它时该用例跳过而不是失败——两个内核锁用例就是靠 `flock` 这个参数在 macOS 上跳过的。条件更复杂时，让用例自己 `return 77`（TAP/autotools 的跳过约定），执行器同样按跳过处理。

可用的断言：`assert_status`、`assert_nonzero`、`assert_contains`、`assert_not_contains`、`assert_equals`。`RUN_OUTPUT` 是脚本的合并输出，`RUN_CALLS` 是 mock 记录的调用流水，`RUN_STATUS` 是退出码。

覆盖面上至少要有：工具缺失时跳过、正常路径调用了预期命令、失败时汇总为失败且整体返回非 0。涉及安全边界的（不加某个危险参数、不走 sudo）用 `assert_not_contains` 明确钉住。

## 补 doctor

mock 测试验证的是「代码与自己的假设一致」，验证不了「假设与真实工具一致」。凡是依赖真实工具输出格式或命令契约的步骤，都要在 `scripts/doctor.sh` 里加一项只读检查，报告版本与关键前提。这条规则来自一次真实教训，见 [故障排查](troubleshooting.md) 里的 RubyGems 条目。

## 提交前

```bash
make lint   # shellcheck + shfmt
make test   # 全部 mock 测试
make doctor # 只读体检，确认新检查项的输出符合预期
```

三条都通过后再提交。`make fmt` 可以就地修复格式问题。
