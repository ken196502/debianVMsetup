#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

# ============================================================
# Debian: 安装 Node.js（使用 NodeSource 仓库）
# 从 mihomo.sh 抽出，独立成脚本
# 默认版本：24
# ============================================================

NODE_MAJOR='24'

# 允许通过环境变量覆盖版本，例如 NODE_MAJOR_OVERRIDE=22 bash install_nodejs.sh
if [[ -n "${NODE_MAJOR_OVERRIDE:-}" ]]; then
    NODE_MAJOR="$NODE_MAJOR_OVERRIDE"
fi

if [[ "$(id -u)" -ne 0 ]]; then
    echo "错误：请使用 root 运行：sudo bash install_nodejs.sh" >&2
    exit 1
fi

if [[ ! -f /etc/debian_version ]]; then
    echo "错误：此脚本仅面向 Debian。" >&2
    exit 1
fi

# 已安装且版本一致则跳过，避免被重复调用时重复安装
if command -v node >/dev/null 2>&1; then
    INSTALLED_MAJOR="$(node --version 2>/dev/null | sed 's/^v//; s/\..*//')"
    if [[ -n "$INSTALLED_MAJOR" && "$INSTALLED_MAJOR" == "$NODE_MAJOR" ]]; then
        echo "Node.js ${NODE_MAJOR} 已安装（$(node --version)），跳过。"
        exit 0
    fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo
echo "============================================================"
echo "安装 Node.js ${NODE_MAJOR}"
echo "============================================================"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    amd64|arm64) ;;
    *)
        echo "错误：NodeSource 的 Node.js ${NODE_MAJOR} 安装脚本不支持当前架构：$ARCH" >&2
        exit 1
        ;;
esac

# 安装前置依赖
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    gnupg

# 下载并运行 NodeSource 安装脚本
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" \
    -o "$TMP/nodesource_setup.sh"
bash "$TMP/nodesource_setup.sh"

# 安装 Node.js
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

node --version
npm --version

echo
echo "Node.js ${NODE_MAJOR} 安装完成。"
