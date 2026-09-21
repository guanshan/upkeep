# Design decisions

*[中文版](decisions.zh-CN.md)*

The reasoning behind the safety boundaries. Each entry states what was refused, why, and what it costs. Read the relevant one before changing that behaviour.

One principle runs through all of them: **this script runs a dozen package managers unattended.** Anything that is "probably fine" becomes unacceptable once multiplied by how often it runs. When in doubt, skip and say so rather than deciding on the user's behalf.

## No sudo for Python packages

pip never runs under sudo. On macOS it tries a writable install directory first, then the user site, and skips if neither works.

`sudo pip install` drops files into the system Python's directories, competing with the system package manager over the same files. It is the classic way to break a distribution. PEP 668's `EXTERNALLY-MANAGED` marker exists precisely to stop it, and `--break-system-packages` is the explicit way around that marker — so it is never used either.

The cost: in a protected environment the step always skips. That is intended. Command-line tools belong to pipx or uv, project dependencies belong in a virtualenv, and both have their own steps.

`run_with_sudo` is called only by system package managers, and only ever with an absolute executable path that has been confirmed to exist. RubyGems likewise goes through the user directory, never sudo.

## No bulk updates of the Linux system Python

On Linux only top-level, non-editable outdated packages in the *currently activated* virtualenv are updated, followed by `pip check`. With no virtualenv active, the system pip is not invoked at all.

A distribution's system Python is owned by its package manager; a bulk `pip install --upgrade` leaves the two management systems disagreeing about the same files. Restricting to top-level packages avoids breaking other packages' version constraints through transitive updates — `--upgrade-strategy only-if-needed` and the follow-up `pip check` are there for the same reason.

macOS is treated differently on purpose: its `python3` is usually Homebrew or a standalone install, carries no system functionality, and has a different risk profile.

## No autoremove, no brew cleanup

DNF gets `--noautoremove`, apt gets `--no-remove`, Homebrew gets `HOMEBREW_NO_INSTALL_CLEANUP=1`.

All three are deletion operations driven by the package manager's dependency graph. That graph is not always accurate after packages have been installed by hand, after `--nodeps`, or across a distribution upgrade — and the cost of deleting the wrong thing far exceeds the disk space saved. Reclaiming disk is a separate intention that deserves its own command and its own confirmation; it should not ride along with an update.

`make clean-docker` is the one cleanup entry point, and it only touches build cache and untagged dangling images — never tagged images, containers, volumes or networks.

## Nothing running is force-quit or restarted

macOS sets `HOMEBREW_NO_UPGRADE_QUIT_CASKS=1`, so running cask apps are not force-quit. Linux sets `NEEDRESTART_MODE=l`, so needrestart lists the services that want a restart instead of restarting them.

An update running in the background has no business terminating the editor someone is typing in, or restarting a process that is serving requests. The cost is that some casks fail to upgrade while their app is running, and that an apt upgrade may leave services needing a manual restart. Both show up in the output, where a human can decide when to deal with them.

## apt keeps locally modified config files

The apt path always passes `-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef`.

When dpkg finds a config file that was modified locally it asks interactively by default, which hangs an unattended run. Of the two options, `confold` keeps the local version and `confdef` handles the remaining branches. Keeping rather than overwriting is the right default because overwriting silently discards local configuration, whereas keeping merely misses a new default — the second is recoverable afterwards, the first is not.

`apt-get` is used rather than `apt`: apt states that its own command-line interface is not guaranteed to be stable between versions, so apt-get is the contract to write against.

## sudo passes only an allowlist of environment variables

`run_with_sudo` accepts a `--preserve-env=VAR[,VAR...]` prefix, which apt uses for `DEBIAN_FRONTEND` and `NEEDRESTART_MODE`.

sudo resets the environment by default, and that default is correct. When individual variables are genuinely needed, they are allowlisted by name rather than passed wholesale with a bare `--preserve-env`, which would carry the entire current shell environment — proxies, TLS settings, PATH manipulation and all — into a privileged process.

## Nothing is compiled implicitly

The Cargo step needs `cargo-install-update`. When it is missing the step skips with a hint instead of running `cargo install cargo-update`.

Installing that helper takes minutes of compilation. A command called "update my local packages" that suddenly starts a long build is both surprising and indistinguishable, from the output, from a hang. After the hint, installing it is the user's call.

## Site config lives outside the code, but a repo may ship a default

The private registry, private scopes and required internal CLIs are all declared in a config file; no site-specific literal remains in the scripts. Lookup order is `$UPKEEP_CONFIG` > `~/.config/upkeep/config.sh` > `config.sh` in the repo root.

The first reason is that it lets one codebase serve both a public repository and a private deployment. Previously the private registry and package names were hard-coded in the entry script, so every sync between the two meant stripping them out by hand — tedious and easy to get wrong. The practical benefit is smaller and more immediate: changing a registry or adding an internal CLI no longer means editing code.

The "config.sh in the repo root" level exists for private deployments: committed alongside the code, it makes `make update` work straight after a clone with no extra steps. A public repository does not commit it and ships `config.example.sh` instead. The difference between the two repos collapses to one data file plus one CI config, with identical code.

The config file is a Bash fragment that gets sourced, which makes it trusted code — `source` has already handed over control. The validation applied after loading therefore only catches typos (a registry written as `ftp://`, a scope missing its `@`, a package name with a space in it). It is not a security boundary.

One asymmetry is deliberate: a path given explicitly through `$UPKEEP_CONFIG` that does not exist is an **error**, while an auto-discovered path that does not exist is silently skipped. Naming a path explicitly means "I know where it is"; silently falling back to a different config, or to none, would make a typo in that path present itself as "the update seemed to run but my private packages were not updated" — among the hardest things to diagnose.

## Only a small set of tools is installed automatically

Two things are installed automatically: the required private CLIs listed in `PRIVATE_NPM_PACKAGES`, and pipx on macOS when it is missing.

The first is decided by site config rather than code, and since `npm install` is equivalent to an update for an already-installed package, installing and updating collapse into one step. The second is because pipx is itself the carrier for other tools — without it the whole Python CLI chain cannot be updated. On Linux only an already-installed pipx is updated, since distributions usually package it themselves.

`PRIVATE_NPM_SCOPES` deliberately cannot install anything; it only changes *how installed packages are updated*. Letting a scope match trigger an install would turn an entire private scope into an implicit provisioning list, which contradicts the rule below.

Everything else that is not installed is simply skipped. This is an updater, not a provisioner.

## Keep going after a failure, summarise at the end

A failing step does not stop the run. The remaining steps execute, all states are summarised at the end, and the process exits non-zero.

The dozen steps are independent of one another; an npm network problem is no reason to stop rustup from updating. Running everything once and reading a complete summary beats fix-one-rerun-fail-again. The exit code ensures a failure is not mistaken for success when the script is called from another script.

## The lock implementation follows the platform

With `flock`, a kernel lock. Without it, an atomic `mkdir` directory lock.

A kernel lock is released by the kernel when the process exits, so neither Ctrl-C nor `kill` leaves anything behind — it is the better mechanism. But macOS does not ship `flock(1)`, so the fallback has to exist: the directory lock records the owner PID, reclaims the lock when that PID is gone, and traps signals for cleanup. `kill -9` can still leave one behind, and the error message then prints the lock path so it can be dealt with directly.

The lock directory is checked for owner and permission bits (no group or other access) and symlinks are rejected, so the lock path cannot be substituted.

## Mock tests, then doctor for the real contract, then containers for apt

The test suite runs entirely against mock commands and never touches a real package manager. `make doctor` is a separate read-only check of real tools' versions and preconditions. `make verify-apt` goes one step further for apt.

Mock tests verify that the code agrees with its own assumptions. They cannot verify that those assumptions match the real tool. That gap has now been paid for twice:

1. An early version resolved the RubyGems user directory with `gem env user_gemhome`, which needs RubyGems 3.2 or newer — macOS ships 3.0. doctor was added to cover this layer.
2. The Cargo step called `cargo-install-update --all`, but cargo-update 22.x requires the `install-update` subcommand at the binary's top level. The helper is mocked in the tests so they stayed green, and doctor at the time only checked that the command existed, so it reached a real machine unnoticed.

The lesson from the second one: **an existence check is not a contract check.** For any step that depends on a real tool's output format or argument conventions, the doctor check should probe the convention itself — for instance, confirming that `--help` still lists the flag being used — not just `command -v`.

apt is a third case again, because the things most likely to break it (whether sudo accepts `--preserve-env`, whether debconf hangs an unattended upgrade, whether a real upgrade completes under `--no-remove` with `--force-confold`) cannot be observed on a macOS development machine at all. `make verify-apt` runs the real script against real apt in throwaway Debian and Ubuntu containers, as root and as a non-root user through sudo, forcing a genuine package upgrade. It needs Docker and network, which is why it is not part of `make test`.

## bash 3.2 is the floor

No `mapfile`, no associative arrays, no other bash 4+ features, and no GNU-only options.

macOS ships bash 3.2 (frozen there for GPLv3 reasons), and running on macOS is one of upkeep's main use cases. Requiring a newer bash before you can run a script whose job is keeping your tools current would be backwards.

The cost is that several constructs are more verbose than they need to be. The specific constraints are at the end of [Architecture](architecture.md).
