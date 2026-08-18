#!/bin/bash
#
# ==========================================================================
# Xray Reality「偷自己」一键部署脚本  v3
#
#   全新 VPS 上一把跑通：装 Xray + 装 Caddy + Let's Encrypt 真证书
#   + Reality 偷自己 + 日志交给 journald（彻底免除文件权限/沙箱坑）
#
# 相比早期版本修正的坑（血泪教训）：
#   1. [日志] 不再写文件日志、不再 chown 属主 —— access/error 置空交给
#      journald。根除 "access.log: permission denied / status=23" 这一整类
#      故障（此前无论 chown nobody 还是 root 运行都会被 systemd 沙箱挡住）。
#   2. [健壮] 不用会"连坐静默退出"的 set -e；关键步骤逐一显式检查返回值，
#      失败即明确报错，绝不"跑完却啥也没改"。
#   3. [校验] 结尾对 systemctl is-active 硬校验，不 active 就打印日志并退出，
#      不再"报告成功但服务其实没起来"。
#   4. [精简] 删除多余的 setcap / User=root 回退 —— 官方 unit 自带
#      AmbientCapabilities 让 nobody 直接绑 443，无需画蛇添足。
#   5. [伪装] serverNames 指向自有域名（偷自己），而非 apple/microsoft
#      这类会被 Xray 警告、易被 GFW 盯上的公共站点。
#
# 前置条件：
#   1. 域名 A 记录已指向本机 IP，Cloudflare 为【灰云 / DNS only】（非橙云）
#   2. 80 端口空闲（签证书用），443 将由 Xray 占用
#   3. Debian 11+/Ubuntu 22.04+/或 RHEL 系（dnf）
# ==========================================================================

set -uo pipefail   # 注意：不用 -e，避免某步非零退出把整个脚本静默 kill

# ============================ 可配置项 ============================
DOMAIN="reality.metazsj.xyz"          # 你的伪装域名（偷自己），需已解析到本机
ACME_EMAIL="admin@metazsj.xyz"        # 证书到期通知邮箱，改成你的
CADDY_PORT="8443"                     # Caddy 内部端口（不对外）
XRAY_CONFIG="/usr/local/etc/xray/config.json"
INFO_FILE="/root/xray-info.txt"
WEB_ROOT="/var/www/reality"
# =================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;36m'; NC='\033[0m'
step()  { echo -e "\n${BLUE}▶ $*${NC}"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[✗] $*${NC}" >&2; exit 1; }

echo "=================================================="
echo "  Xray Reality 偷自己 一键部署 v3 —— $DOMAIN"
echo "=================================================="

# ============================================================
step "[1/8] 前置检查"
# ============================================================
[[ $EUID -eq 0 ]] || die "请以 root 运行：sudo bash $0"

# 识别包管理器
if   command -v apt-get >/dev/null 2>&1; then PM="apt"
elif command -v dnf     >/dev/null 2>&1; then PM="dnf"
else die "未识别包管理器（仅支持 apt / dnf）"; fi
ok "包管理器：$PM"

# 装基础依赖
install_pkgs() {
    if [[ "$PM" == "apt" ]]; then
        apt-get update -qq && apt-get install -y "$@" >/dev/null
    else
        dnf install -y "$@" >/dev/null
    fi
}
NEED=()
for c in curl jq openssl; do command -v "$c" >/dev/null 2>&1 || NEED+=("$c"); done
if [[ ${#NEED[@]} -gt 0 ]]; then
    step "安装依赖：${NEED[*]}"
    install_pkgs "${NEED[@]}" || die "依赖安装失败：${NEED[*]}"
fi
ok "基础依赖就绪"

# 检测公网 IPv4
VPS_IP=""
for ep in "https://api.ipify.org" "https://ifconfig.me/ip" "https://api.ip.sb/ip"; do
    VPS_IP=$(curl -4 -s --connect-timeout 5 --max-time 8 "$ep" 2>/dev/null | tr -d '[:space:]')
    [[ "$VPS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
    VPS_IP=""
done
[[ -n "$VPS_IP" ]] || die "无法获取本机公网 IPv4，请检查网络"
ok "本机公网 IP：$VPS_IP"

# 校验域名解析
RESOLVED=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | head -1)
if [[ -z "$RESOLVED" ]]; then
    die "$DOMAIN 无法解析。请确认 Cloudflare 已加 A 记录并等待 1-2 分钟生效。"
elif [[ "$RESOLVED" != "$VPS_IP" ]]; then
    warn "$DOMAIN 解析到 $RESOLVED，但本机 IP 是 $VPS_IP"
    warn "偷自己要求 A 记录为【灰云 / DNS only】直连本机。若在 Cloudflare 看到橙色云朵，请点成灰色。"
    read -rp "$(echo -e "${YELLOW}仍继续？(证书很可能签发失败) [y/N]: ${NC}")" a
    [[ "$a" =~ ^[Yy]$ ]] || die "已中止，请修正 DNS 后重试。"
else
    ok "解析正确：$DOMAIN → $VPS_IP（灰云直连）"
fi

# 端口检查
port_busy() { ss -tlnH "sport = :$1" 2>/dev/null | grep -q .; }
port_busy 80 && die "80 端口被占用（签证书需要）。释放后重试：ss -tlnp | grep :80"
port_busy "$CADDY_PORT" && die "$CADDY_PORT 端口被占用。请改 CADDY_PORT 或释放。"
ok "端口 80 与 $CADDY_PORT 空闲"

# ============================================================
step "[2/8] 安装 Xray-core"
# ============================================================
if command -v xray >/dev/null 2>&1; then
    ok "Xray 已安装：$(xray version 2>/dev/null | head -1)"
else
    tmp=$(mktemp --suffix=.sh)
    got=false
    for url in \
        "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" \
        "https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"; do
        if curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$tmp" \
           && [[ "$(head -c2 "$tmp")" == "#!" ]]; then got=true; break; fi
    done
    [[ "$got" == true ]] || { rm -f "$tmp"; die "Xray 安装脚本下载失败（GitHub 不通？）"; }
    bash "$tmp" install; rc=$?
    rm -f "$tmp"
    [[ $rc -eq 0 ]] && command -v xray >/dev/null 2>&1 || die "Xray 安装失败"
    ok "Xray 安装完成：$(xray version 2>/dev/null | head -1)"
fi

# ============================================================
step "[3/8] 生成密钥与配置参数"
# ============================================================
UUID=$(xray uuid)
KEYS=$(xray x25519)
# 兼容多版本 x25519 输出（Private key / PrivateKey / Password(PublicKey)）
PRIVATE_KEY=$(echo "$KEYS" | grep -iE '^Private' | awk -F: '{print $NF}' | tr -d ' ')
PUBLIC_KEY=$(echo "$KEYS"  | grep -iE '^(Public|Password)' | awk -F': ' '{print $NF}' | tr -d ' ')
SHORT_ID=$(openssl rand -hex 8)
[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "密钥生成失败，x25519 输出：$KEYS"
ok "UUID / x25519 密钥 / ShortID 生成完毕"

# ============================================================
step "[4/8] 安装 Caddy"
# ============================================================
if command -v caddy >/dev/null 2>&1; then
    ok "Caddy 已安装：$(caddy version | head -1)"
else
    if [[ "$PM" == "apt" ]]; then
        install_pkgs debian-keyring debian-archive-keyring apt-transport-https gnupg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list
        apt-get update -qq && apt-get install -y caddy >/dev/null
    else
        dnf install -y 'dnf-command(copr)' >/dev/null
        dnf copr enable -y @caddy/caddy >/dev/null
        dnf install -y caddy >/dev/null
    fi
    command -v caddy >/dev/null 2>&1 || die "Caddy 安装失败（到 dl.cloudsmith.io 网络不通？）"
    ok "Caddy 安装完成：$(caddy version | head -1)"
fi

# ============================================================
step "[5/8] 配置 Caddy 并签发证书"
# ============================================================
mkdir -p "$WEB_ROOT"
cat > "$WEB_ROOT/index.html" <<'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Welcome</title>
<style>body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;margin:0;
display:flex;min-height:100vh;align-items:center;justify-content:center;background:#f5f6f8;color:#333}
.b{text-align:center}h1{font-weight:600;margin:0 0 .5rem}p{color:#888;margin:0}</style></head>
<body><div class="b"><h1>It works!</h1><p>This site is up and running.</p></div></body></html>
HTML

cat > /etc/caddy/Caddyfile <<EOF
{
    email $ACME_EMAIL
    admin off
    auto_https disable_redirects
}

$DOMAIN:$CADDY_PORT {
    root * $WEB_ROOT
    file_server
    encode gzip
    header {
        Strict-Transport-Security "max-age=31536000"
        -Server
    }
}
EOF

caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || die "Caddyfile 校验失败"

# 放行 80（签证书 + 自动续期需要）
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1
    ok "firewalld 放行 80/tcp"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q active; then
    ufw allow 80/tcp >/dev/null 2>&1; ok "ufw 放行 80/tcp"
elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null \
        || iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null
    ok "iptables 放行 80/tcp（重启可能失效，需要 netfilter-persistent 持久化）"
else
    warn "未检测到本机防火墙，请确认云安全组已放行 80/tcp，否则证书签发失败"
fi

systemctl enable caddy >/dev/null 2>&1
systemctl restart caddy
sleep 3

# 轮询验证证书就绪
CERT_OK=false
for _ in $(seq 1 20); do
    if curl -s --max-time 5 --resolve "$DOMAIN:$CADDY_PORT:127.0.0.1" \
        "https://$DOMAIN:$CADDY_PORT/" -o /dev/null 2>/dev/null; then
        CERT_OK=true; break
    fi
    sleep 3
done
if [[ "$CERT_OK" != true ]]; then
    warn "证书签发/验证失败，Caddy 最近日志："
    journalctl -u caddy -n 25 --no-pager | sed 's/^/    /'
    die "排查：80 是否对公网开放；$DOMAIN 是否灰云直连本机。修正后重跑。"
fi
ok "证书签发成功，$DOMAIN 已就绪（TLS1.3 + H2）"

# ============================================================
step "[6/8] 写入 Xray Reality 配置（日志交给 journald）"
# ============================================================
# 关键：access/error 留空 → Xray 不打开日志文件 → 从根上免除
# permission denied / systemd 沙箱只读路径 这一整类故障。日志用 journalctl 看。
mkdir -p "$(dirname "$XRAY_CONFIG")"
cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "",
    "error": ""
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "tag": "vless-reality",
      "settings": {
        "clients": [
          { "id": "$UUID", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "127.0.0.1:$CADDY_PORT",
          "xver": 0,
          "serverNames": ["$DOMAIN"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID", ""]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF

# 启动前校验配置合法性
if ! xray -test -config "$XRAY_CONFIG" 2>/tmp/xray-test.err; then
    warn "Xray 配置校验未通过："
    sed 's/^/    /' /tmp/xray-test.err
    die "请检查 $XRAY_CONFIG"
fi
ok "Xray 配置写入并校验通过"

# ============================================================
step "[7/8] 内核 BBR 调优（可选，容器内可能无效不影响主流程）"
# ============================================================
if ! lsmod | grep -q '^tcp_bbr '; then modprobe tcp_bbr 2>/dev/null && echo tcp_bbr > /etc/modules-load.d/bbr.conf; fi
cat > /etc/sysctl.d/99-xray-bbr.conf <<'SC'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SC
sysctl -p /etc/sysctl.d/99-xray-bbr.conf >/dev/null 2>&1
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
[[ "$CC" == bbr ]] && ok "BBR 已启用" || warn "BBR 未生效（cc=$CC，可能受容器内核限制，不影响使用）"

# ============================================================
step "[8/8] 启动 Xray 并硬校验"
# ============================================================
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 3
if ! systemctl is-active --quiet xray; then
    warn "Xray 未能启动，最近日志："
    journalctl -u xray -n 25 --no-pager | sed 's/^/    /'
    die "启动失败。请把上面日志贴出来排查。"
fi
ok "Xray 已启动（active/running）"

# ---------- 输出客户端信息 ----------
SHARE_LINK="vless://${UUID}@${VPS_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-${DOMAIN}"

cat > "$INFO_FILE" <<INFO
Xray Reality 偷自己 —— 部署信息
生成时间: $(date)

服务端:
- Xray Reality  :443 → dest 127.0.0.1:$CADDY_PORT
- Caddy         :$CADDY_PORT → $DOMAIN (Let's Encrypt)
- 日志: journalctl -u xray -f  (不写文件)

客户端:
- 地址: $VPS_IP
- 端口: 443
- UUID: $UUID
- Public Key: $PUBLIC_KEY
- Short ID: $SHORT_ID
- SNI: $DOMAIN
- Flow: xtls-rprx-vision
- Fingerprint: chrome

分享链接:
$SHARE_LINK
INFO
chmod 600 "$INFO_FILE"

echo ""
echo -e "${GREEN}=================== 部署完成 ===================${NC}"
echo -e "  地址(Address) : ${BLUE}$VPS_IP${NC}"
echo -e "  端口(Port)    : ${BLUE}443${NC}"
echo -e "  UUID          : ${BLUE}$UUID${NC}"
echo -e "  Public Key    : ${BLUE}$PUBLIC_KEY${NC}"
echo -e "  Short ID      : ${BLUE}$SHORT_ID${NC}"
echo -e "  SNI / 域名     : ${BLUE}$DOMAIN${NC}"
echo -e "  Flow          : xtls-rprx-vision   Fingerprint: chrome"
echo ""
echo -e "${GREEN}VLESS 链接（导入客户端）：${NC}"
echo "$SHARE_LINK"
echo ""
echo -e "信息已保存到 ${INFO_FILE}（仅 root 可读）"
echo -e "验证：浏览器访问 https://$DOMAIN 应看到 \"It works!\"；客户端需用 Clash.Meta/mihomo 或 v2rayN 等支持 Reality 的内核。"
echo -e "${YELLOW}提醒：请保持 80 端口对公网开放，Caddy 证书 90 天自动续期依赖它。${NC}"
