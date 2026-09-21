# Troubleshooting

*[中文版](troubleshooting.zh-CN.md)*

Look up the symptom. Whatever the problem, start with `make doctor` — it is read-only, changes nothing, and most issues are visible directly in its output.

## First: skipped is not failed

The three states in the summary mean different things:

- **Skipped** — the environment does not meet a precondition. A missing tool, PEP 668, an inactive corepack shim all land here. It does not count as a failure and the overall exit code is still 0.
- **Done** — the step succeeded. The parenthesis may add detail, e.g. "no outdated user gems".
- **Failed** — a command returned non-zero. The run exits non-zero, but the remaining steps still ran to completion.

## "An update is already running"

The error prints the lock path. First confirm no upkeep process is actually running:

```bash
ps aux | grep update-local-packages
```

Then remove the lock:

```bash
rm -rf ~/.local/state/upkeep/upkeep-$UID.lock
```

A normal exit and Ctrl-C both clean up after themselves. On macOS only `kill -9` can leave a lock behind — that path uses a `mkdir` directory lock and never gets to run its cleanup. On Linux the kernel `flock` is released the moment the process disappears, so residue is not possible. The "concurrency lock" section of `make doctor` reports whether a stale lock exists.

## The pnpm step is skipped

The message is "pnpm unavailable (possibly an inactive corepack shim)". `command -v pnpm` found Corepack's shim, but the corresponding version has not been downloaded into the local cache.

The script deliberately does not download it: the probe runs with the network and the download prompt disabled, so `make update` cannot hang on an interactive confirmation. To enable it for real, run this once:

```bash
corepack prepare pnpm@latest --activate
```

If you do not use pnpm, the skip is harmless.

## The Python packages step is skipped

The message mentions PEP 668 protecting the current Python. This is a property of the environment, not a fault. The script will not use `--break-system-packages`, and it will not install Python packages with sudo.

Pick the route that matches your intent:

- Command-line tools belong to pipx or uv, each of which has its own step.
- Project dependencies belong in a virtualenv. On Linux, activate it and then run `make update`; the script updates that environment's top-level outdated packages and runs `pip check`.

The other skip message — the pip install directory is not writable and the user site is unusable — likewise does not fall back to sudo. Check how that Python was installed.

## uv self-update failed

Three cases, distinguishable by the detail text in the summary:

- "uv is managed by Homebrew, self-update handled by the Homebrew step" — expected. uv's own version is updated during the system package step; the uv step only updates the tools uv manages.
- "uv is already at x.y.z (GitHub API rate-limited, no reinstall needed)" — this machine's egress IP has exhausted the anonymous GitHub API quota, but the installed version is already the target. Nothing to do.
- "GitHub API rate-limited, updated uv through the install script instead" — it already fell back to `https://astral.sh/uv/install.sh`, which is equivalent to a self-update.

Only a missing curl, or a failure of the install script itself, is recorded as a failure.

## The Cargo step is skipped

The message is that cargo-update is not installed. Updating global Cargo packages needs the `cargo-install-update` helper, and installing that helper takes minutes of compilation. The updater does not start long implicit builds, so install it yourself once:

```bash
cargo install cargo-update
```

The step then works automatically.

## The Cargo step fails with "unexpected argument '--all' found"

From cargo-update 22.x onwards, running `cargo-install-update --all` directly fails: the binary's top-level parser still expects an `install-update` subcommand. The correct form goes through cargo's dispatch: `cargo install-update --all`.

This was broken until 2026-09-21 while the mock tests stayed green — the helper is mocked, and doctor at the time only checked that the command existed, not that the arguments were still accepted. doctor now probes whether `cargo install-update --help` actually lists `--all`, so the same class of drift surfaces after a machine change or a major cargo-update release.

## The RubyGems step is skipped

The message says the RubyGems user directory could not be determined because no usable ruby was found. That directory is resolved with `ruby -e 'Gem.user_dir'`.

There is a lesson behind this: an early version used `gem env user_gemhome`, which requires RubyGems 3.2 or newer, while macOS ships 3.0. The mock tests were green and the real machine failed. `make doctor` exists to cover exactly this gap — run it after switching machines or a major version bump.

## The system packages step fails

**macOS.** Errors from `brew update` or `brew upgrade` are printed verbatim. The script does not run `brew cleanup` and does not force-quit running cask apps, so a cask whose app is running may fail to upgrade — quit the app and run again.

**Linux.** Check the "system package manager" section of `make doctor` first to see whether dnf or apt-get was detected; if neither exists the step skips. A non-root user without sudo fails outright.

The apt path has two deliberate constraints: locally modified config files are kept (`--force-confold`), and services are not restarted automatically (`NEEDRESTART_MODE=l` only lists them). So an upgrade may leave services needing a manual restart, or a reboot. If the error says packages would have to be removed to upgrade, that is `--no-remove` doing its job — the script will not decide to uninstall anything on your behalf.

To check the apt path itself against real Debian and Ubuntu containers, run `make verify-apt` (needs Docker and network).

## Private packages were not updated as expected

Run `make doctor` first — its "site configuration" section prints exactly which file was loaded, the registry and the package list. The usual causes:

- **"No site config loaded"** — none of the three sources matched. Check whether `~/.config/upkeep/config.sh` exists, or whether there is a `config.sh` in the repo root (a public checkout has none by default; copy `config.example.sh`).
- **The wrong file was loaded** — the order is `$UPKEEP_CONFIG` > user config > repo `config.sh`, first match wins. Usually either a stale exported `UPKEEP_CONFIG` in the shell, or a user config shadowing the repo one.
- **Packages updated but not through the private registry** — an empty `PRIVATE_NPM_REGISTRY` means npm's configured default is used. Also note that `PRIVATE_NPM_SCOPES` only affects *how installed packages are updated*; a missing package is not installed just because its scope matches. That is what `PRIVATE_NPM_PACKAGES` is for.

To run once without any site config:

```bash
UPKEEP_CONFIG= make update
```

## Site config errors

- **"UPKEEP_CONFIG points at a config that does not exist"** — an explicitly named path must exist. There is deliberately no silent fallback, so that a typo does not present itself as "it ran but nothing private was updated".
- **"PRIVATE_NPM_REGISTRY must be an http(s) address"** — only `http://` or `https://` is accepted; empty means npm's default registry.
- **"Each PRIVATE_NPM_SCOPES entry should look like @scope"** — write `@acme`, not `acme`, and without a trailing `/`.
- **"Invalid package name in PRIVATE_NPM_PACKAGES"** — each entry is either `package-name` or `package-name|extra npm install arguments`; the arguments go after the pipe.

## npm

**Enumeration failed but private packages were still installed.** `npm ls` exits non-zero when the global tree contains extraneous or invalid packages. As long as the output is usable the run continues; even when it is not, the required private CLIs are still installed independently, and the step is recorded as failed with an explanation.

**A private package could not be fetched.** Private packages are usually not on the public npm registry and go through the mirror named by `PRIVATE_NPM_REGISTRY`. Use `make doctor` to confirm which config was loaded and whether that registry is right, then check that the registry itself is reachable (it may require being on a particular network).

**TLS warning.** When `NODE_TLS_REJECT_UNAUTHORIZED=0` is detected, a warning is printed and certificate verification is restored for the duration of this run only. Your shell configuration is not modified.

## Some test cases are skipped

On macOS you will see two:

```
SKIP [lock] flock mode is used when available（宿主机没有 flock）
SKIP [lock] flock mode rejects concurrent run（宿主机没有 flock）
```

`flock` ships with Linux and not with macOS, and kernel-lock behaviour cannot be simulated, so these skip rather than fail. CI runs them on Linux.

A third one skips wherever the repo has no `config.sh`, which is the normal state of a public checkout:

```
SKIP [config] repo config is used when nothing else is set
```

## make lint reports formatting problems

Run `make fmt` to fix them in place, then `make lint` again. Without shfmt the format check warns and skips rather than blocking; without shellcheck lint fails outright — a missing static check should be loud, not silent.

Note that shfmt's layout rules change between versions, and the version in a distribution archive often differs from a developer's. CI installs a pinned release for that reason; if your local shfmt disagrees with CI, check `shfmt --version` against the one pinned in `.github/workflows/ci.yml`.
