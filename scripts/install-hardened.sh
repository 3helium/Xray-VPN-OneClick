#!/bin/bash

# Xray 一键安装脚本
# 支持: Debian/Ubuntu/Kali/CentOS/AlmaLinux/Rocky/Fedora
# 版本: 2.0.0

set -e

# ============================================
# 内联的 OS 检测函数 (支持远程下载执行)
# ============================================

# Ensure PATH includes sbin directories
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Supported distributions and minimum versions
declare -A SUPPORTED_DISTROS=(
    ["ubuntu"]="22.04"
    ["debian"]="11"
    ["kali"]="2023"
    ["centos"]="9"
    ["almalinux"]="9"
    ["rocky"]="9"
    ["fedora"]="39"
    ["amzn"]="2023"
)

# OS family mapping
declare -A OS_FAMILY=(
    ["ubuntu"]="debian"
    ["debian"]="debian"
    ["kali"]="debian"
    ["centos"]="rhel"
    ["almalinux"]="rhel"
    ["rocky"]="rhel"
    ["fedora"]="rhel"
    ["amzn"]="rhel"
)

# Package manager mapping
declare -A PKG_MANAGER=(
    ["debian"]="apt"
    ["rhel"]="dnf"
)

# Global variables
OS_ID=""
OS_VERSION=""
OS_VERSION_ID=""
OS_FAMILY_TYPE=""
OS_PKG_MANAGER=""
OS_PRETTY_NAME=""

# Detect operating system from /etc/os-release
detect_os() {
    OS_ID=""
    OS_VERSION=""
    OS_VERSION_ID=""
    OS_FAMILY_TYPE=""
    OS_PKG_MANAGER=""
    OS_PRETTY_NAME=""

    if [[ -e /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID,,}"  # lowercase
        OS_VERSION="$VERSION"
        OS_VERSION_ID="$VERSION_ID"
        OS_PRETTY_NAME="$PRETTY_NAME"
    elif [[ -e /etc/almalinux-release ]]; then
        OS_ID="almalinux"
        OS_VERSION_ID=$(grep -oE '[0-9]+\.[0-9]+' /etc/almalinux-release | head -1)
    elif [[ -e /etc/rocky-release ]]; then
        OS_ID="rocky"
        OS_VERSION_ID=$(grep -oE '[0-9]+\.[0-9]+' /etc/rocky-release | head -1)
    elif [[ -e /etc/centos-release ]]; then
        OS_ID="centos"
        OS_VERSION_ID=$(grep -oE '[0-9]+' /etc/centos-release | head -1)
    elif [[ -e /etc/fedora-release ]]; then
        OS_ID="fedora"
        OS_VERSION_ID=$(grep -oE '[0-9]+' /etc/fedora-release | head -1)
    elif [[ -e /etc/debian_version ]]; then
        OS_ID="debian"
        OS_VERSION_ID=$(cat /etc/debian_version)
    fi

    # Set OS family and package manager
    if [[ -n "${OS_FAMILY[$OS_ID]}" ]]; then
        OS_FAMILY_TYPE="${OS_FAMILY[$OS_ID]}"
        OS_PKG_MANAGER="${PKG_MANAGER[$OS_FAMILY_TYPE]}"
    fi

    # Return success if OS was detected
    [[ -n "$OS_ID" ]]
}

# Check if the detected OS is supported
is_os_supported() {
    [[ -n "${SUPPORTED_DISTROS[$OS_ID]}" ]]
}

# Get minimum supported version for current OS
get_min_version() {
    echo "${SUPPORTED_DISTROS[$OS_ID]:-}"
}

# Compare version numbers (returns 0 if v1 >= v2)
version_ge() {
    local v1="$1" v2="$2"
    [[ "$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -n1)" == "$v2" ]]
}

# Check if current OS version meets minimum requirement
check_version_requirement() {
    local min_version
    min_version=$(get_min_version)
    [[ -z "$min_version" ]] && return 1
    version_ge "$OS_VERSION_ID" "$min_version"
}

# Print error for unsupported OS
print_unsupported_os_error() {
    echo ""
    echo "❌ 错误: 不支持的操作系统"
    echo "========================================"
    echo "检测到: ${OS_PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"
    echo ""
    echo "支持的系统:"
    echo "  - Ubuntu 22.04+"
    echo "  - Debian 11+"
    echo "  - Kali Linux 2023+"
    echo "  - CentOS Stream 9+"
    echo "  - AlmaLinux 9+"
    echo "  - Rocky Linux 9+"
    echo "  - Fedora 39+"
    echo "  - Amazon Linux 2023+"
    echo "========================================"
    echo ""
}

# Print error for version too low
print_version_too_low_error() {
    local min_version
    min_version=$(get_min_version)
    echo ""
    echo "❌ 错误: 系统版本过低"
    echo "========================================"
    echo "检测到: ${OS_PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"
    echo "最低要求: $OS_ID $min_version+"
    echo ""
    echo "请升级您的系统后重试。"
    echo "========================================"
    echo ""
}

# ============================================
# 内联的包管理器函数
# ============================================

# Install packages using the appropriate package manager
pkg_install() {
    case "$OS_PKG_MANAGER" in
        apt)
            apt-get update -qq
            apt-get install -y "$@"
            ;;
        dnf)
            dnf install -y "$@"
            ;;
        *)
            echo "错误: 未知的包管理器"
            return 1
            ;;
    esac
}

# Enable EPEL repository for RHEL-based systems
enable_epel() {
    if [[ "$OS_FAMILY_TYPE" == "rhel" && "$OS_ID" != "fedora" && "$OS_ID" != "amzn" ]]; then
        if ! rpm -q epel-release &>/dev/null; then
            echo "启用 EPEL 仓库..."
            dnf install -y epel-release || true
        fi
    fi
}

# ============================================
# 内联的环境检测函数
# ============================================

ENV_IS_CONTAINER="false"
ENV_CONTAINER_TYPE=""

detect_container() {
    ENV_IS_CONTAINER="false"
    ENV_CONTAINER_TYPE=""

    # Check for Docker
    if [[ -f /.dockerenv ]]; then
        ENV_IS_CONTAINER="true"
        ENV_CONTAINER_TYPE="docker"
        return 0
    fi

    # Check cgroup for container hints
    if grep -qE '(docker|lxc|kubepods)' /proc/1/cgroup 2>/dev/null; then
        ENV_IS_CONTAINER="true"
        if grep -q docker /proc/1/cgroup 2>/dev/null; then
            ENV_CONTAINER_TYPE="docker"
        elif grep -q lxc /proc/1/cgroup 2>/dev/null; then
            ENV_CONTAINER_TYPE="lxc"
        else
            ENV_CONTAINER_TYPE="unknown"
        fi
        return 0
    fi

    # Check for OpenVZ
    if [[ -d /proc/vz && ! -d /proc/bc ]]; then
        ENV_IS_CONTAINER="true"
        ENV_CONTAINER_TYPE="openvz"
        return 0
    fi

    # Not a container - return success (0) to avoid set -e exit
    return 0
}

# ============================================
# 主安装逻辑
# ============================================

echo "================================"
echo "Xray VLESS+Reality 一键安装脚本"
echo "================================"
echo ""

# 检查 shell 兼容性
if [[ -e /proc/$$/exe ]] && readlink /proc/$$/exe | grep -q "dash"; then
    echo "错误: 请使用 bash 运行此脚本"
    echo "使用命令: bash $0"
    exit 1
fi

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本"
  echo "使用命令: sudo bash $0"
  exit 1
fi

# 检测操作系统
echo "[0/5] 检测系统环境..."
detect_os
echo "检测到: ${OS_PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"
echo "系统家族: $OS_FAMILY_TYPE | 包管理器: $OS_PKG_MANAGER"

# 检查是否支持
if ! is_os_supported; then
    print_unsupported_os_error
    exit 1
fi

# 检查版本要求
if ! check_version_requirement; then
    print_version_too_low_error
    exit 1
fi

echo "✓ 系统检测通过"

# 检测容器环境
detect_container
if [[ "$ENV_IS_CONTAINER" == "true" ]]; then
    echo ""
    echo "⚠️  警告: 检测到容器环境 ($ENV_CONTAINER_TYPE)"
    echo "VPN 功能在容器中可能受限。"
    read -p "是否继续安装？[y/N] " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "安装已取消。"
        exit 0
    fi
fi

# RHEL 系列启用 EPEL
if [[ "$OS_FAMILY_TYPE" == "rhel" ]]; then
    echo ""
    echo "[1/5] 配置软件仓库..."
    enable_epel
fi

# 安装依赖
echo ""
echo "[1.5/5] 安装依赖..."
case "$OS_PKG_MANAGER" in
    apt)
        apt-get update -qq
        apt-get install -y curl unzip openssl
        ;;
    dnf)
        # Amazon Linux 2023 使用 curl-minimal，与 curl 冲突
        # 只安装缺失的包
        if [[ "$OS_ID" == "amzn" ]]; then
            dnf install -y unzip openssl || true
        else
            dnf install -y curl unzip openssl
        fi
        ;;
esac

# 安装 Xray
echo ""
echo "[2/5] 安装 Xray-core..."

# 检查是否需要强制重装（如果服务文件不存在）
FORCE_INSTALL=""
if [[ ! -f /etc/systemd/system/xray.service ]] && [[ ! -f /etc/systemd/system/xray@.service ]]; then
    echo "检测到 systemd 服务文件缺失，将强制重新安装..."
    FORCE_INSTALL="--force"
fi

# 下载上游官方 install-release.sh 并执行
# 关键: 必须先验证下载内容是 bash 脚本, 否则 GitHub 偶尔返回的反爬/限流 HTML
# 会被 `bash -c` 当作脚本执行, 报出 "syntax error near `<!DOCTYPE html>`" 这种
# 让人摸不着头脑的错误.
install_xray() {
    local tmp script_url first_bytes
    tmp=$(mktemp --suffix=.sh) || return 1

    # 主源 + raw 镜像 (raw.githubusercontent.com 偶尔比 github.com/.../raw/ 稳)
    for script_url in \
        "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" \
        "https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"; do

        if ! curl -fsSL --connect-timeout 10 --max-time 60 "$script_url" -o "$tmp"; then
            echo "  ↳ 从 $script_url 下载失败"
            continue
        fi

        first_bytes=$(head -c 2 "$tmp")
        if [[ "$first_bytes" != "#!" ]]; then
            echo "  ↳ $script_url 返回的不是 bash 脚本 (前 80 字节):"
            head -c 80 "$tmp" | sed 's/^/      /'
            echo ""
            echo "      多半是上游临时返回了 HTML/限流页, 换镜像重试..."
            continue
        fi

        # 注意: 脚本顶部有 set -e。这里必须用 `|| rc=$?` 捕获失败,
        # 否则上游安装脚本一旦非零退出, set -e 会让整个脚本立即终止,
        # 外层 MAX_RETRIES 重试逻辑将永远不会被执行。
        local rc=0
        bash "$tmp" install $FORCE_INSTALL || rc=$?
        rm -f "$tmp"
        return $rc
    done

    rm -f "$tmp"
    return 1
}

MAX_RETRIES=3
RETRY_COUNT=0
while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    if install_xray; then
        break
    fi
    ((RETRY_COUNT++))
    if [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
        echo "安装失败，等待 5 秒后重试 ($RETRY_COUNT/$MAX_RETRIES)..."
        sleep 5
    else
        echo "错误: Xray 安装失败，已达到最大重试次数"
        exit 1
    fi
done

# 生成配置参数
echo ""
echo "[3/5] 生成配置参数..."
UUID=$(cat /proc/sys/kernel/random/uuid)
KEYS=$(/usr/local/bin/xray x25519)

# 兼容新旧版本 xray x25519 输出格式
# 旧版: "Private key: xxx" / "Public key: xxx"
# 新版 v25+: "PrivateKey: xxx" / "PublicKey: xxx"
# 新版 v26+: "PrivateKey: xxx" / "Password (PublicKey): xxx"
PRIVATE_KEY=$(echo "$KEYS" | grep -iE "^Private\s*key:" | cut -d':' -f2 | tr -d ' ')
PUBLIC_KEY=$(echo "$KEYS" | grep -iE "^Public\s*key:" | cut -d':' -f2 | tr -d ' ')

# 如果旧格式解析失败，尝试新格式
if [[ -z "$PRIVATE_KEY" ]]; then
    PRIVATE_KEY=$(echo "$KEYS" | grep -E "^PrivateKey:" | cut -d':' -f2 | tr -d ' ')
fi
if [[ -z "$PUBLIC_KEY" ]]; then
    # v25+ 使用 PublicKey 字段
    PUBLIC_KEY=$(echo "$KEYS" | grep -E "^PublicKey:" | cut -d':' -f2 | tr -d ' ')
fi
if [[ -z "$PUBLIC_KEY" ]]; then
    # v26+ 使用 "Password (PublicKey): xxx" 格式
    PUBLIC_KEY=$(echo "$KEYS" | grep -E "^Password" | awk -F': ' '{print $NF}' | tr -d ' ')
fi
SHORT_ID=$(openssl rand -hex 8)

# 验证密钥生成成功
if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    echo "❌ 错误: 密钥生成失败"
    echo "xray x25519 输出:"
    echo "$KEYS"
    exit 1
fi

echo "UUID: $UUID"
echo "Private Key: $PRIVATE_KEY"
echo "Public Key: $PUBLIC_KEY"
echo "Short ID: $SHORT_ID"

# 获取服务器 IP（优先 IPv4，回退 IPv6）
SERVER_IP=""
IP_FAMILY=""

# 尝试 IPv4
for endpoint in "https://api.ipify.org" "https://ifconfig.me/ip" "https://api.ip.sb/ip"; do
    SERVER_IP=$(curl -4 -s --connect-timeout 5 --max-time 8 "$endpoint" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$SERVER_IP" ]] && [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IP_FAMILY="ipv4"
        break
    fi
    SERVER_IP=""
done

# IPv4 失败时回退 IPv6
if [[ -z "$SERVER_IP" ]]; then
    for endpoint in "https://api6.ipify.org" "https://ifconfig.me/ip" "https://api.ip.sb/ip"; do
        SERVER_IP=$(curl -6 -s --connect-timeout 5 --max-time 8 "$endpoint" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$SERVER_IP" ]] && [[ "$SERVER_IP" == *:* ]]; then
            IP_FAMILY="ipv6"
            break
        fi
        SERVER_IP=""
    done
fi

if [[ -z "$SERVER_IP" ]]; then
    echo "⚠️  无法自动获取公网 IP"
    read -p "请手动输入服务器公网 IP (IPv4 或 IPv6): " SERVER_IP
    SERVER_IP=$(echo "$SERVER_IP" | tr -d '[:space:]')
    if [[ "$SERVER_IP" == *:* ]]; then
        IP_FAMILY="ipv6"
    else
        IP_FAMILY="ipv4"
    fi
fi

# 构造 URL 中使用的主机字段（IPv6 必须用方括号包裹）
if [[ "$IP_FAMILY" == "ipv6" ]]; then
    SERVER_HOST_URL="[${SERVER_IP}]"
else
    SERVER_HOST_URL="$SERVER_IP"
fi

echo "服务器 IP: $SERVER_IP ($IP_FAMILY)"
if [[ "$IP_FAMILY" == "ipv6" ]]; then
    echo "⚠️  仅检测到 IPv6 公网地址。客户端所在网络必须支持 IPv6 才能连接。"
fi

# ============================================
# 可配置项：Reality 伪装目标域名
# 单一数据源——dest / serverNames / 客户端 SNI / 分享链接全部引用它，
# 从根本上杜绝“服务端与客户端 SNI 不一致导致连不上”的问题。
# 选站建议：与本机同区域、支持 TLS1.3 + HTTP/2、非 CDN、相对冷门的大站，
# 隐蔽性优于 apple/microsoft 这类探测工具的高频已知目标。
# ============================================
DEST_DOMAIN="www.apple.com"

# 创建配置文件
echo ""
echo "[4/5] 创建配置文件..."

# 确保配置目录和日志目录存在
mkdir -p /usr/local/etc/xray
mkdir -p /var/log/xray

# 检测内核版本，判断是否支持 TCP Fast Open
KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
ENABLE_TCP_OPTIMIZATIONS=false

# TCP Fast Open 需要内核 >= 3.7 (复用上方定义的 version_ge，避免 sort -C 的可读性陷阱)
if version_ge "$KERNEL_VERSION" "3.7"; then
    ENABLE_TCP_OPTIMIZATIONS=true
    echo "✓ 检测到内核版本 $KERNEL_VERSION，启用 TCP 性能优化"
else
    echo "⚠️  内核版本 $KERNEL_VERSION < 3.7，跳过 TCP Fast Open 优化"
fi

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "tag": "vless_tls",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "email": "user@example.com"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST_DOMAIN}:443",
          "xver": 0,
          "serverNames": [
            "${DEST_DOMAIN}"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID",
            ""
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

# 根据内核版本添加 TCP 性能优化
if [ "$ENABLE_TCP_OPTIMIZATIONS" = true ]; then
    echo "✓ 添加 TCP 性能优化参数到配置文件..."

    # 使用 jq 添加 sockopt 到 inbound streamSettings
    jq '.inbounds[0].streamSettings.sockopt = {
        "tcpFastOpen": true,
        "tcpNoDelay": true,
        "tcpKeepAliveInterval": 30
    }' /usr/local/etc/xray/config.json > /tmp/xray-config-tmp.json && \
    mv /tmp/xray-config-tmp.json /usr/local/etc/xray/config.json

    # 说明: 不再给 freedom outbound 注入 sockopt——它是主动连出的直连出站,
    # tcpFastOpen 在这里没有意义, 只会给配置增加无用噪音。

    echo "✓ Xray sockopt 已启用 (TCP Fast Open, TCP NoDelay, TCP KeepAlive)"
fi

# ============================================
# 内核 TCP 调优 (BBR + fq qdisc + 大缓冲)
# 这一步对跨洲单 TCP 连接吞吐影响最大
# ============================================
echo ""
echo "[4.1/5] 启用内核 BBR + TCP 缓冲调优..."

# 加载 BBR 模块（部分极简内核默认不加载）
if ! lsmod | grep -q "^tcp_bbr "; then
    if modprobe tcp_bbr 2>/dev/null; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        echo "✓ tcp_bbr 模块已加载并设为开机自动加载"
    else
        echo "⚠️  当前内核无 tcp_bbr 模块，跳过 BBR（可能是极简/容器内核）"
    fi
fi

# 写入持久化 sysctl 配置
cat > /etc/sysctl.d/99-xray-bbr.conf <<'SYSCTL_EOF'
# Xray VPN performance tuning (managed by Xray-VPN-OneClick install.sh)
# Reversible: rm this file and reboot to revert.

# 拥塞控制: BBR + fq qdisc (BBR 推荐搭配 fq)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 套接字缓冲上限 (~64MB) - 支持高 BDP 跨洲链路
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# 连接队列 / backlog
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 65535

# TCP 行为
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
SYSCTL_EOF

# 应用（容器/受限环境里部分参数可能写不进去，单条容错处理）
sysctl -p /etc/sysctl.d/99-xray-bbr.conf >/dev/null 2>&1 || true

# 验证关键参数是否真的生效
ACTUAL_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
ACTUAL_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
if [ "$ACTUAL_CC" = "bbr" ]; then
    echo "✓ 内核 BBR + fq qdisc 已启用 (cc=$ACTUAL_CC, qdisc=$ACTUAL_QDISC)"
else
    echo "⚠️  BBR 未生效 (当前 cc=$ACTUAL_CC)，可能受容器内核限制；配置文件已写入 /etc/sysctl.d/99-xray-bbr.conf"
fi

# 确保日志目录和文件存在，并设置最小必要权限
# 目录 750 / 文件 640，避免 666 带来的本地日志投毒与信息泄露风险。
# owner 稍后根据实际运行用户（setcap 场景为 nobody，回退场景为 root）设置。
mkdir -p /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log
chmod 750 /var/log/xray
chmod 640 /var/log/xray/*.log

# ============================================
# 端口 443 绑定权限：优先 setcap（最小权限），而非让整个进程以 root 运行
# ============================================
# 强制 User=root 会放大攻击面：一旦 Xray 被利用即是 root 权限。
# 更安全的做法是只给二进制 cap_net_bind_service 能力，绑定 443 后仍以
# 非特权用户（官方 install-release.sh 默认创建的 nobody）运行。
XRAY_BIN="/usr/local/bin/xray"
RUN_USER="nobody"   # 官方脚本默认运行用户
mkdir -p /etc/systemd/system/xray.service.d

if command -v setcap &>/dev/null && setcap 'cap_net_bind_service=+ep' "$XRAY_BIN" 2>/dev/null; then
    # setcap 成功：确保 drop-in 不再强制 root（清掉可能残留的旧覆盖）
    cat > /etc/systemd/system/xray.service.d/99-user-override.conf <<EOF
[Service]
# 通过 setcap 授予 cap_net_bind_service，无需 root 即可绑定 443。
# 显式留空 User 让其沿用官方 unit 的默认非特权用户。
EOF
    CAP_MODE="setcap"
    echo "✓ 已通过 setcap 授权二进制绑定 443，Xray 将以非特权用户运行"
else
    # 回退：setcap 不可用（无 libcap / 特殊文件系统）时才退回 root
    RUN_USER="root"
    cat > /etc/systemd/system/xray.service.d/99-user-override.conf <<EOF
[Service]
# setcap 不可用，回退为 root 以绑定 443 端口
User=root
EOF
    CAP_MODE="root"
    echo "⚠️  setcap 不可用，已回退为 root 运行（安全性略降）"
fi

# 运行用户确定后，把日志属主交给它，确保非特权进程能写入日志
chown -R "${RUN_USER}:${RUN_USER}" /var/log/xray 2>/dev/null || chown -R "$RUN_USER" /var/log/xray 2>/dev/null || true

# 配置防火墙
echo ""
echo "[4.5/5] 配置防火墙..."
if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    # firewalld (RHEL/CentOS/Fedora) 正在运行
    firewall-cmd --permanent --add-port=443/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    echo "✓ firewalld 已配置放行 443/tcp"
elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    # ufw (Ubuntu/Debian) 正在运行
    ufw allow 443/tcp 2>/dev/null || true
    echo "✓ ufw 已配置放行 443/tcp"
elif command -v iptables &>/dev/null && ! command -v firewall-cmd &>/dev/null && ! command -v ufw &>/dev/null; then
    # 仅在没有更高层防火墙管理器时才直接写 iptables，避免规则被其覆盖
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    echo "✓ iptables 已放行 443/tcp"
    echo "  ⚠️  iptables 规则重启后可能丢失，如需持久化请安装 iptables-persistent/netfilter-persistent"
elif command -v firewall-cmd &>/dev/null; then
    echo "⚠️  检测到 firewalld 已安装但未运行——未自动放行端口。"
    echo "    如启用了其它防火墙策略，请手动放行 443/tcp。"
elif command -v ufw &>/dev/null; then
    echo "⚠️  检测到 ufw 已安装但未启用——未自动放行端口。"
    echo "    若稍后启用 ufw，请记得执行: ufw allow 443/tcp"
else
    echo "⚠️  未检测到防火墙管理器，请确认云厂商安全组/防火墙已放行 443/tcp"
fi

# 启动前预检：先用 xray -test 验证配置合法性，避免等 systemd 起不来才排查
echo ""
echo "[4.8/5] 校验配置文件..."
if "$XRAY_BIN" -test -config /usr/local/etc/xray/config.json 2>/tmp/xray-test.err; then
    echo "✓ 配置文件校验通过"
else
    echo "❌ 配置文件校验未通过，Xray 报告如下："
    sed 's/^/    /' /tmp/xray-test.err
    rm -f /tmp/xray-test.err
    echo ""
    echo "已生成的配置在 /usr/local/etc/xray/config.json，请检查后重试。"
    exit 1
fi
rm -f /tmp/xray-test.err

# 启动服务
echo ""
echo "[5/5] 启动 Xray 服务..."
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 等待服务启动
sleep 3

# 检查服务状态
if systemctl is-active --quiet xray; then
  echo ""
  echo "================================"
  echo "✅ Xray 安装成功！"
  echo "================================"
  echo ""
  echo "📋 服务器信息："
  echo "地址: $SERVER_IP"
  echo "端口: 443"
  if [ "$CAP_MODE" = "setcap" ]; then
      echo "运行模式: 非特权用户 ($RUN_USER) + setcap（已加固）"
  else
      echo "运行模式: root（setcap 不可用时的回退）"
  fi
  echo ""
  echo "🔑 客户端配置："
  echo "UUID: $UUID"
  echo "Public Key: $PUBLIC_KEY"
  echo "Short ID: $SHORT_ID"
  echo "SNI: ${DEST_DOMAIN}"
  echo "Flow: xtls-rprx-vision"
  echo ""
  echo "📱 分享链接："
  SHARE_LINK="vless://${UUID}@${SERVER_HOST_URL}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Xray-Reality"
  echo "$SHARE_LINK"
  echo ""
  echo "配置信息已保存到: /root/xray-info.txt"

  # 保存配置信息
  cat > /root/xray-info.txt <<INFO
Xray 配置信息
生成时间: $(date)
系统: ${OS_PRETTY_NAME:-$OS_ID $OS_VERSION_ID}

服务器信息:
- 地址: $SERVER_IP
- 端口: 443
- 协议: VLESS + XTLS-Reality

客户端配置:
- UUID: $UUID
- Public Key: $PUBLIC_KEY
- Short ID: $SHORT_ID
- SNI: ${DEST_DOMAIN}
- Flow: xtls-rprx-vision
- Fingerprint: chrome

分享链接:
$SHARE_LINK

服务管理命令:
- 启动: systemctl start xray
- 停止: systemctl stop xray
- 重启: systemctl restart xray
- 状态: systemctl status xray
- 日志: journalctl -u xray -f
INFO

  # 该文件含 UUID / 公钥 / 完整分享链接等连接凭据，限制为仅 root 可读
  chmod 600 /root/xray-info.txt

else
  echo ""
  echo "❌ Xray 启动失败"
  echo ""
  echo "请检查以下内容："
  echo "1. 查看日志: journalctl -u xray -n 50"
  echo "2. 检查配置: cat /usr/local/etc/xray/config.json"
  echo "3. 检查端口: ss -tlnp | grep 443"
  echo ""
  echo "常见问题："
  echo "- 端口 443 被占用"
  echo "- 配置文件格式错误"
  echo "- SELinux 阻止 (RHEL系): setenforce 0"
  exit 1
fi
