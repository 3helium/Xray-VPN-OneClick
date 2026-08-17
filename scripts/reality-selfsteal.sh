#!/bin/bash
#
# ==========================================================================
# Reality "偷自己" 一键部署脚本
#   自动: 安装 Caddy + Let's Encrypt 签真证书 + 改 Xray Reality 配置
#
# 架构:
#   [客户端] --443--> [Xray Reality] --dest--> [127.0.0.1:8443 本地 Caddy]
#   Caddy 用 Let's Encrypt 给你的域名签真证书(HTTP-01 走 80 端口)
#   握手借用你自己域名的合法证书 —— SNI/IP/证书三者自洽,无 CDN 破绽
#
# 前置条件(运行前必须满足):
#   1. 已安装 Xray 且 /usr/local/etc/xray/config.json 是 VLESS+Reality 配置
#   2. 域名 A 记录已指向本机 IP,且在 Cloudflare 是【灰云 / DNS only】(非橙云)
#   3. 80 端口空闲(签证书用),443 端口归 Xray
# ==========================================================================

set -euo pipefail

# ============================ 可配置项 ============================
DOMAIN="reality.metazsj.xyz"          # 你的伪装域名(偷自己)
ACME_EMAIL="admin@metazsj.xyz"        # 证书到期通知邮箱,改成你的(无需真实收件也能签发)
CADDY_PORT="8443"                     # Caddy 内部监听端口(不对外)
XRAY_CONFIG="/usr/local/etc/xray/config.json"
INFO_FILE="/root/xray-info.txt"
WEB_ROOT="/var/www/reality"
# =================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

echo "=========================================="
echo "  Reality 偷自己 一键部署 —— $DOMAIN"
echo "=========================================="

# ============================================================
# [0/6] 前置检查
# ============================================================
info "[0/6] 前置检查..."

[[ $EUID -eq 0 ]] || die "请以 root 运行: sudo bash $0"

command -v xray >/dev/null 2>&1 || die "未找到 xray,请先完成 Xray 安装"
[[ -f "$XRAY_CONFIG" ]] || die "未找到 Xray 配置文件: $XRAY_CONFIG"

# 确认是 Reality 配置
if ! grep -q '"security"[[:space:]]*:[[:space:]]*"reality"' "$XRAY_CONFIG"; then
    die "配置文件不像 Reality 配置(未找到 security=reality),请检查 $XRAY_CONFIG"
fi

# 安装缺失的基础工具
NEED_PKGS=()
command -v jq   >/dev/null 2>&1 || NEED_PKGS+=("jq")
command -v curl >/dev/null 2>&1 || NEED_PKGS+=("curl")
if [[ ${#NEED_PKGS[@]} -gt 0 ]]; then
    info "安装依赖: ${NEED_PKGS[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y "${NEED_PKGS[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${NEED_PKGS[@]}"
    else
        die "无法自动安装依赖(未识别包管理器),请手动安装: ${NEED_PKGS[*]}"
    fi
fi

# 检测本机公网 IPv4
info "检测本机公网 IP..."
VPS_IP=""
for ep in "https://api.ipify.org" "https://ifconfig.me/ip" "https://api.ip.sb/ip"; do
    VPS_IP=$(curl -4 -s --connect-timeout 5 --max-time 8 "$ep" 2>/dev/null | tr -d '[:space:]' || true)
    [[ "$VPS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
    VPS_IP=""
done
[[ -n "$VPS_IP" ]] || die "无法获取本机公网 IPv4,请检查网络"
ok "本机公网 IP: $VPS_IP"

# 校验域名解析是否指向本机(顺便识别橙云代理)
info "校验 $DOMAIN 解析..."
RESOLVED=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | head -1 || true)
if [[ -z "$RESOLVED" ]]; then
    die "域名 $DOMAIN 无法解析。请确认已在 Cloudflare 添加 A 记录,并等待 1-2 分钟生效。"
elif [[ "$RESOLVED" != "$VPS_IP" ]]; then
    warn "域名解析到 $RESOLVED,但本机 IP 是 $VPS_IP —— 二者不一致!"
    warn "偷自己要求 A 记录为【灰云 / DNS only】直接指向本机。"
    warn "若你在 Cloudflare 看到【橙色云朵】,请点它切成【灰色云朵】后重试。"
    read -rp "$(echo -e ${YELLOW}"仍要继续吗? (证书很可能签发失败) [y/N]: "${NC})" ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "已中止。请修正 DNS 后重新运行。"
else
    ok "解析正确: $DOMAIN → $VPS_IP (灰云直连)"
fi

# 检查端口占用
check_port_free() {
    local p="$1" who
    who=$(ss -tlnpH "sport = :$p" 2>/dev/null || true)
    if [[ -n "$who" ]]; then
        warn "端口 $p 已被占用:"; echo "$who" | sed 's/^/    /'
        return 1
    fi
    return 0
}
check_port_free 80          || die "80 端口被占用,签证书需要它。请先释放 80 端口。"
check_port_free "$CADDY_PORT" || die "$CADDY_PORT 端口被占用。请改脚本顶部 CADDY_PORT 或释放该端口。"
ok "端口 80 与 $CADDY_PORT 均空闲"

# ============================================================
# [1/6] 安装 Caddy
# ============================================================
info "[1/6] 安装 Caddy..."
if command -v caddy >/dev/null 2>&1; then
    ok "Caddy 已安装: $(caddy version | head -1)"
else
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list
        apt-get update -qq
        apt-get install -y caddy
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y 'dnf-command(copr)'
        dnf copr enable -y @caddy/caddy
        dnf install -y caddy
    else
        die "未识别包管理器,无法自动安装 Caddy"
    fi
    command -v caddy >/dev/null 2>&1 || die "Caddy 安装失败,请检查网络到 dl.cloudsmith.io 是否通畅"
    ok "Caddy 安装完成: $(caddy version | head -1)"
fi

# ============================================================
# [2/6] 生成兜底站点页面 + Caddyfile
# ============================================================
info "[2/6] 写入 Caddy 配置与兜底页面..."

mkdir -p "$WEB_ROOT"
cat > "$WEB_ROOT/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Welcome</title>
  <style>
    body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
         margin:0;display:flex;min-height:100vh;align-items:center;
         justify-content:center;background:#f5f6f8;color:#333}
    .box{text-align:center;padding:2rem}
    h1{font-weight:600;margin:0 0 .5rem}
    p{color:#888;margin:0}
  </style>
</head>
<body>
  <div class="box">
    <h1>It works!</h1>
    <p>This site is up and running.</p>
  </div>
</body>
</html>
HTML

# Caddyfile:
#   - auto_https disable_redirects: 只管证书,不抢占 80 做跳转 vhost(签证书时仍临时用 80)
#   - admin off: 关闭 Caddy 管理 API(2019 端口),减小暴露面
#   - 站点监听 CADDY_PORT,443 由 Xray 占用,故证书走 HTTP-01(80 端口)
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

# 校验 Caddyfile 语法
caddy validate --config /etc/caddy/Caddyfile 2>/dev/null \
    || die "Caddyfile 校验失败,请检查 /etc/caddy/Caddyfile"
ok "Caddy 配置已写入并通过校验"

# ============================================================
# [3/6] 放行防火墙 80 端口(签证书 + 自动续期需要)
# ============================================================
info "[3/6] 放行防火墙 80/tcp..."
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld 已放行 80/tcp"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ok "ufw 已放行 80/tcp"
elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null \
        || iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    ok "iptables 已放行 80/tcp(重启后可能失效,如需持久化请装 netfilter-persistent)"
else
    warn "未检测到本机防火墙。请确认云厂商安全组已放行 80/tcp,否则证书无法签发。"
fi

# ============================================================
# [4/6] 启动 Caddy 并等待证书签发
# ============================================================
info "[4/6] 启动 Caddy 并签发证书(首次可能需要 10-30 秒)..."
systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy
sleep 3

# 轮询验证:本机以正确 SNI 访问 8443,拿到合法证书即成功
CERT_OK=false
for _ in $(seq 1 20); do
    if curl -s --max-time 5 \
        --resolve "$DOMAIN:$CADDY_PORT:127.0.0.1" \
        "https://$DOMAIN:$CADDY_PORT/" -o /dev/null 2>/dev/null; then
        CERT_OK=true
        break
    fi
    sleep 3
done

if [[ "$CERT_OK" != true ]]; then
    warn "证书签发/验证未成功。最近的 Caddy 日志:"
    journalctl -u caddy -n 30 --no-pager | sed 's/^/    /'
    die "请排查: 80 端口是否对公网开放; $DOMAIN 是否灰云直连本机。修正后重跑本脚本。"
fi
ok "Caddy 已就绪,$DOMAIN 证书签发成功(TLS1.3 + H2)"

# ============================================================
# [5/6] 改写 Xray Reality 配置(dest / serverNames)+ 修日志权限
# ============================================================
info "[5/6] 更新 Xray Reality 配置..."

# 备份
cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"

# 用 jq 安全改写: dest 指向本地 Caddy, serverNames 换成本域名
jq --arg dest "127.0.0.1:$CADDY_PORT" --arg sni "$DOMAIN" '
    .inbounds[0].streamSettings.realitySettings.dest = $dest
  | .inbounds[0].streamSettings.realitySettings.serverNames = [$sni]
' "$XRAY_CONFIG" > /tmp/xray-new.json \
    || die "jq 改写配置失败"
mv /tmp/xray-new.json "$XRAY_CONFIG"
ok "已设置 dest=127.0.0.1:$CADDY_PORT, serverNames=[$DOMAIN]"

# 修复日志权限(上一版脚本的 nobody:nobody bug)
# Xray 官方 unit 默认以 nobody 运行,Debian/Ubuntu 上 nobody 的组是 nogroup。
# chown 到 nobody:nogroup 后:nobody 运行可写;若服务改成 root 运行,root 亦可写。
mkdir -p /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log
chown -R nobody:nogroup /var/log/xray 2>/dev/null || chown -R nobody /var/log/xray 2>/dev/null || true
chmod 750 /var/log/xray
chmod 640 /var/log/xray/*.log
ok "日志目录权限已修正 (owner=nobody, 750/640)"

# 启动前校验 Xray 配置
if ! xray -test -config "$XRAY_CONFIG" 2>/tmp/xray-test.err; then
    warn "Xray 配置校验未通过:"
    sed 's/^/    /' /tmp/xray-test.err
    die "已保留备份 ${XRAY_CONFIG}.bak.*,请排查后重试。"
fi
ok "Xray 配置校验通过"

# ============================================================
# [6/6] 重启 Xray 并输出客户端信息
# ============================================================
info "[6/6] 重启 Xray..."
systemctl restart xray
sleep 3
systemctl is-active --quiet xray || {
    warn "Xray 未能启动,最近日志:"
    journalctl -u xray -n 30 --no-pager | sed 's/^/    /'
    die "启动失败。可回滚: cp ${XRAY_CONFIG}.bak.* $XRAY_CONFIG && systemctl restart xray"
}
ok "Xray 已启动 (active/running)"

# 从配置提取客户端参数
UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // ""' "$XRAY_CONFIG")
PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")

# 公钥: 优先读 info 文件,读不到则用私钥反推
PUBLIC_KEY=""
if [[ -f "$INFO_FILE" ]]; then
    PUBLIC_KEY=$(grep -i "Public Key" "$INFO_FILE" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ' | head -1 || true)
fi
if [[ -z "$PUBLIC_KEY" ]] && [[ -n "$PRIVATE_KEY" ]]; then
    PUB_OUT=$(xray x25519 -i "$PRIVATE_KEY" 2>/dev/null || true)
    PUBLIC_KEY=$(echo "$PUB_OUT" | grep -iE "public|password" | awk -F': ' '{print $NF}' | tr -d ' ' | head -1 || true)
fi

SHARE_LINK="vless://${UUID}@${VPS_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-selfsteal"

echo ""
echo "=========================================="
ok  "部署完成!Reality 已切换为「偷自己」模式"
echo "=========================================="
echo ""
echo "📋 服务端:"
echo "   Xray Reality  :443  →  dest 127.0.0.1:$CADDY_PORT (本地 Caddy)"
echo "   Caddy         :$CADDY_PORT  →  $DOMAIN (Let's Encrypt 真证书)"
echo ""
echo "🔑 客户端配置(相比之前,只有 SNI 变了):"
echo "   地址(Address) : $VPS_IP"
echo "   端口(Port)    : 443"
echo "   UUID          : $UUID"
echo "   Public Key    : ${PUBLIC_KEY:-<读取失败,请手动填之前保存的公钥>}"
echo "   Short ID      : $SHORT_ID"
echo "   SNI / 域名     : $DOMAIN   ← 改成这个"
echo "   Flow          : xtls-rprx-vision"
echo "   Fingerprint   : chrome"
echo ""
echo "📱 分享链接:"
echo "   $SHARE_LINK"
echo ""

# 更新 info 文件
cat > "$INFO_FILE" <<INFO
Xray Reality 配置信息(偷自己模式)
更新时间: $(date)

服务端:
- Xray Reality 监听 443, dest=127.0.0.1:$CADDY_PORT
- Caddy 监听 $CADDY_PORT, 域名 $DOMAIN (Let's Encrypt)

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

管理命令:
- Xray:  systemctl {status|restart} xray  |  journalctl -u xray -f
- Caddy: systemctl {status|restart} caddy |  journalctl -u caddy -f
- 证书由 Caddy 自动续期(需保持 80 端口对公网开放)
INFO
chmod 600 "$INFO_FILE"
echo "ℹ️  信息已保存到 $INFO_FILE (仅 root 可读)"
echo ""
echo "验证提示: 浏览器访问 https://$DOMAIN 应能看到 \"It works!\" 页面。"
