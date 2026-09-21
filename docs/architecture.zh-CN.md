# 架构说明

*[English](architecture.md)*

upkeep 是一个入口脚本加五个 lib 模块的 Bash 程序。本文说明模块划分，以及模块之间靠全局变量通信的隐式约定——后者是改动时最容易破坏的部分。

## 文件布局

```
Makefile                      # 对外入口，所有命令的唯一来源
scripts/
  update-local-packages.sh    # make update：站点配置、共享状态声明、步骤编排
  doctor.sh                   # make doctor：只读体检，独立程序，不加载 lib
  clean-docker-cache.sh       # make clean-docker：独立程序，不加载 lib
  verify-apt-container.sh     # make verify-apt：容器里验证 apt 的真实契约
  lib/
    site-config.sh            # 站点配置：查找、加载与校验，doctor 也复用它
    step-runner.sh            # 步骤执行器：跳过标记、特权执行、结果汇总
    lock.sh                   # 并发锁：flock 优先，mkdir 回退
    node-tools.sh             # npm、pnpm、Bun
    python-tools.sh           # pipx、uv、pip、虚拟环境
    system-tools.sh           # 系统包、rustup、Cargo、RubyGems
  tests/
    update-local-packages.test.sh   # 测试入口：加载框架与夹具，按域执行用例
    clean-docker-cache.test.sh      # 独立测试，自带断言
    lib/harness.sh                  # 计数器、断言、用例执行器
    lib/fixture.sh                  # 隔离的运行目录与被测脚本的调用封装
    fixtures/command-driver.sh      # mock 命令驱动，独立成文件以纳入 shellcheck
    cases/*.test.sh                 # 按域分组的用例：cli、config、lock、system、node、python、flow
```

测试全部基于 mock 命令，不触碰真实包管理器。用 `TEST_FILTER` 只跑一个域，例如 `TEST_FILTER=node make test-update`。

`clean-docker-cache.sh` 完全独立，不加载任何 lib。`doctor.sh` 只加载 `site-config.sh` 一个模块：它不需要步骤编排和并发锁，但配置的查找顺序必须与 `make update` 完全一致，各写一份迟早漂移。

## 运行顺序

`update-local-packages.sh` 的 `main()` 是全部控制流：

1. `parse_args`：只接受 `--help` / `-h`，其余参数以状态码 2 退出。
2. `detect_platform`：`uname -s` 映射到 `PLATFORM`（`macos` 或 `linux`），其他系统直接失败退出。同时检测到 `NODE_TLS_REJECT_UNAUTHORIZED=0` 会就地恢复 TLS 校验。
3. `acquire_lock`：取得并发锁，失败则整体退出。
4. 依次 `run_step`：系统包按平台分流，其余工具链共用。
5. `print_summary`，并以失败计数决定退出码。

模块用一个 `for` 循环按固定顺序 source：`site-config`、`step-runner`、`lock`、`node-tools`、`python-tools`、`system-tools`。`site-config` 必须排在最前——它声明的 `PRIVATE_NPM_*` 会被 `node-tools` 读取；其余模块之间没有依赖顺序要求，但 `step-runner` 提供的原语被大家调用，排前面更直观。

配置的实际加载发生在 `main()` 里、`detect_platform` 之前：加载失败就整体退出，不做任何更新。

## 共享状态契约

模块不通过参数和返回值传递状态，而是读写入口脚本声明的一组全局变量。新增或修改模块时必须遵守下表。

| 变量 | 声明位置 | 写入方 | 读取方 |
| --- | --- | --- | --- |
| `PLATFORM` | 入口脚本 | `detect_platform` | `lock.sh`、`python-tools.sh` |
| `STEP_DETAIL` | 入口脚本 | 各步骤函数、`skip_step` | `run_step` |
| `STEP_SKIPPED` | 入口脚本 | `skip_step`、`run_step` | `run_step`、`update_pipx` |
| `RESULT_LABELS` / `RESULT_STATES` / `RESULT_DETAILS` | 入口脚本 | `run_step` | `print_summary` |
| `FAILURE_COUNT` | 入口脚本 | `run_step` | `main` |
| `LOCK_PATH` / `LOCK_ACQUIRED` | 入口脚本 | `lock.sh` | `lock.sh` |
| `PIPX_RUNNER` | 入口脚本 | `ensure_pipx` | `update_pipx` |
| `PRIVATE_NPM_REGISTRY` / `PRIVATE_NPM_SCOPES` / `PRIVATE_NPM_PACKAGES` / `SITE_CONFIG_PATH` | `site-config.sh` | `load_site_config`（读站点配置文件） | `node-tools.sh`、`doctor.sh` |

这套设计的代价是静态检查看不出关联：shellcheck 逐文件分析，会把每一处 `STEP_DETAIL=` 报成「赋值后未使用」。项目根目录的 `.shellcheckrc` 因此统一关闭 SC2034 与 SC2153（后者是测试用例文件读取 `MOCK_*` 时的同类误报），并在文件内注明原因。

新增步骤的具体写法见 [扩展指南](adding-a-step.zh-CN.md)。

## 步骤状态机

`run_step` 把每个步骤函数的行为归到三种状态。判定顺序是先看 `STEP_SKIPPED`，再看退出码：

| 步骤函数的行为 | 汇总里的状态 |
| --- | --- |
| 调用 `skip_step '原因'` 后返回 | 跳过 |
| 返回 0 | 完成 |
| 返回非 0 | 失败，`FAILURE_COUNT` 加一 |

三点容易踩的地方：

- `skip_step` 自身返回 0，所以 `skip_step '未检测到 npm'; return` 这个惯用写法返回的是 0，靠 `STEP_SKIPPED` 而非退出码表达跳过。
- `run_step` 在调用步骤函数前会清空 `STEP_DETAIL` 和 `STEP_SKIPPED`，步骤函数不需要自己重置。
- 失败且 `STEP_DETAIL` 为空时，`run_step` 会补上「命令退出状态：N」，所以失败路径至少有一条可读说明。

「跳过」表示环境不具备该条件，不计入失败。工具未安装、PEP 668 保护、corepack shim 未激活都归到这一类，这是安全边界的一部分，而不是降级处理。

## 并发锁

`acquire_lock` 先用 `prepare_lock_directory` 选定目录（依次尝试 `XDG_RUNTIME_DIR`、`XDG_STATE_HOME/upkeep`、`$HOME/.local/state/upkeep`），校验属主与权限位后，再按宿主机能力二选一：

- 有 `flock`（Linux 自带）：用内核文件锁。进程无论以何种方式退出，内核都会释放，不残留。
- 无 `flock`（macOS）：回退 `mkdir` 原子目录锁，锁内写入 PID。发现锁时若 PID 已退出则自愈回收，并注册 `EXIT`、`INT`、`TERM`、`HUP` 清理。`kill -9` 仍可能残留，此时报错会给出锁路径。

两条路径的行为差异是平台能力决定的，不是可配置项。测试里的两个内核锁用例在没有 `flock` 的宿主机上会跳过，只有 Linux 上的流水线真正执行。

## Bash 3.2 约束

macOS 自带 bash 3.2，项目以此为下限，不使用更高版本的特性：

- 不用 `mapfile` / `readarray`，读取多行结果一律 `while IFS= read -r`。
- 不用关联数组，结果汇总用三个下标对齐的普通数组。
- `set -u` 下展开可能为空的数组要写成 `${arr[@]+"${arr[@]}"}`，直接写 `"${arr[@]}"` 会报未绑定变量。
- 不依赖 GNU 专属选项，例如 `readlink -f`、`stat -c` 在 macOS 上都不可用，需要分平台处理或改用纯 Bash 实现。
