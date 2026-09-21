# Architecture

*[中文版](architecture.zh-CN.md)*

upkeep is one entry script plus six lib modules. This page covers how they are split up and — more importantly — the implicit contract they use to talk to each other through global variables. That contract is the easiest thing to break.

## Layout

```
Makefile                      # the only public entry point
scripts/
  update-local-packages.sh    # make update: shared state, step orchestration
  doctor.sh                   # make doctor: read-only health check
  clean-docker-cache.sh       # make clean-docker: standalone, loads no lib
  verify-apt-container.sh     # make verify-apt: real apt contract, in containers
  lib/
    site-config.sh            # site config: lookup, loading, validation
    step-runner.sh            # step executor: skip flag, sudo, result summary
    lock.sh                   # concurrency lock: flock, falling back to mkdir
    node-tools.sh             # npm, pnpm, Bun
    python-tools.sh           # pipx, uv, pip, virtualenvs
    system-tools.sh           # system packages, rustup, Cargo, RubyGems
  tests/
    update-local-packages.test.sh   # entry: loads harness and fixtures, runs cases
    clean-docker-cache.test.sh      # standalone, brings its own assertions
    lib/harness.sh                  # counters, assertions, test runner
    lib/fixture.sh                  # isolated run dir, call wrapper
    fixtures/command-driver.sh      # mock command driver, its own file so shellcheck sees it
    cases/*.test.sh                 # by domain: cli, config, lock, system, node, python, flow
```

Tests run entirely against mock commands and never touch a real package manager. `TEST_FILTER` narrows a run to one domain, e.g. `TEST_FILTER=node make test-update`.

`clean-docker-cache.sh` is fully standalone. `doctor.sh` loads exactly one module, `site-config.sh`: it needs neither step orchestration nor locking, but its config lookup order has to match `make update` exactly, and two copies of that logic would drift.

## Order of operations

`main()` in `update-local-packages.sh` is the whole control flow:

1. `parse_args` — accepts only `--help` / `-h`; anything else exits with status 2.
2. `load_site_config` — resolves and loads the site config; a failure here exits before anything is updated.
3. `detect_platform` — maps `uname -s` onto `PLATFORM` (`macos` or `linux`) and refuses anything else. It also restores TLS verification for this process if `NODE_TLS_REJECT_UNAUTHORIZED=0` is set.
4. `acquire_lock` — takes the concurrency lock, or exits.
5. `run_step` for each step — system packages branch on the platform, the rest are shared.
6. `print_summary`, with the exit code decided by the failure count.

Modules are sourced by a `for` loop in a fixed order: `site-config`, `step-runner`, `lock`, `node-tools`, `python-tools`, `system-tools`. `site-config` must come first — the `PRIVATE_NPM_*` variables it declares are read by `node-tools`. The rest have no ordering requirement, but `step-runner` provides primitives everyone calls, so it reads better near the front.

## The shared-state contract

Modules do not pass state through arguments and return values. They read and write a set of globals declared by the entry script. Anything new has to respect this table.

| Variable | Declared in | Written by | Read by |
| --- | --- | --- | --- |
| `PLATFORM` | entry script | `detect_platform` | `lock.sh`, `python-tools.sh` |
| `STEP_DETAIL` | entry script | step functions, `skip_step` | `run_step` |
| `STEP_SKIPPED` | entry script | `skip_step`, `run_step` | `run_step`, `update_pipx` |
| `RESULT_LABELS` / `RESULT_STATES` / `RESULT_DETAILS` | entry script | `run_step` | `print_summary` |
| `FAILURE_COUNT` | entry script | `run_step` | `main` |
| `LOCK_PATH` / `LOCK_ACQUIRED` | entry script | `lock.sh` | `lock.sh` |
| `PIPX_RUNNER` | entry script | `ensure_pipx` | `update_pipx` |
| `PRIVATE_NPM_REGISTRY` / `PRIVATE_NPM_SCOPES` / `PRIVATE_NPM_PACKAGES` / `SITE_CONFIG_PATH` | `site-config.sh` | `load_site_config` | `node-tools.sh`, `doctor.sh` |

The cost of this design is that static analysis cannot see the connection. shellcheck works one file at a time, so every `STEP_DETAIL=` looks like an assignment that is never used. `.shellcheckrc` at the repo root therefore disables SC2034, and SC2153 for the same reason on the test side (case files read `MOCK_*` variables that `lib/fixture.sh` assigns). Both are documented in that file.

For how to write a new step, see [Adding a step](adding-a-step.md).

## The step state machine

`run_step` sorts every step function into one of three states. It checks `STEP_SKIPPED` first, then the exit status:

| What the step function does | State in the summary |
| --- | --- |
| calls `skip_step '<reason>'`, then returns | skipped |
| returns 0 | done |
| returns non-zero | failed, `FAILURE_COUNT` incremented |

Three things that catch people out:

- `skip_step` itself returns 0, so the usual `skip_step 'npm not found'; return` returns 0. Skipping is expressed through `STEP_SKIPPED`, not through the exit status.
- `run_step` clears `STEP_DETAIL` and `STEP_SKIPPED` before calling the step, so step functions do not reset them.
- On a failure with an empty `STEP_DETAIL`, `run_step` fills in the exit status, so a failed step always carries at least one readable line.

*Skipped* means the environment does not meet a precondition, and it never counts as a failure. A missing tool, a PEP 668 environment and an inactive corepack shim all land here. That is part of the safety boundary, not a degraded mode.

## The concurrency lock

`acquire_lock` first picks a directory through `prepare_lock_directory` (trying `XDG_RUNTIME_DIR`, then `XDG_STATE_HOME/upkeep`, then `$HOME/.local/state/upkeep`) and checks its owner and permission bits. It then branches on what the host can do:

- **With `flock`** (standard on Linux): a kernel file lock. However the process exits, the kernel releases it, so nothing is left behind.
- **Without `flock`** (macOS): an atomic `mkdir` lock with the owner PID written inside. A lock whose PID is gone is reclaimed, and `EXIT`, `INT`, `TERM` and `HUP` are trapped for cleanup. `kill -9` can still leave one behind, and the error message then prints the lock path.

The difference is dictated by the platform, not configurable. The two kernel-lock test cases skip on a host without `flock`, so only CI on Linux actually exercises them.

## Bash 3.2 constraints

macOS ships bash 3.2 and the project treats that as the floor:

- No `mapfile` / `readarray`. Multi-line output is read with `while IFS= read -r`.
- No associative arrays. The summary uses three index-aligned plain arrays.
- Under `set -u`, a possibly-empty array must be expanded as `${arr[@]+"${arr[@]}"}`; a bare `"${arr[@]}"` raises an unbound variable error.
- No GNU-only options. `readlink -f` and `stat -c` do not exist on macOS, so those need a per-platform branch or a pure-Bash equivalent.
