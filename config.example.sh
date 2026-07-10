#!/usr/bin/env bash

# Copy this file to ~/.config/upkeep/config.sh, or point UPKEEP_CONFIG to it.
# 将此文件复制到 ~/.config/upkeep/config.sh，或通过 UPKEEP_CONFIG 指定路径。

# Leave the registry empty to use npm's configured default registry.
# registry 为空时使用 npm 当前配置的默认 registry。
PRIVATE_NPM_REGISTRY='https://registry.example.com/npm'

# Each item is either "package-name" or "package-name|extra npm install arguments".
# 每项格式为「包名」或「包名|额外的 npm install 参数」。
PRIVATE_NPM_PACKAGES=(
    '@acme/cli'
    '@acme/strict-cli|--engine-strict'
)
