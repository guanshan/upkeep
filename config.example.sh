#!/usr/bin/env bash

# 站点配置模板。三种用法，按需选一种：
#   cp config.example.sh ~/.config/upkeep/config.sh   用户级，不进仓库（推荐）
#   cp config.example.sh config.sh                    随本 checkout 走，可提交给团队共用
#   UPKEEP_CONFIG=/path/to/config.sh make update      仅本次使用指定配置
# 完全不配置也能正常运行，此时不处理任何私有包。
#
# Site configuration template. Copy it to ~/.config/upkeep/config.sh, to ./config.sh,
# or point UPKEEP_CONFIG at it. Running without any config is fine — no private
# packages are touched.

# 私有包走的 registry；留空则使用 npm 当前配置的默认 registry。
# Registry used for private packages; leave empty to use npm's configured default.
PRIVATE_NPM_REGISTRY='https://registry.example.com/npm'

# 这些 scope 下已安装的包都改走私有 registry 更新，但不会因为缺失而安装。
# Installed packages in these scopes are updated through the private registry.
# They are never installed just because they are missing.
PRIVATE_NPM_SCOPES=('@acme')

# 必备私有 CLI，缺失时自动补装。
# 每项格式为「包名」或「包名|额外的 npm install 参数」。
# Required private CLIs, installed when missing.
# Each item is either "package-name" or "package-name|extra npm install arguments".
PRIVATE_NPM_PACKAGES=(
    '@acme/cli'
    '@acme/strict-cli|--engine-strict'
)
