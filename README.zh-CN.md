# upkeep

![平台](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)
![shell](https://img.shields.io/badge/shell-bash-4EAA25)
![许可证](https://img.shields.io/badge/license-MIT-green)

一条命令让 macOS 与 Linux 上的本地包管理器全部保持最新。`upkeep` 自动识别操作系统，只更新已安装的工具链，缺失的自动跳过，并在结束时汇总完成 / 跳过 / 失败。

[English](README.md) | **中文**

## 安装

```bash
git clone https://github.com/guanshan/upkeep.git && cd upkeep
make doctor   # 先只读体检，确认工具与环境
make update   # 执行更新
```

纯公网环境无需任何额外配置。要把某个私有 scope 固定到内部 registry，见 [站点配置](#站点配置)。

无需额外依赖：纯 `bash` + `make`。每一步都是可选的——未安装的工具记为「跳过」，不会算作失败。

## 用法

```bash
make update        # 执行全部更新
make update-help   # 查看更新范围与安全边界（默认目标）
make doctor        # 只读体检：核对真实工具契约与环境，不修改任何状态
make clean-docker  # 清理 Docker 构建缓存与悬空镜像
make test-update   # 运行更新脚本测试
make test          # 运行全部测试
make lint          # shellcheck 静态检查 + shfmt 格式检查
make fmt           # 用 shfmt 就地修复格式
```

## 站点配置

私有 registry 与内部 CLI 放在配置文件里，不进脚本。复制模板后按需修改：

```bash
cp config.example.sh ~/.config/upkeep/config.sh
```

```bash
PRIVATE_NPM_REGISTRY='https://registry.example.com/npm'   # 留空则用 npm 当前配置的默认 registry
PRIVATE_NPM_SCOPES=('@acme')                              # 这些 scope 下已装的包改走该 registry 更新
PRIVATE_NPM_PACKAGES=('@acme/cli' '@acme/strict|--engine-strict')  # 必备 CLI，缺失时自动补装
```

查找顺序，命中即止：

| 来源 | 适用场景 |
| --- | --- |
| `UPKEEP_CONFIG=/path/to/config.sh` | 仅本次运行。设为空串（`UPKEEP_CONFIG=`）表示完全不加载站点配置。 |
| `$XDG_CONFIG_HOME/upkeep/config.sh` | 按用户，不进仓库。默认为 `~/.config/upkeep/config.sh`。 |
| 仓库根目录的 `config.sh` | 按 checkout，可提交给团队共用一份默认值。 |

`UPKEEP_CONFIG` 指向的文件不存在时直接报错，而不是静默回退——配置路径写错却被忽略，是最难排查的一类问题。`make doctor` 会打印实际加载了哪个文件以及它配了什么。

## 文档

- [架构说明](docs/architecture.md) —— 模块划分，以及入口脚本与 `lib/` 之间的共享状态契约。
- [扩展指南](docs/adding-a-step.md) —— 步骤函数的契约、sudo 约束，以及怎么给新步骤补 mock 测试。
- [故障排查](docs/troubleshooting.md) —— 锁残留、corepack shim 未激活、PEP 668、uv 限流、RubyGems、apt 服务重启。
- [设计决策](docs/decisions.md) —— 不用 `sudo pip`、不执行 autoremove、不隐式编译等安全边界背后的取舍。

## 更新范围

**系统包（按平台）**

- **macOS** —— 更新 Homebrew formula 与 cask，不自动执行 cleanup，不强制退出正在运行的 cask 应用。
- **Linux** —— 用 DNF 更新系统软件包；Debian/Ubuntu 改用 apt-get，两者并存时 dnf 优先。不执行 autoremove，也不用 dist-upgrade；apt 路径保留本机已改过的配置文件（`--force-confold`），并且只列出需要重启的服务而不自动重启（`NEEDRESTART_MODE=l`）。
- **其他系统** —— 在更新开始前返回不支持错误。

**跨平台工具**（检测到对应命令时才更新）

- npm、pnpm 与 Bun 全局包。pnpm 会先禁网禁提示探测，未激活的 Corepack shim（或没有全局包的 shim）会跳过，不触发交互式下载。
- pipx 管理的 Python 命令行工具。
- uv 与 uv 管理的工具。
- rustup 工具链。
- Cargo 全局安装包（需已装 `cargo-update`，缺失时跳过并提示，不隐式编译安装）。
- RubyGems 用户目录中的 gem（用户目录通过 `ruby -e 'Gem.user_dir'` 解析，兼容 macOS 系统自带的 RubyGems 3.0；缺可用 ruby 时跳过）。

npm 枚举全局包时容忍 `npm ls` 的非零退出（extraneous/invalid 树），只要输出可用就继续；即使枚举失败，也会独立补装必备的私有 CLI。

**私有 npm 包** —— 通过配置文件声明，不写在脚本里。见 [站点配置](#站点配置)。

**uv 自更新** —— uv 通过 GitHub API 自更新受限时，自动改用 `https://astral.sh/uv/install.sh`，当前已是目标版本则跳过重装。uv 由 Homebrew（或其他外部包管理器）管理时，系统包阶段负责更新 uv，uv 阶段只更新其管理的工具。

## Python 策略

- **macOS** —— 检查当前 `python3` 的过期包，优先用可写安装目录，其次用户 site；两者都不可用则跳过，不使用 sudo。检测到 PEP 668 时该步骤记为「跳过」（环境属性而非故障），绝不使用 `--break-system-packages`。
- **Linux** —— 仅更新当前已激活虚拟环境中的顶层、非 editable 过期包，并在更新后执行 `pip check`。未激活虚拟环境时不调用系统 pip。
- **pipx** —— macOS 缺失时优先通过 Homebrew 安装；Linux 只更新已安装的 pipx。

## Docker 清理

`make clean-docker` 执行 `docker builder prune --all`（全部未使用的构建缓存）和 `docker image prune`（仅无标签的悬空镜像），前后打印 `docker system df` 对比。不删除有标签的镜像、容器、卷和网络。

## 安全边界

- 不修改子项目依赖或 lockfile。
- 不执行 `npm audit fix --force`、autoremove 或 Homebrew cleanup。
- 不绕过 PEP 668，不批量更新 Linux 系统 Python 或 root 全局 pip 包；不使用 sudo 更新任何 Python 包。
- sudo 只用于经过校验的绝对可执行路径（仅系统包管理器），不用于 RubyGems 与 pip；需要的环境变量按 `--preserve-env=` 白名单逐个透传，不整体放行。
- 并发锁优先使用 `flock`（内核在进程退出时自动释放，Ctrl-C / kill 不残留）；无 flock 的 macOS 回退 mkdir 目录锁，带 PID 陈锁自愈与信号清理，报错时给出锁路径。
- 检测到 `NODE_TLS_REJECT_UNAUTHORIZED=0` 时，仅在当前更新进程内恢复 TLS 证书校验。
- 单个步骤失败后继续执行剩余步骤；最终汇总失败，并以非零状态退出。

## 开发

`make lint` 执行 shellcheck（硬性要求）与 shfmt（缺失时告警跳过），`make fmt` 就地修复格式。测试按域分组放在 `scripts/tests/cases/` 下，可以只跑一组：`TEST_FILTER=node make test-update`。`.gitlab-ci.yml` 在每次推送时跑 lint、测试，以及一个仅供参考的 `doctor` 任务。

测试用 mock 命令覆盖 macOS / Linux 分支、缺失工具、失败汇总和安全边界，不会更新真实系统包。其中两个内核锁用例依赖 macOS 不带的 `flock`，本地会跳过，只在 Linux 流水线上执行。

mock 验证不了真实工具契约（历史上曾漏掉 RubyGems 3.0 的兼容问题），换机器或大版本升级后先跑 `make doctor`。apt 路径目前只有 mock 测试覆盖，尚未在真实 Debian/Ubuntu 机器上验证过，首次使用前先在该机器上跑一次 `make doctor`。
