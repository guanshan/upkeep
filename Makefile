SHELL := /bin/bash
.DEFAULT_GOAL := update-help
ROOT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
UPDATE_SCRIPT := $(ROOT_DIR)scripts/update-local-packages.sh
UPDATE_TEST := $(ROOT_DIR)scripts/tests/update-local-packages.test.sh
CLEAN_DOCKER_SCRIPT := $(ROOT_DIR)scripts/clean-docker-cache.sh
CLEAN_DOCKER_TEST := $(ROOT_DIR)scripts/tests/clean-docker-cache.test.sh
DOCTOR_SCRIPT := $(ROOT_DIR)scripts/doctor.sh
SHELL_SOURCES := $(wildcard \
	$(ROOT_DIR)scripts/*.sh \
	$(ROOT_DIR)scripts/lib/*.sh \
	$(ROOT_DIR)scripts/tests/*.sh \
	$(ROOT_DIR)scripts/tests/lib/*.sh \
	$(ROOT_DIR)scripts/tests/cases/*.sh \
	$(ROOT_DIR)scripts/tests/fixtures/*.sh)

.PHONY: update update-help doctor clean-docker test-update test-clean-docker test \
	lint shellcheck fmt-check fmt

update:
	@"$(UPDATE_SCRIPT)"

update-help:
	@"$(UPDATE_SCRIPT)" --help

doctor:
	@"$(DOCTOR_SCRIPT)"

clean-docker:
	@"$(CLEAN_DOCKER_SCRIPT)"

test-update:
	@bash "$(UPDATE_TEST)"

test-clean-docker:
	@bash "$(CLEAN_DOCKER_TEST)"

test: test-update test-clean-docker

lint: shellcheck fmt-check

# shellcheck 是硬性要求：静态检查缺位时宁可让 lint 失败，也不要静默放行。
shellcheck:
	@command -v shellcheck >/dev/null 2>&1 \
		|| { printf '错误：未安装 shellcheck（brew install shellcheck / apt-get install shellcheck）\n' >&2; exit 1; }
	@shellcheck -x $(SHELL_SOURCES)
	@printf 'shellcheck：通过\n'

# shfmt 只管格式，缺失时告警跳过，避免为了排版阻断本地开发。
fmt-check:
	@command -v shfmt >/dev/null 2>&1 \
		|| { printf '警告：未安装 shfmt，跳过格式检查（brew install shfmt）\n' >&2; exit 0; }
	@shfmt -d -i 4 -ci $(SHELL_SOURCES)
	@printf 'shfmt：通过\n'

fmt:
	@command -v shfmt >/dev/null 2>&1 \
		|| { printf '错误：未安装 shfmt（brew install shfmt）\n' >&2; exit 1; }
	@shfmt -w -i 4 -ci $(SHELL_SOURCES)
