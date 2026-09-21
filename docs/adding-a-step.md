# Adding an update step

*[中文版](adding-a-step.zh-CN.md)*

How to add a new toolchain to `make update`. Read the shared-state contract and the step state machine in [Architecture](architecture.md) first.

## The step function contract

A step function takes no arguments and returns no structured result. It only has to do three things:

- Call `skip_step '<tool> not found'` and return when the tool is absent.
- Return 0 on success, writing anything worth recording into `STEP_DETAIL`.
- Return non-zero on failure, ideally with a reason in `STEP_DETAIL`. Left empty, the summary shows only the exit status.

The skeleton:

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

(User-facing strings in this codebase are Chinese; keep new ones consistent with the surrounding steps.)

A few things learned from the existing steps:

- `skip_step` returns 0, so `skip_step '...'; return` exits with 0. Skipping is carried by `STEP_SKIPPED`, so do not add a `return 1`.
- When several sub-commands should all run before reporting, accumulate with `local result=0` instead of returning on the first error. `update_homebrew` and `update_apt` both do this.
- Test for a whitespace-only string with `[[ -z "${value//[[:space:]]/}" ]]` rather than shelling out.
- If probing whether a tool is usable could itself trigger an interactive download, disable the network and the prompt for the probe. `update_pnpm` does exactly that for corepack shims.

## Wiring it into the orchestration

Add one line to `main()` in `scripts/update-local-packages.sh`, and update the scope description in `usage()` to match:

```bash
run_step 'Deno 全局包' update_deno
```

The label appears verbatim in the summary. Follow the existing "tool + what it updates" shape.

## Steps that need sudo

Only system package managers use sudo. `run_with_sudo` accepts nothing but an absolute executable path that has been confirmed to exist. That restriction is deliberate — do not work around it:

```bash
local dnf_bin
dnf_bin="$(command -v dnf)" || { skip_step '未检测到 dnf'; return; }
run_with_sudo "$dnf_bin" upgrade --refresh --assumeyes --noautoremove
```

If the child process genuinely needs environment variables, allowlist them by name with a `--preserve-env=` prefix. sudo resets the environment by default, and passing the whole thing through would defeat the point:

```bash
DEBIAN_FRONTEND=noninteractive run_with_sudo \
    --preserve-env=DEBIAN_FRONTEND "$apt_bin" upgrade --assume-yes
```

RubyGems and pip never use sudo. See [Design decisions](decisions.md) for why.

## Adding tests

Tests are driven by mock commands and never touch a real package manager. They are split by domain:

```
scripts/tests/update-local-packages.test.sh  # entry: loading and the summary
scripts/tests/lib/harness.sh                 # counters, assertions, run_test
scripts/tests/lib/fixture.sh                 # isolated run dir, call wrapper
scripts/tests/fixtures/command-driver.sh     # mock command driver
scripts/tests/cases/*.test.sh                # cli, config, lock, system, node, python, flow
```

1. **Teach the mock about the new command.** Add a branch to `case "$name" in` in `fixtures/command-driver.sh` that prints the tool's typical output. To assert on an environment variable, add a line to the `printf` block that records the call. Tunable behaviour goes in a `MOCK_*` variable: give it a default in `create_fixture` and add it to the environment prefix list in `run_update`.

2. **Write the case.** Put it in the matching file under `cases/`, or add a new domain and list it in the entry script's `case_module` loop. Each case is a subshell — `(` rather than `{` — so variables set by `create_fixture` cannot leak into the next case:

```bash
test_deno_without_globals_is_reported() (
    create_fixture
    enable_tools deno
    run_update
    assert_status 0 "$RUN_STATUS" || exit
    assert_contains "$RUN_OUTPUT" '没有 Deno 全局包' || exit
)
```

3. **Register it** at the end of the same file: `run_test node 'deno without globals is reported' test_deno_without_globals_is_reported`. The first argument is the domain, matching the file name, and `TEST_FILTER` selects on it. The optional fourth argument names a command; when the host does not have it, the case is skipped instead of failing — that is how the two kernel-lock cases skip on macOS via `flock`. For a condition that is more than "is this command present", have the case `return 77` itself (the TAP/autotools skip convention); the runner treats that as a skip too.

Available assertions: `assert_status`, `assert_nonzero`, `assert_contains`, `assert_not_contains`, `assert_equals`. `RUN_OUTPUT` is the script's combined output, `RUN_CALLS` is the recorded mock call log, and `RUN_STATUS` is the exit code.

At a minimum, cover: the tool being absent is skipped, the happy path invokes the expected command, and a failure is summarised as failed with a non-zero overall exit. Pin safety boundaries — a dangerous flag that must not appear, a path that must not use sudo — with `assert_not_contains`.

## Adding a doctor check

Mock tests verify that the code agrees with its own assumptions. They cannot verify that those assumptions match the real tool. Any step that depends on a real tool's output format or argument conventions needs a read-only check in `scripts/doctor.sh` reporting the version and the key preconditions.

Note the stronger form of this rule: **an existence check is not a contract check.** `command -v some-helper` passing tells you nothing about whether the arguments you pass are still accepted. Probe the convention itself — for example, confirm `--help` still lists the flag you rely on. Both incidents in [Troubleshooting](troubleshooting.md) (RubyGems and cargo-update) got through because the check stopped at existence.

## Before committing

```bash
make lint   # shellcheck + shfmt
make test   # the full mock suite
make doctor # read-only, confirms your new check prints what you expect
```

All three should pass. `make fmt` fixes formatting in place. If your step touches apt, `make verify-apt` exercises it against real containers (needs Docker and network).
