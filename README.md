# upkeep

![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)
![shell](https://img.shields.io/badge/shell-bash-4EAA25)
![license](https://img.shields.io/badge/license-MIT-green)

One command to keep every local package manager on macOS and Linux up to date. `upkeep` detects the OS, updates whatever toolchains are installed, skips whatever is missing, and prints a single done / skipped / failed summary at the end.

**English** | [中文](README.zh-CN.md)

## Install

```bash
git clone https://github.com/guanshan/upkeep.git && cd upkeep
make doctor   # read-only health check of your tools and environment first
make update   # run the updates
```

No extra setup is needed for a public-network machine. To pin a private scope to an
internal registry, see [Site configuration](#site-configuration).

No extra dependencies — just `bash` + `make`. Every step is optional: a tool that is not installed is reported as *skipped*, never as a failure.

## Usage

```bash
make update        # run every update
make update-help   # print the update scope and safety boundaries (default target)
make doctor        # read-only health check; verifies real tool contracts, changes nothing
make clean-docker  # prune Docker build cache and dangling images
make test-update   # run the updater test suite
make test          # run all tests
make lint          # shellcheck + shfmt
make fmt           # rewrite files in place with shfmt
```

## Site configuration

Private registries and internal CLIs live in a config file, never in the scripts.
Copy the template and edit it:

```bash
cp config.example.sh ~/.config/upkeep/config.sh
```

```bash
PRIVATE_NPM_REGISTRY='https://registry.example.com/npm'   # empty = npm's default registry
PRIVATE_NPM_SCOPES=('@acme')                              # installed packages in these scopes update through that registry
PRIVATE_NPM_PACKAGES=('@acme/cli' '@acme/strict|--engine-strict')  # installed when missing
```

Lookup order, first match wins:

| Source | When to use |
| --- | --- |
| `UPKEEP_CONFIG=/path/to/config.sh` | One run only. `UPKEEP_CONFIG=` (empty) disables site config entirely. |
| `$XDG_CONFIG_HOME/upkeep/config.sh` | Per user, stays out of the repo. Defaults to `~/.config/upkeep/config.sh`. |
| `config.sh` in the repo root | Per checkout, can be committed so a team shares one default. |

A path given through `UPKEEP_CONFIG` that does not exist is an error rather than a
silent fallback — a typo in a config path is otherwise very hard to notice.
`make doctor` prints which file was loaded and what it configures.

## Docs

- [Architecture](docs/architecture.md) — module layout, and the shared-global contract between the entry script and `lib/`.
- [Adding a step](docs/adding-a-step.md) — the step function contract, sudo rules, and how to mock-test a new step.
- [Troubleshooting](docs/troubleshooting.md) — lock residue, inactive corepack shim, PEP 668, uv rate limits, RubyGems, apt restarts.
- [Design decisions](docs/decisions.md) — why no `sudo pip`, no `autoremove`, no implicit compiles, and the rest of the safety boundaries.

## What it updates

**System packages (per platform)**

- **macOS** — Homebrew formulae and casks. No automatic `cleanup`; running cask apps are not force-quit.
- **Linux** — DNF, or apt-get on Debian/Ubuntu (dnf wins when both exist). Neither `autoremove` nor `dist-upgrade`; apt keeps locally modified config files (`--force-confold`) and only lists services needing a restart instead of restarting them (`NEEDRESTART_MODE=l`).
- **Other OSes** — refused up front with an unsupported-platform error.

**Cross-platform tools** (each updated only when its command is found)

- npm, pnpm and Bun global packages. pnpm is probed with the network and prompt disabled first, so an inactive Corepack shim (or a shim with no global packages) is skipped instead of triggering an interactive download.
- pipx-managed Python CLIs.
- uv, and the tools uv manages.
- rustup toolchains.
- Cargo global installs (requires `cargo-update`; if absent the step is skipped with a hint — nothing is compiled implicitly).
- gems in the RubyGems user directory (the user dir is resolved via `ruby -e 'Gem.user_dir'`, which works on macOS's bundled RubyGems 3.0; skipped when no usable ruby is found).

npm tolerates a non-zero exit from `npm ls` (extraneous/invalid trees) as long as the output is usable; even if enumeration fails outright, required private CLIs are still (re)installed.

**Private npm packages** — configured, not hard-coded. See [Site configuration](#site-configuration).

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
- sudo is used only for a validated absolute executable path (system package managers only) — never for RubyGems or pip. Environment variables reach the privileged process through an explicit `--preserve-env=` allowlist, never wholesale.
- The concurrency lock prefers `flock` (released by the kernel on exit, so Ctrl-C / kill leave nothing behind); on macOS without flock it falls back to a mkdir lock with PID stale-lock reclaim and signal cleanup, and prints the lock path on contention.
- When `NODE_TLS_REJECT_UNAUTHORIZED=0` is detected, TLS verification is restored for the duration of this run only.
- Steps keep going after a failure; the run reports the failure in the summary and exits non-zero.

## Development

`make lint` runs shellcheck (required) and shfmt (skipped with a warning when absent); `make fmt` fixes formatting in place. Tests are grouped by domain under `scripts/tests/cases/` — run one group with `TEST_FILTER=node make test-update`. `.gitlab-ci.yml` runs lint, tests and an informational `doctor` on every push.

Tests use mock commands to cover the macOS / Linux branches, missing tools, failure aggregation and the safety boundaries — they never touch real system packages. Two kernel-lock cases need `flock`, which macOS does not ship, so they are skipped locally and only run in CI on Linux.

Mocks cannot verify real tool contracts (a RubyGems 3.0 incompatibility slipped through once), so run `make doctor` after switching machines or a major version bump. The apt path has been covered by mock tests but not yet verified against a real Debian/Ubuntu host — run `make doctor` there first.
