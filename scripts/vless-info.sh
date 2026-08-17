#!/bin/bash
#
# ==========================================================================
# vless-info.sh —— 读取本机 Xray Reality 配置，输出客户端信息与 VLESS 链接
#
# 用法:  sudo bash vless-info.sh
#   - 自动从 /usr/local/etc/xray/config.json 读取参数
#   - 公钥(pbk)配置文件里没有，脚本用私钥反推；反推不到则回退读 /root/xray-info.txt
#   - 每个 client 都会输出一条链接（支持多用户）
# ==========================================================================

set -uo pipefail

CFG="${1:-/usr/local/etc/xray/config.json}"
INFO_FILE="/root/xray-info.txt"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;36m'; NC='\033[0m'

# ---------- 前置检查 ----------
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}未找到 jq，请先安装：apt-get install -y jq  或  dnf install -y jq${NC}" >&2
    exit 1
fi
if [[ ! -f "$CFG" ]]; then
    echo -e "${RED}未找到配置文件: $CFG${NC}" >&2
    exit 1
fi
if ! jq empty "$CFG" 2>/dev/null; then
    echo -e "${RED}配置文件不是合法 JSON: $CFG${NC}" >&2
    exit 1
fi

# ---------- 定位 Reality inbound ----------
# 找到第一个 security=reality 的 inbound 下标（不假设它是 inbounds[0]）
IDX=$(jq -r '[.inbounds | to_entries[] | select(.value.streamSettings.security=="reality") | .key][0] // empty' "$CFG")
if [[ -z "$IDX" ]]; then
    echo -e "${RED}配置里没有找到 security=reality 的 inbound${NC}" >&2
    exit 1
fi

# ---------- 读取公共参数 ----------
PORT=$(jq -r ".inbounds[$IDX].port" "$CFG")
SNI=$(jq -r ".inbounds[$IDX].streamSettings.realitySettings.serverNames[0] // \"\"" "$CFG")
SID=$(jq -r ".inbounds[$IDX].streamSettings.realitySettings.shortIds[0] // \"\"" "$CFG")
PRIV=$(jq -r ".inbounds[$IDX].streamSettings.realitySettings.privateKey // \"\"" "$CFG")
NETWORK=$(jq -r ".inbounds[$IDX].streamSettings.network // \"tcp\"" "$CFG")

# ---------- 反推公钥 ----------
PBK=""
if [[ -n "$PRIV" ]] && command -v xray >/dev/null 2>&1; then
    PBK=$(xray x25519 -i "$PRIV" 2>/dev/null \
          | grep -iE 'public|password' | awk -F': ' '{print $NF}' | tr -d ' ' | head -1 || true)
fi
# 反推失败则回退读 info 文件
if [[ -z "$PBK" && -f "$INFO_FILE" ]]; then
    PBK=$(grep -i "Public Key" "$INFO_FILE" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ' | head -1 || true)
fi

# ---------- 取本机公网 IP（优先 IPv4，回退 IPv6）----------
IP=""; IP_IS_V6=false
for ep in "https://api.ipify.org" "https://ifconfig.me/ip" "https://api.ip.sb/ip"; do
    IP=$(curl -4 -s --connect-timeout 5 --max-time 8 "$ep" 2>/dev/null | tr -d '[:space:]' || true)
    [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
    IP=""
done
if [[ -z "$IP" ]]; then
    for ep in "https://api6.ipify.org" "https://ifconfig.me/ip"; do
        IP=$(curl -6 -s --connect-timeout 5 --max-time 8 "$ep" 2>/dev/null | tr -d '[:space:]' || true)
        [[ "$IP" == *:* ]] && { IP_IS_V6=true; break; }
        IP=""
    done
fi
# 链接里 IPv6 需用方括号包裹
if [[ "$IP_IS_V6" == true ]]; then HOST="[$IP]"; else HOST="$IP"; fi

# ---------- 输出 ----------
echo ""
echo -e "${GREEN}==================== Reality 服务端信息 ====================${NC}"
echo -e "  地址(Address) : ${BLUE}${IP:-<获取失败,请手动填 VPS IP>}${NC}"
echo -e "  端口(Port)    : ${BLUE}${PORT}${NC}"
echo -e "  SNI / 域名     : ${BLUE}${SNI}${NC}"
echo -e "  传输(Network) : ${NETWORK}"
echo -e "  流控(Flow)    : xtls-rprx-vision"
echo -e "  指纹(fp)      : chrome"
echo -e "  Public Key    : ${BLUE}${PBK:-<读取失败,见下方提示>}${NC}"
echo -e "  Short ID      : ${BLUE}${SID}${NC}"

# 缺关键字段时给提示
[[ -z "$SNI" ]] && echo -e "${YELLOW}  ! serverNames 为空，请检查配置${NC}"
[[ -z "$PBK" ]] && echo -e "${YELLOW}  ! 公钥反推失败：请打开 ${INFO_FILE} 找到当时保存的 Public Key，手动填入链接的 pbk=${NC}"
[[ -z "$IP"  ]] && echo -e "${YELLOW}  ! 未能自动获取公网 IP，请把链接里的地址替换成你的 VPS IP${NC}"

# ---------- 逐个 client 生成链接 ----------
CLIENT_COUNT=$(jq -r ".inbounds[$IDX].settings.clients | length" "$CFG")
echo ""
echo -e "${GREEN}==================== VLESS 链接（导入客户端）====================${NC}"
for ((c=0; c<CLIENT_COUNT; c++)); do
    UUID=$(jq -r ".inbounds[$IDX].settings.clients[$c].id" "$CFG")
    FLOW=$(jq -r ".inbounds[$IDX].settings.clients[$c].flow // \"xtls-rprx-vision\"" "$CFG")
    EMAIL=$(jq -r ".inbounds[$IDX].settings.clients[$c].email // \"\"" "$CFG")
    TAG="Reality-${SNI:-node}"
    [[ -n "$EMAIL" && "$EMAIL" != "user@example.com" ]] && TAG="$EMAIL"

    LINK="vless://${UUID}@${HOST}:${PORT}?encryption=none&flow=${FLOW}&security=reality&sni=${SNI}&fp=chrome&pbk=${PBK}&sid=${SID}&type=${NETWORK}&headerType=none#${TAG}"

    if [[ "$CLIENT_COUNT" -gt 1 ]]; then echo -e "${YELLOW}[客户端 $((c+1))/${CLIENT_COUNT}]${NC}"; fi
    echo "$LINK"
    echo ""
done

echo -e "${GREEN}导入方式：${NC}"'复制上面的 vless:// 链接，在 v2rayN / v2rayNG / Shadowrocket 等客户端选「从剪贴板导入」。'
