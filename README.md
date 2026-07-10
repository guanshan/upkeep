# upkeep

![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)
![shell](https://img.shields.io/badge/shell-bash-4EAA25)
![license](https://img.shields.io/badge/license-MIT-green)

One command to keep every local package manager on macOS and Linux up to date. `upkeep` detects the OS, updates whatever toolchains are installed, skips whatever is missing, and prints a single done / skipped / failed summary at the end.

**English** | [中文](#中文)

## Install

```bash
git clone https://github.com/guanshan/upkeep.git && cd upkeep
make doctor   # read-only health check of your tools and environment first
make update   # run the updates
```

No extra dependencies — just `bash` + `make`. Every step is optional: a tool that is not installed is reported as *skipped*, never as a failure.

## Usage

```bash
make update        # run every update
make update-help   # print the update scope and safety boundaries (default target)
make doctor        # read-only health check; verifies real tool contracts, changes nothing
make clean-docker  # prune Docker build cache and dangling images
make test-update   # run the updater test suite
make test          # run all tests
```

## What it updates

**System packages (per platform)**

- **macOS** — Homebrew formulae and casks. No automatic `cleanup`; running cask apps are not force-quit.
- **Linux** — DNF system packages. No `autoremove`.
- **Other OSes** — refused up front with an unsupported-platform error.

**Cross-platform tools** (each updated only when its command is found)

- npm, pnpm and Bun global packages. pnpm is probed with the network and prompt disabled first, so an inactive Corepack shim (or a shim with no global packages) is skipped instead of triggering an interactive download.
- pipx-managed Python CLIs.
- uv, and the tools uv manages.
- rustup toolchains.
- Cargo global installs (requires `cargo-update`; if absent the step is skipped with a hint — nothing is compiled implicitly).
- gems in the RubyGems user directory (the user dir is resolved via `ruby -e 'Gem.user_dir'`, which works on macOS's bundled RubyGems 3.0; skipped when no usable ruby is found).

npm tolerates a non-zero exit from `npm ls` (extraneous/invalid trees) as long as the output is usable; even if enumeration fails outright, configured private packages are still (re)installed.

**Private npm packages** — private packages are opt-in and configured outside the repository. Copy [`config.example.sh`](config.example.sh) to `~/.config/upkeep/config.sh`, or set `UPKEEP_CONFIG` to another path. Each `PRIVATE_NPM_PACKAGES` item is either `package-name` or `package-name|extra npm install arguments`; the latter can add flags such as `--engine-strict`. Explicitly listed packages are always installed or updated through `PRIVATE_NPM_REGISTRY` when it is set. Every other enumerated global package uses the configured public npm registry through `npm update -g`. The shipped default is empty and contains no site-specific values.

**uv self-update** — when uv's GitHub-API self-update is rate-limited, it falls back to `https://astral.sh/uv/install.sh`, and skips the reinstall when already on the target version. When uv is managed by Homebrew (or another external package manager), the system-package step owns the uv update and the uv step only updates uv's tools.

## Python strategy

- **macOS** — checks the current `python3` for outdated packages, preferring a writable install dir, then the user site; if neither is usable it skips (never uses sudo). A PEP 668 environment is recorded as *skipped* (a property of the environment, not a failure) and `--break-system-packages` is never used.
- **Linux** — updates only the top-level, non-editable outdated packages in the currently activated virtualenv, then runs `pip check`. With no virtualenv active, the system pip is never touched.
- **pipx** — on macOS it is installed via Homebrew when missing; on Linux only an already-installed pipx is updated.

## Docker cleanup

`make clean-docker` runs `docker builder prune --all` (all unused build cache) and `docker image prune` (dangling, untagged images only), printing a `docker system df` before/after. Tagged images, containers, volumes and networks are left untouched.

## Safety boundaries

- Never modifies sub-project dependencies or lockfiles.
- Never runs `npm audit fix --force`, `autoremove`, or Homebrew `cleanup`.
- Never bypasses PEP 668, never bulk-updates the Linux system Python or root global pip packages, and never uses sudo for any Python package.
- sudo is used only for a validated absolute executable path (currently DNF only) — never for RubyGems or pip.
- The concurrency lock prefers `flock` (released by the kernel on exit, so Ctrl-C / kill leave nothing behind); on macOS without flock it falls back to a mkdir lock with PID stale-lock reclaim and signal cleanup, and prints the lock path on contention.
- When `NODE_TLS_REJECT_UNAUTHORIZED=0` is detected, TLS verification is restored for the duration of this run only.
- Steps keep going after a failure; the run reports the failure in the summary and exits non-zero.

Tests use mock commands to cover the macOS / Linux branches, missing tools, failure aggregation and the safety boundaries — they never touch real system packages. Mocks cannot verify real tool contracts (a RubyGems 3.0 incompatibility slipped through once), so run `make doctor` after switching machines or a major version bump.

---

# 中文

![平台](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)
![shell](https://img.shields.io/badge/shell-bash-4EAA25)
![许可证](https://img.shields.io/badge/license-MIT-green)

一条命令让 macOS 与 Linux 上的本地包管理器全部保持最新。`upkeep` 自动识别操作系统，只更新已安装的工具链，缺失的自动跳过，并在结束时汇总完成 / 跳过 / 失败。

[English](#upkeep) | **中文**

## 安装

```bash
git clone https://github.com/guanshan/upkeep.git && cd upkeep
make doctor   # 先只读体检，确认工具与环境
make update   # 执行更新
```

无需额外依赖：纯 `bash` + `make`。每一步都是可选的——未安装的工具记为「跳过」，不会算作失败。

## 用法

```bash
make update        # 执行全部更新
make update-help   # 查看更新范围与安全边界（默认目标）
make doctor        # 只读体检：核对真实工具契约与环境，不修改任何状态
make clean-docker  # 清理 Docker 构建缓存与悬空镜像
make test-update   # 运行更新脚本测试
make test          # 运行全部测试
```

## 更新范围

**系统包（按平台）**

- **macOS** —— 更新 Homebrew formula 与 cask，不自动执行 cleanup，不强制退出正在运行的 cask 应用。
- **Linux** —— 用 DNF 更新系统软件包，不执行 autoremove。
- **其他系统** —— 在更新开始前返回不支持错误。

**跨平台工具**（检测到对应命令时才更新）

- npm、pnpm 与 Bun 全局包。pnpm 会先禁网禁提示探测，未激活的 Corepack shim（或没有全局包的 shim）会跳过，不触发交互式下载。
- pipx 管理的 Python 命令行工具。
- uv 与 uv 管理的工具。
- rustup 工具链。
- Cargo 全局安装包（需已装 `cargo-update`，缺失时跳过并提示，不隐式编译安装）。
- RubyGems 用户目录中的 gem（用户目录通过 `ruby -e 'Gem.user_dir'` 解析，兼容 macOS 系统自带的 RubyGems 3.0；缺可用 ruby 时跳过）。

npm 枚举全局包时容忍 `npm ls` 的非零退出（extraneous/invalid 树），只要输出可用就继续；即使枚举失败，也会继续安装或更新配置的私有包。

**私有 npm 包** —— 私有包为可选能力，配置保存在仓库外。可将 [`config.example.sh`](config.example.sh) 复制到 `~/.config/upkeep/config.sh`，也可通过 `UPKEEP_CONFIG` 指定其他路径。`PRIVATE_NPM_PACKAGES` 的每一项格式为 `package-name` 或 `package-name|额外的 npm install 参数`，后者可附加 `--engine-strict` 等参数。显式列出的包始终安装或更新；`PRIVATE_NPM_REGISTRY` 非空时使用该 registry。其余枚举到的全局包通过 `npm update -g` 使用 npm 当前配置的公开 registry。仓库默认配置为空，不包含站点特定值。

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
- sudo 只用于经过校验的绝对可执行路径（目前仅 DNF），不用于 RubyGems 与 pip。
- 并发锁优先使用 `flock`（内核在进程退出时自动释放，Ctrl-C / kill 不残留）；无 flock 的 macOS 回退 mkdir 目录锁，带 PID 陈锁自愈与信号清理，报错时给出锁路径。
- 检测到 `NODE_TLS_REJECT_UNAUTHORIZED=0` 时，仅在当前更新进程内恢复 TLS 证书校验。
- 单个步骤失败后继续执行剩余步骤；最终汇总失败，并以非零状态退出。

测试用 mock 命令覆盖 macOS / Linux 分支、缺失工具、失败汇总和安全边界，不会更新真实系统包。mock 验证不了真实工具契约（历史上曾漏掉 RubyGems 3.0 的兼容问题），换机器或大版本升级后先跑 `make doctor`。
