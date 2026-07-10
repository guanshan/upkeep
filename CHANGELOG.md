# Changelog

本项目所有值得注意的变更都会记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- `make update`：跨平台一键更新，自动识别 macOS / Linux，汇总各步骤的完成、跳过与失败状态。
  - 系统包：macOS 走 Homebrew（formula + cask），Linux 走 DNF。
  - 跨平台工具：npm、pnpm、Bun、pipx、uv、rustup、Cargo、RubyGems，以及平台对应的 Python 策略。
- `make doctor`：只读环境体检，核对真实工具契约（corepack shim 激活状态、PEP 668、RubyGems 用户目录、uv 安装方式、并发锁状态等）。
- `make clean-docker`：清理 Docker 构建缓存与悬空镜像，前后对比磁盘占用。
- 并发锁：优先 `flock`（内核在进程退出时自动释放），无 flock 时回退 mkdir 原子锁，带 PID 陈锁自愈与信号清理。
- 测试套件：基于 mock 命令覆盖 macOS / Linux 分支、缺失工具、失败汇总与安全边界。
- GitHub Actions CI：在 Ubuntu 与 macOS 14 上运行完整测试，并通过 macOS 覆盖 Bash 3.2。

### Changed

- 更新脚本按职责拆分为入口 + `scripts/lib/` 下的 5 个模块（step-runner、lock、node-tools、python-tools、system-tools）。
- 私有 npm 包改为仓库外配置驱动，可通过 `~/.config/upkeep/config.sh` 或 `UPKEEP_CONFIG` 设置 registry、包名与额外安装参数。
- README 拆分为英文 `README.md` 与简体中文 `README.zh-CN.md`。

[Unreleased]: https://github.com/guanshan/upkeep/commits/main
