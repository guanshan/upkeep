# 故障排查

按现象查处理办法。出现任何异常，先跑 `make doctor`——它只读，不改任何状态，多数问题在输出里能直接定位。

## 先分清跳过与失败

汇总里的三种状态含义不同，「跳过」不是故障：

- **跳过**：环境不具备该条件。工具没装、PEP 668 保护、corepack shim 未激活都属于这一类，不计入失败，整体退出码仍是 0。
- **完成**：执行成功，括号里可能附带补充说明，例如「没有过期的用户 gem」。
- **失败**：命令返回非 0。整体以非 0 退出，但其余步骤已经继续跑完。

## 已有更新任务正在运行

报错里会给出锁路径。先确认确实没有 upkeep 在跑：

```bash
ps aux | grep update-local-packages
```

确认无进程后删除锁：

```bash
rm -rf ~/.local/state/upkeep/upkeep-$UID.lock
```

正常退出和 Ctrl-C 都不会留下锁。macOS 上只有 `kill -9` 才可能残留——那条路径用的是 `mkdir` 目录锁，来不及执行清理。Linux 上用的是内核 `flock`，进程消失锁即释放，不存在残留。`make doctor` 的「并发锁」一节会直接报告是否有残留。

## pnpm 步骤被跳过

提示「pnpm 不可用（可能是未激活的 corepack shim）」。`command -v pnpm` 命中的是 Corepack 的 shim，但对应版本还没下载到本地缓存。

脚本刻意不替它下载：探测时会关掉网络和下载提示，避免 `make update` 卡在交互式确认上。需要真正启用时手动执行一次：

```bash
corepack prepare pnpm@latest --activate
```

若本来就不用 pnpm，这个跳过可以忽略。

## Python 包步骤被跳过

提示「PEP 668 保护当前 Python 环境」。这是环境属性，不是故障。脚本不会使用 `--break-system-packages`，也不会用 sudo 装 Python 包。

按用途选一条路：

- 命令行工具交给 pipx 或 uv 管理，它们各自有独立步骤。
- 项目依赖放进虚拟环境。Linux 上激活 venv 后再跑 `make update`，脚本会更新该环境的顶层过期包并执行 `pip check`。

另一种跳过提示是「pip 安装目录不可写且用户 site 不可用」，同样不会退化成 sudo，需要手动确认 Python 安装方式是否符合预期。

## uv 自更新失败

三种情况，汇总里的说明文本可以区分：

- 「uv 由 Homebrew 管理，自更新由 Homebrew 步骤负责」：预期行为，uv 的版本更新在系统包阶段完成，uv 步骤只更新它管理的工具。
- 「uv 已是最新版 x.y.z（GitHub API 受限，无需重装）」：本机出口 IP 的 GitHub 匿名 API 限额打满，但当前已是目标版本，无需处理。
- 「GitHub API 受限，已改用安装脚本更新 uv」：已自动回退到 `https://astral.sh/uv/install.sh` 直链重装，等价于自更新。

只有在没有 curl、或安装脚本本身失败时才会记为失败。

## Cargo 步骤被跳过

提示「未安装 cargo-update」。更新 Cargo 全局包需要 `cargo-install-update` 这个辅助工具，而安装它要编译数分钟。更新脚本不做这种隐式的长时间编译，需要时手动装一次：

```bash
cargo install cargo-update
```

装完之后该步骤自动生效。

## Cargo 步骤报「unexpected argument '--all' found」

cargo-update 22.x 起，直接执行 `cargo-install-update --all` 会失败：该二进制的顶层解析器仍要求 `install-update` 子命令。正确写法是经 cargo 分发：`cargo install-update --all`。

这个问题在 2026-09-21 修复前一直存在，且 mock 测试全绿——测试里 helper 是假的，而 doctor 当时只检查了命令是否存在，没核对调用契约。现在 doctor 会实际探测 `cargo install-update --help` 是否接受 `--all`，换机器或 cargo-update 大版本升级后先跑一次即可发现同类问题。

## RubyGems 步骤被跳过

提示「无法确定 RubyGems 用户目录（缺少可用的 ruby）」。用户目录是通过 `ruby -e 'Gem.user_dir'` 解析的。

这里有过一次教训：早期版本用 `gem env user_gemhome`，该子命令需要 RubyGems 3.2 以上，而 macOS 系统自带的是 3.0，mock 测试全绿但真机报错。`make doctor` 就是为补上这类「假设与真实工具不一致」的检查而加的，换机器或大版本升级后先跑一次。

## 系统包步骤失败

**macOS。** `brew update` 或 `brew upgrade` 的报错会原样打印。脚本不执行 `brew cleanup`，也不强制退出正在运行的 cask 应用，因此某些 cask 会因为应用正在运行而升级失败，关掉应用重跑即可。

**Linux。** 先看 `make doctor` 的「系统包管理器」一节确认识别到的是 dnf 还是 apt-get；两者都没有时该步骤跳过。非 root 且没有 sudo 会直接失败。

apt 路径上有两个刻意的约束：更新时保留本机已改过的配置文件（`--force-confold`），并且不自动重启服务（`NEEDRESTART_MODE=l` 只列出）。因此升级后可能需要手动重启相关服务，或者重启机器。如果报错提示需要卸载软件包才能升级，那是 `--no-remove` 在起作用——脚本不会替人做卸载决定，需要手动处理。

## 私有包没有按预期更新

先跑 `make doctor`，「站点配置」一节会直接给出实际加载了哪个文件、registry 与包清单。常见情况：

- **显示「未加载站点配置」**：三个来源都没命中。检查 `~/.config/upkeep/config.sh` 是否存在，或仓库根目录有没有 `config.sh`（开源版默认没有，需要从 `config.example.sh` 复制）。
- **加载的不是预期的那个文件**：查找顺序是 `$UPKEEP_CONFIG` > 用户级配置 > 仓库内 `config.sh`，命中即止。常见原因是 shell 里残留了 `UPKEEP_CONFIG` 导出，或用户级配置盖住了仓库里的。
- **包更新了但没走私有 registry**：`PRIVATE_NPM_REGISTRY` 留空时使用 npm 当前配置的默认 registry。另外 `PRIVATE_NPM_SCOPES` 只影响「已装的怎么更新」，缺失的包不会因为 scope 匹配就被安装——那是 `PRIVATE_NPM_PACKAGES` 的职责。

临时不加载任何站点配置：

```bash
UPKEEP_CONFIG= make update
```

## 站点配置报错

- **「UPKEEP_CONFIG 指向的配置不存在」**：显式指定的路径必须存在。这里刻意不静默回退，避免路径笔误表现为「跑完了但私有包没动」。
- **「PRIVATE_NPM_REGISTRY 必须是 http(s) 地址」**：只接受 `http://` 或 `https://` 开头，留空表示用 npm 默认 registry。
- **「PRIVATE_NPM_SCOPES 每项应形如 @scope」**：写 `@acme`，不是 `acme`，也不带 `/`。
- **「PRIVATE_NPM_PACKAGES 包名无效」**：每项格式为「包名」或「包名|额外的 npm install 参数」，竖线后面才是参数。

## npm 相关

**枚举失败仍在装私有包。** 全局树里有 extraneous 或 invalid 的包时 `npm ls` 会非零退出。只要输出可用就继续；即使完全不可用，必备的私有 CLI 也会独立补装，此时步骤记为失败并附说明。

**私有包拉取失败。** 私有包通常不在公网 npm 上，走的是 `PRIVATE_NPM_REGISTRY` 指定的镜像。先用 `make doctor` 确认加载的是哪份配置、registry 是否正确，再检查该 registry 本身是否可达（例如是否需要先连上对应网络）。

**TLS 警告。** 检测到 `NODE_TLS_REJECT_UNAUTHORIZED=0` 时会打印警告并在本次运行内恢复证书校验，只影响当前进程，不改 shell 配置。

## make test 有用例跳过

macOS 上会看到两条：

```
SKIP [lock] flock mode is used when available（宿主机没有 flock）
SKIP [lock] flock mode rejects concurrent run（宿主机没有 flock）
```

`flock` 是 Linux 自带、macOS 没有的命令，内核锁行为无法在 macOS 上模拟，因此跳过而不是失败。这两个用例由 GitLab 流水线在 Linux 上执行。

## make lint 报格式问题

`make fmt` 就地修复，再跑一次 `make lint`。缺少 shfmt 时格式检查会告警跳过，不阻断；缺少 shellcheck 则直接失败——静态检查缺位时宁可让 lint 红，也不静默放行。
