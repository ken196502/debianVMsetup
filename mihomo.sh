cat > /root/install-mihomo.sh <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

# ============================================================
# Debian: Node.js 24 + Mihomo + TUN + 清理系统级代理
# Mihomo 固定版本：v1.19.32
# ============================================================

SUB_URL='https://v4.gh-proxy.org/https://raw.githubusercontent.com/longyang1233/free-nodes-sub/refs/heads/main/clash.yaml'
MIHOMO_VER='v1.19.32'

if [[ "$(id -u)" -ne 0 ]]; then
    echo "错误：请使用 root 运行：bash /root/install-mihomo.sh" >&2
    exit 1
fi

if [[ ! -f /etc/debian_version ]]; then
    echo "错误：此脚本仅面向 Debian。" >&2
    exit 1
fi

BACKUP="/var/backups/mihomo-install-$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d)"
mkdir -p "$BACKUP"
trap 'rm -rf "$TMP"' EXIT

echo
echo "============================================================"
echo "1/8 备份并清理系统级代理设置"
echo "============================================================"

# 备份可能包含系统级代理设置的目录及文件
for p in \
    /etc/environment \
    /etc/profile \
    /etc/profile.d \
    /etc/apt/apt.conf \
    /etc/apt/apt.conf.d \
    /etc/systemd/system \
    /etc/systemd/system.conf.d \
    /etc/default
do
    if [[ -e "$p" ]]; then
        mkdir -p "$BACKUP$(dirname "$p")"
        cp -a "$p" "$BACKUP$p"
    fi
done

# 删除常见配置文件中的代理环境变量及 APT 代理项。
# 使用 Python 正则处理，不依赖未定义的 PATTERN shell 变量。
python3 - <<'PY'
import os
import re

paths = [
    "/etc/environment",
    "/etc/profile",
    "/etc/profile.d",
    "/etc/apt/apt.conf",
    "/etc/apt/apt.conf.d",
    "/etc/systemd/system",
    "/etc/systemd/system.conf.d",
    "/etc/default",
]

proxy_assignment = re.compile(
    r'^\s*(?:export\s+)?'
    r'(?:http_proxy|https_proxy|all_proxy|no_proxy|'
    r'HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)\s*=',
    re.IGNORECASE,
)

apt_proxy = re.compile(
    r'Acquire\s*::\s*(?:http|https)\s*::\s*Proxy\b',
    re.IGNORECASE,
)

systemd_proxy = re.compile(
    r'\b(?:http_proxy|https_proxy|all_proxy|no_proxy)\s*=',
    re.IGNORECASE,
)

def should_skip_line(line, path):
    if proxy_assignment.search(line) or apt_proxy.search(line):
        return True

    # systemd Environment= 行可能同时定义多个变量；
    # 如果其中包含代理变量，则移除整行，避免留下无效配置。
    if path.endswith((".conf", ".service")):
        if re.match(r'^\s*Environment(?:File)?\s*=', line, re.I):
            if systemd_proxy.search(line):
                return True

    return False

def process_file(path):
    if not os.path.isfile(path) or os.path.islink(path):
        return

    try:
        with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
            lines = f.readlines()
    except (OSError, UnicodeError):
        return

    new_lines = [
        line for line in lines
        if not should_skip_line(line, path)
    ]

    if new_lines != lines:
        with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.writelines(new_lines)
        print("已清理：", path)

for root in paths:
    if os.path.isfile(root):
        process_file(root)
    elif os.path.isdir(root):
        for current, dirs, files in os.walk(root):
            dirs[:] = [
                d for d in dirs
                if d not in (".git", "proc", "sys", "dev")
            ]
            for name in files:
                process_file(os.path.join(current, name))
PY

# 清除当前脚本进程中的代理环境变量
unset http_proxy https_proxy all_proxy no_proxy
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
unset ftp_proxy FTP_PROXY

echo "系统级代理清理完成。备份目录：$BACKUP"

echo
echo "============================================================"
echo "2/8 安装依赖"
echo "============================================================"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    gzip \
    python3 \
    python3-yaml \
    iproute2 \
    iptables

echo
echo "============================================================"
echo "3/8 安装 Node.js（调用独立脚本 install_nodejs.sh）"
echo "============================================================"

bash "$(dirname "$0")/install_nodejs.sh"

echo
echo "============================================================"
echo "4/8 下载并安装 Mihomo ${MIHOMO_VER}"
echo "============================================================"

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64)
        ASSET="mihomo-linux-amd64-compatible-${MIHOMO_VER}.gz"
        ;;
    arm64)
        ASSET="mihomo-linux-arm64-${MIHOMO_VER}.gz"
        ;;
    armhf)
        ASSET="mihomo-linux-armv7-${MIHOMO_VER}.gz"
        ;;
    i386)
        ASSET="mihomo-linux-386-${MIHOMO_VER}.gz"
        ;;
    *)
        echo "错误：尚未配置 Mihomo 对应的 Debian 架构：$ARCH" >&2
        exit 1
        ;;
esac

MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/${ASSET}"
MIHOMO_MIRROR="https://v4.gh-proxy.org/${MIHOMO_URL}"

if ! curl -fL --connect-timeout 15 --retry 2 \
    "$MIHOMO_URL" -o "$TMP/mihomo.gz"; then
    echo "官方地址下载失败，尝试代理地址……"
    curl -fL --connect-timeout 15 --retry 2 \
        "$MIHOMO_MIRROR" -o "$TMP/mihomo.gz"
fi

gzip -t "$TMP/mihomo.gz"
gzip -dc "$TMP/mihomo.gz" > "$TMP/mihomo"
chmod 0755 "$TMP/mihomo"

"$TMP/mihomo" -v

install -m 0755 "$TMP/mihomo" /usr/local/bin/mihomo

echo
echo "============================================================"
echo "5/8 下载订阅配置"
echo "============================================================"

mkdir -p /etc/mihomo
chmod 0755 /etc/mihomo

if [[ -f /etc/mihomo/config.yaml ]]; then
    cp -a /etc/mihomo/config.yaml \
        "$BACKUP/mihomo-config-before-install.yaml"
fi

if ! curl -fL --connect-timeout 20 --retry 3 \
    "$SUB_URL" -o "$TMP/config.yaml"; then
    echo "错误：订阅下载失败，原配置备份保留在 $BACKUP" >&2
    exit 1
fi

if [[ ! -s "$TMP/config.yaml" ]]; then
    echo "错误：订阅文件为空。" >&2
    exit 1
fi

# 确认下载内容是合法 YAML，并开启 TUN
python3 - "$TMP/config.yaml" "$TMP/config-tun.yaml" <<'PY'
import sys
import yaml

src, dst = sys.argv[1:3]

with open(src, "r", encoding="utf-8") as f:
    config = yaml.safe_load(f)

if not isinstance(config, dict):
    raise SystemExit("错误：订阅内容不是有效的 YAML 配置对象。")

tun = config.get("tun")
if tun is None:
    tun = {}
elif not isinstance(tun, dict):
    raise SystemExit("错误：订阅配置中的 tun 字段不是对象。")

tun["enable"] = True
tun["stack"] = "system"
tun["auto-route"] = True
tun["auto-detect-interface"] = True
config["tun"] = tun

with open(dst, "w", encoding="utf-8") as f:
    yaml.safe_dump(
        config,
        f,
        allow_unicode=True,
        sort_keys=False,
        default_flow_style=False,
    )
PY

install -m 0644 "$TMP/config-tun.yaml" /etc/mihomo/config.yaml
chown root:root /etc/mihomo/config.yaml

echo
echo "============================================================"
echo "6/8 配置 systemd 服务"
echo "============================================================"

cat > /etc/systemd/system/mihomo.service <<'UNIT'
[Unit]
Description=Mihomo Proxy Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo -f /etc/mihomo/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT

chmod 0644 /etc/systemd/system/mihomo.service

echo
echo "============================================================"
echo "7/8 验证配置并启动 Mihomo"
echo "============================================================"

/usr/local/bin/mihomo \
    -t -d /etc/mihomo -f /etc/mihomo/config.yaml

if [[ ! -e /dev/net/tun ]]; then
    mkdir -p /dev/net
    if ! mknod /dev/net/tun c 10 200 2>/dev/null; then
        echo "警告：无法创建 /dev/net/tun，请检查内核 TUN 支持。" >&2
    fi
    [[ ! -e /dev/net/tun ]] || chmod 0666 /dev/net/tun
fi

systemctl daemon-reload
systemctl enable --now mihomo
sleep 2

if ! systemctl is-active --quiet mihomo; then
    echo "错误：Mihomo 启动失败，最近日志如下：" >&2
    journalctl -u mihomo -n 80 --no-pager >&2 || true
    exit 1
fi

echo
echo "============================================================"
echo "8/8 完成检查"
echo "============================================================"

echo
echo "--- Node.js ---"
node --version
npm --version

echo
echo "--- Mihomo ---"
mihomo -v

echo
echo "--- 服务状态 ---"
systemctl --no-pager --full status mihomo

echo
echo "--- TUN 配置 ---"
grep -A 8 '^tun:' /etc/mihomo/config.yaml || true

echo
echo "--- 当前 shell 的代理环境变量 ---"
env | grep -iE '^(http|https|all|no)_proxy=' || echo "当前 shell 未设置代理环境变量"

echo
echo "安装完成。"
echo "配置文件：/etc/mihomo/config.yaml"
echo "服务日志：journalctl -u mihomo -f"
echo "备份目录：$BACKUP"
echo
echo "注意：本脚本清理的是常见系统配置文件中的代理项，"
echo "不会自动修改其他用户家目录、Docker 配置或应用程序内部代理设置。"
SCRIPT

# 复制 Node.js 安装脚本，供生成的安装脚本调用
cp "$(dirname "$0")/install_nodejs.sh" /root/install_nodejs.sh

chmod +x /root/install-mihomo.sh
bash /root/install-mihomo.sh
