SHELL := /bin/bash
.DEFAULT_GOAL := update-help
ROOT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
UPDATE_SCRIPT := $(ROOT_DIR)scripts/update-local-packages.sh
UPDATE_TEST := $(ROOT_DIR)scripts/tests/update-local-packages.test.sh
CLEAN_DOCKER_SCRIPT := $(ROOT_DIR)scripts/clean-docker-cache.sh
CLEAN_DOCKER_TEST := $(ROOT_DIR)scripts/tests/clean-docker-cache.test.sh
DOCTOR_SCRIPT := $(ROOT_DIR)scripts/doctor.sh

.PHONY: update update-help doctor clean-docker test-update test-clean-docker test

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
