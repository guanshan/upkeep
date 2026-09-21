# Changelog

本项目所有值得注意的变更都会记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- 站点配置外置：私有 registry、私有 scope 与必备私有 CLI 由 `config.sh` 声明，脚本内不再硬编码。
  查找顺序为 `$UPKEEP_CONFIG` > `$XDG_CONFIG_HOME/upkeep/config.sh` > 仓库内 `config.sh`；
  显式指定却不存在时报错而非静默回退。需要随仓库分发默认配置的部署可以提交 `config.sh`，clone 下来即可用。
- `PRIVATE_NPM_SCOPES`：整个 scope 下已安装的包改走私有 registry 更新（不会因缺失而安装）。
- `scripts/lib/site-config.sh`：配置的查找、加载与校验，由 `make update` 与 `make doctor` 共用。
- `make doctor` 新增「站点配置」一节，打印实际加载的配置路径与内容。
- `.github/workflows/ci.yml`：Ubuntu + macOS 矩阵。macOS runner 用系统自带 Bash 3.2 跑测试，
  并覆盖无 flock 时的 mkdir 目录锁回退——只有 Linux runner 的流水线测不到这两者。
- `make update`：跨平台一键更新，自动识别 macOS / Linux，汇总各步骤的完成、跳过与失败状态。
  - 系统包：macOS 走 Homebrew（formula + cask），Linux 走 DNF 或 apt-get（两者并存时 dnf 优先）。
  - 跨平台工具：npm、pnpm、Bun、pipx、uv、rustup、Cargo、RubyGems，以及平台对应的 Python 策略。
- Debian/Ubuntu 支持：apt 路径保留本机已改过的配置文件（`--force-confold`），不使用 dist-upgrade，并且只列出需要重启的服务而不自动重启（`NEEDRESTART_MODE=l`）。
- `run_with_sudo` 支持 `--preserve-env=` 白名单，按名字透传环境变量给特权进程，不整体放行。
- `make doctor`：只读环境体检，核对真实工具契约（corepack shim 激活状态、PEP 668、RubyGems 用户目录、uv 安装方式、并发锁状态等），并覆盖 apt 与 Docker 守护进程可达性。
- `make clean-docker`：清理 Docker 构建缓存与悬空镜像，前后对比磁盘占用。
- `make lint` / `make fmt`：shellcheck 静态检查与 shfmt 格式检查，配套根目录 `.shellcheckrc`。
- 并发锁：优先 `flock`（内核在进程退出时自动释放），无 flock 时回退 mkdir 原子锁，带 PID 陈锁自愈与信号清理。
- 测试套件：基于 mock 命令覆盖 macOS / Linux 分支、缺失工具、失败汇总与安全边界。
- `docs/`：架构说明、扩展指南、故障排查与设计决策四份文档。

### Changed

- README 拆分为 `README.md`（英文）与 `README.zh-CN.md`（中文），与开源版结构对齐。
- mock 命令驱动从 `lib/fixture.sh` 的 heredoc 提为独立文件 `tests/fixtures/command-driver.sh`，
  纳入 shellcheck 检查范围（提取当天即发现一条此前不可见的告警）。
- 测试支持 `UPDATE_BASH` 指定解释器，可在同一台机器上分别用 Bash 3.2 与 5.x 验证兼容性。
- 用例执行器同时支持两种跳过方式：注册时声明前置命令，或用例自身返回 77（TAP/autotools 约定）。
- 更新脚本按职责拆分为入口 + `scripts/lib/` 下的 5 个模块（step-runner、lock、node-tools、python-tools、system-tools）。
- Linux 系统包步骤改由 `update_linux_packages` 按发行版分流，汇总标签从「DNF 系统软件包」改为「Linux 系统软件包」。
- 更新脚本的测试从单个 996 行文件拆为入口 + `tests/lib/`（框架与夹具）+ `tests/cases/`（按域分组的用例）。
- 用例分组标签由 `task1`..`task4` 改为域名（`cli`、`lock`、`system`、`node`、`python`、`flow`），`TEST_FILTER` 随之按域过滤，例如 `TEST_FILTER=node make test-update`。

### Fixed

- 两个内核锁用例在没有 `flock` 的宿主机（macOS）上从失败改为跳过，`make test` 不再开箱即红。
- 移除 CHANGELOG 与 README 中的占位链接，指向真实仓库地址。

### Removed

- `docs/superpowers/`：一次性的实现计划与设计稿，内容已并入 `docs/` 下的常设文档。

[Unreleased]: https://github.com/guanshan/upkeep/commits/main
