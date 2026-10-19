#!/usr/bin/env bash
set -Eeuo pipefail

# 新订阅地址
NEW_SUB_URL='https://gh-proxy.com/https://raw.githubusercontent.com/hello-world-1989/cn-news/refs/heads/main/clash-free.yaml'

CONFIG='/etc/mihomo/config.yaml'
TMP="$(mktemp)"
WORK="$(mktemp)"
BACKUP="${CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

cleanup() {
    rm -f "$TMP" "$WORK"
}
trap cleanup EXIT

if [[ "$(id -u)" -ne 0 ]]; then
    echo "请使用 root 权限运行：sudo bash mihomo_sub.sh" >&2
    exit 1
fi

echo '==> 1. 下载新订阅'
curl -fL --retry 3 --connect-timeout 20 \
    "$NEW_SUB_URL" -o "$TMP"

echo '==> 2. 检查 YAML 并补充代理规则'
python3 - "$TMP" "$WORK" <<'PY'
import sys
import yaml

src, dst = sys.argv[1:3]

with open(src, encoding="utf-8") as f:
    c = yaml.safe_load(f)

if not isinstance(c, dict):
    raise SystemExit("错误：订阅内容不是有效的 YAML 配置")

groups = c.get("proxy-groups", [])
if not isinstance(groups, list) or not groups:
    raise SystemExit("错误：订阅没有 proxy-groups，无法确定代理组")

group_names = [
    g.get("name") for g in groups
    if isinstance(g, dict) and isinstance(g.get("name"), str)
]
if not group_names:
    raise SystemExit("错误：没有找到有效的代理组名称")

# 优先选择常见的手动节点选择组。
# 找不到时使用订阅中的第一个代理组。
preferred = [
    "🚀 节点选择",
    "节点选择",
    "Proxy",
    "PROXY",
    "proxy",
    "手动选择",
]
proxy_group = next(
    (name for name in preferred if name in group_names),
    group_names[0],
)

rules = c.get("rules", [])
if not isinstance(rules, list):
    raise SystemExit("错误：rules 字段不是列表")

# 保留原规则顺序，移除终结性的 MATCH / FINAL，
# 稍后统一添加 MATCH,代理组。
kept = []
removed = []

for rule in rules:
    if isinstance(rule, str):
        parts = [x.strip() for x in rule.split(",")]
        rule_type = parts[0].upper() if parts else ""
        if rule_type in ("MATCH", "FINAL"):
            removed.append(rule)
            continue
    kept.append(rule)

# 常见私有网络及本地域名直连规则。
# 放在现有规则前面，避免它们被前面的代理规则抢先匹配。
local_rules = [
    "DOMAIN,localhost,DIRECT",
    "DOMAIN-SUFFIX,local,DIRECT",
    "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
    "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
    "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
    "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
    "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
]

# 避免重复插入这些本地规则
existing = set(x for x in kept if isinstance(x, str))
local_rules = [x for x in local_rules if x not in existing]

c["rules"] = local_rules + kept + [f"MATCH,{proxy_group}"]

# 开启 TUN
tun = c.get("tun")
if tun is None:
    tun = {}
if not isinstance(tun, dict):
    raise SystemExit("错误：tun 字段格式不正确")

tun["enable"] = True
tun["stack"] = "system"
tun["auto-route"] = True
tun["auto-detect-interface"] = True
c["tun"] = tun

# 确保有控制接口，供本机管理；仅监听 localhost
c["external-controller"] = "127.0.0.1:9090"

with open(dst, "w", encoding="utf-8") as f:
    yaml.safe_dump(
        c,
        f,
        allow_unicode=True,
        sort_keys=False,
        default_flow_style=False,
    )

print("选用的兜底代理组：", proxy_group)
print("移除的旧兜底规则：", removed if removed else "无")
print("新兜底规则：MATCH," + proxy_group)
print("原有其他规则及代理组已保留")
PY

echo '==> 3. 备份当前配置'
if [[ -f "$CONFIG" ]]; then
    cp -a "$CONFIG" "$BACKUP"
    echo "旧配置备份：$BACKUP"
fi

echo '==> 4. 验证新配置'
mihomo -t -d /etc/mihomo -f "$WORK"

echo '==> 5. 安装新配置'
install -o root -g root -m 0644 "$WORK" "$CONFIG"

echo '==> 6. 重启 Mihomo'
systemctl enable mihomo
systemctl restart mihomo

sleep 2
if ! systemctl is-active --quiet mihomo; then
    echo '错误：Mihomo 启动失败，恢复旧配置。' >&2
    if [[ -f "$BACKUP" ]]; then
        install -o root -g root -m 0644 "$BACKUP" "$CONFIG"
        systemctl restart mihomo || true
    fi
    journalctl -u mihomo -n 60 --no-pager
    exit 1
fi

echo '==> 7. 检查结果'
systemctl --no-pager --full status mihomo
echo
echo '当前最终规则：'
grep -nE 'MATCH|FINAL' "$CONFIG" || true
echo
echo '控制接口：127.0.0.1:9090'
echo '完成。'

