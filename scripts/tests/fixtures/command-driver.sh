#!/usr/bin/env bash
set -u

name="${0##*/}"

if [[ "$name" == 'uname' ]]; then
    printf '%s\n' "${STUB_UNAME:-Linux}"
    exit 0
fi
if [[ "$name" == 'stat' ]]; then
    printf '%s\n' "${MOCK_STAT_MODE:-700}"
    exit 0
fi
if [[ "$name" == 'id' && "${1:-}" == '-u' ]]; then
    printf '%s\n' "${MOCK_UID:-1000}"
    exit 0
fi

{
    printf '%s' "$name"
    for argument in "$@"; do
        printf ' %s' "$argument"
    done
    if [[ "$name" == 'brew' ]]; then
        printf ' [HOMEBREW_NO_INSTALL_CLEANUP=%s]' "${HOMEBREW_NO_INSTALL_CLEANUP:-}"
        printf ' [HOMEBREW_NO_UPGRADE_QUIT_CASKS=%s]' "${HOMEBREW_NO_UPGRADE_QUIT_CASKS:-}"
    fi
    if [[ "$name" == 'npm' ]]; then
        printf ' [NODE_TLS_REJECT_UNAUTHORIZED=%s]' "${NODE_TLS_REJECT_UNAUTHORIZED:-}"
    fi
    if [[ "$name" == 'gem' ]]; then
        printf ' [GEM_HOME=%s] [GEM_PATH=%s]' "${GEM_HOME:-}" "${GEM_PATH:-}"
    fi
    if [[ "$name" == 'pnpm' ]]; then
        printf ' [COREPACK_ENABLE_NETWORK=%s] [COREPACK_ENABLE_DOWNLOAD_PROMPT=%s]' \
            "${COREPACK_ENABLE_NETWORK:-}" "${COREPACK_ENABLE_DOWNLOAD_PROMPT:-}"
    fi
    printf '\n'
} >>"$CALLS_FILE"

if [[ "${MOCK_FAIL_MANAGER:-}" == "$name" ]]; then
    exit "${MOCK_FAIL_STATUS:-42}"
fi

case "$name" in
    npm)
        if [[ "${1:-}" == 'ls' ]]; then
            printf '%s\n' '/mock/lib'
            local_package=''
            for local_package in ${MOCK_NPM_GLOBALS:-}; do
                printf '/mock/lib/node_modules/%s\n' "$local_package"
            done
            exit "${MOCK_NPM_LS_STATUS:-0}"
        fi
        ;;
    pnpm)
        if [[ "${1:-} ${2:-}" == 'root --global' ]]; then
            printf '%s\n' "${MOCK_PNPM_ROOT:-}"
            exit "${MOCK_PNPM_ROOT_STATUS:-0}"
        fi
        ;;
    ruby)
        if [[ "${1:-}" == '-rrubygems' ]]; then
            printf '%s' "${MOCK_GEM_USER_DIR:-}"
        fi
        ;;
    uv)
        if [[ "${1:-}" == '--version' ]]; then
            printf 'uv %s (mock-platform)\n' "${MOCK_UV_VERSION:-0.11.7}"
        elif [[ "${1:-} ${2:-}" == 'self update' ]]; then
            if [[ "${MOCK_UV_EXTERNAL_MANAGER:-}" == '1' ]]; then
                printf '%s\n' 'error: uv was installed through an external package manager and cannot update itself.' >&2
                printf '%s\n' 'hint: You installed uv using Homebrew. To update uv, run `brew update && brew upgrade uv`' >&2
                exit 1
            fi
            if [[ "${MOCK_UV_SELF_UNSUPPORTED:-}" == '1' ]]; then
                printf '%s\n' 'Self-update is only available for uv binaries installed via the standalone installation scripts.' >&2
                exit 2
            fi
            if [[ "${MOCK_UV_SELF_RATELIMITED:-}" == '1' ]]; then
                printf '%s\n' 'error: The version 0.11.28 was not found for the app uv in workspace uv' >&2
                exit 1
            fi
        fi
        ;;
    bun)
        if [[ "${1:-} ${2:-} ${3:-}" == 'pm ls --global' ]]; then
            if [[ "${MOCK_BUN_NO_MANIFEST:-}" == '1' ]]; then
                printf '%s\n' 'error: No package.json was found' >&2
                exit 1
            fi
            printf '%s' "${MOCK_BUN_LIST:-}"
        fi
        ;;
    cargo)
        if [[ "${1:-} ${2:-}" == 'install --list' ]]; then
            printf '%s' "${MOCK_CARGO_LIST:-}"
        fi
        ;;
    brew)
        if [[ "${1:-} ${2:-}" == '--prefix uv' ]]; then
            if [[ -n "${MOCK_BREW_UV_PREFIX:-}" ]]; then
                printf '%s\n' "$MOCK_BREW_UV_PREFIX"
                exit 0
            fi
            exit 1
        fi
        if [[ "${1:-} ${2:-}" == '--prefix ruby' ]]; then
            if [[ -n "${MOCK_BREW_RUBY_PREFIX:-}" ]]; then
                printf '%s\n' "$MOCK_BREW_RUBY_PREFIX"
                exit 0
            fi
            exit 1
        fi
        if [[ "${1:-} ${2:-}" == 'install pipx' ]]; then
            ln -sf "$FIXTURE_DIR/command-driver" "$MOCK_BIN/pipx"
        fi
        ;;
    gem)
        if [[ "${1:-}" == 'outdated' ]]; then
            printf '%s' "${MOCK_GEM_OUTDATED:-}"
        fi
        ;;
    python3)
        if [[ "${1:-} ${2:-} ${3:-}" == '-m pip --version' ]]; then
            printf '%s\n' 'pip 26.1.2'
        elif [[ "${1:-} ${2:-}" == '- pip-outdated' ]]; then
            printf '%s' "${MOCK_PIP_OUTDATED:-}"
        elif [[ "${1:-} ${2:-}" == '- externally-managed' ]]; then
            exit "${MOCK_PIP_EXTERNAL:-1}"
        elif [[ "${1:-} ${2:-}" == '- purelib-path' ]]; then
            printf '%s' "${MOCK_PIP_TARGET:-}"
        elif [[ "${1:-} ${2:-}" == '- user-site-path' ]]; then
            printf '%s' "${MOCK_PIP_USER_TARGET:-}"
        elif [[ "${1:-} ${2:-}" == '- in-virtualenv' ]]; then
            exit "${MOCK_PYTHON_VENV:-1}"
        elif [[ "${1:-} ${2:-} ${3:-}" == '-m pip install' && "${MOCK_PIP_FAIL_COMMAND:-}" == 'install' ]]; then
            exit 42
        fi
        ;;
esac

exit 0

