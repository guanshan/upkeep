#!/usr/bin/env bash

set -uo pipefail

usage() {
    printf '%s\n' \
        '用法：scripts/clean-docker-cache.sh [--help]' \
        '' \
        '清理范围：' \
        '  - Docker 构建缓存（docker builder prune --all）' \
        '  - 悬空镜像（docker image prune，仅无标签的 <none> 镜像）' \
        '' \
        '安全边界：' \
        '  - 不删除有标签的镜像、容器、卷和网络' \
        '  - 正在被构建使用的缓存由 docker 自动跳过'
}

parse_args() {
    if (($# == 0)); then
        return 0
    fi
    if (($# == 1)) && [[ "$1" == '--help' || "$1" == '-h' ]]; then
        usage
        exit 0
    fi
    printf '错误：未知参数：%s\n' "$*" >&2
    usage >&2
    exit 2
}

main() {
    parse_args "$@"
    if ! command -v docker >/dev/null 2>&1; then
        printf '错误：未检测到 docker。\n' >&2
        return 1
    fi

    printf '==> 清理前磁盘占用\n'
    if ! docker system df; then
        printf '错误：无法访问 docker daemon。\n' >&2
        return 1
    fi

    local result=0
    printf '\n==> 清理构建缓存\n'
    docker builder prune --all --force || result=1
    printf '\n==> 清理悬空镜像\n'
    docker image prune --force || result=1

    printf '\n==> 清理后磁盘占用\n'
    docker system df || result=1
    return "$result"
}

main "$@"
