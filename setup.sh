#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

# ============================================================
# Debian 一键部署：Git + Tmux + Chromium + Node.js + Mihomo + 订阅
# 依次调用本目录下的各个安装脚本
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "错误：请使用 root 运行：sudo bash setup.sh" >&2
    exit 1
fi

if [[ ! -f /etc/debian_version ]]; then
    echo "错误：此脚本仅面向 Debian。" >&2
    exit 1
fi

run() {
    local desc="$1"; shift
    echo
    echo "############################################################"
    echo "# $desc"
    echo "############################################################"
    "$@"
}

# ---------- 1/6 安装 Git ----------
run "1/6 安装 Git" bash -c '
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y git
    git --version
'

# ---------- 2/6 安装 Tmux ----------
run "2/6 安装 Tmux" bash -c '
    DEBIAN_FRONTEND=noninteractive apt-get install -y tmux
    tmux -V
'

# ---------- 3/6 安装 Chromium 并设置 BROWSER ----------
echo
echo "############################################################"
echo "# 3/6 安装 Chromium 并设置 BROWSER 环境变量"
echo "############################################################"
DEBIAN_FRONTEND=noninteractive apt-get install -y chromium

CHROMIUM_BIN="$(command -v chromium || true)"
if [[ -z "$CHROMIUM_BIN" ]]; then
    echo "错误：未找到 chromium 可执行文件。" >&2
    exit 1
fi
echo "Chromium 路径：$CHROMIUM_BIN"

# 设置 BROWSER 环境变量（系统级 /etc/environment + 登录 shell /etc/profile.d）
if ! grep -qxF "BROWSER="$CHROMIUM_BIN"" /etc/environment 2>/dev/null; then
    echo "BROWSER="$CHROMIUM_BIN"" >> /etc/environment
fi
cat > /etc/profile.d/browser.sh <<PROF
export BROWSER="$CHROMIUM_BIN"
PROF
chmod 0644 /etc/profile.d/browser.sh
export BROWSER="$CHROMIUM_BIN"
echo "已设置 BROWSER=$CHROMIUM_BIN"

# ---------- 4/6 安装 Node.js ----------
run "4/6 安装 Node.js" bash "$SCRIPT_DIR/install_nodejs.sh"

# ---------- 5/6 安装 Mihomo ----------
run "5/6 安装 Mihomo" bash "$SCRIPT_DIR/mihomo.sh"

# ---------- 6/6 更新 Mihomo 订阅 ----------
run "6/6 更新 Mihomo 订阅" bash "$SCRIPT_DIR/mihomo_sub.sh"

echo
echo "############################################################"
echo "# 全部完成"
echo "############################################################"
echo "Chromium : $CHROMIUM_BIN (BROWSER 已设置)"
git --version
tmux -V
node --version
mihomo -v
echo "服务状态："
systemctl --no-pager --full status mihomo || true
