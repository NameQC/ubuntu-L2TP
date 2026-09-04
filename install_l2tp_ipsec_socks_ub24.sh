#!/usr/bin/env bash
set -e

########################
# 可自定义参数
########################
VPN_USER="vpnL2TP"
VPN_PASS="vpnL2TP"
VPN_PSK="vpnL2TP"

# VPN 网段
VPN_NET="10.10.10.0/24"
VPN_LOCAL="10.10.10.1"
VPN_POOL_START="10.10.10.10"
VPN_POOL_END="10.10.10.200"

# SOCKS5 配置
SOCKS_USER="NameQC"
SOCKS_PASS="NameQC"
SOCKS_PORT=1080

# 日志颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

########################
# 基础检查
########################
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}错误：请用 root 用户执行本脚本。${NC}"
  exit 1
fi

# 修复主机名解析问题（通用方法）
echo -e "${YELLOW}正在检查主机名解析...${NC}"
CURRENT_HOSTNAME=$(hostname 2>/dev/null || echo "localhost")

# 检查是否为有效的非localhost主机名，且未在hosts中正确解析
if [ -n "$CURRENT_HOSTNAME" ] && [ "$CURRENT_HOSTNAME" != "localhost" ] && [ "$CURRENT_HOSTNAME" != "localhost.localdomain" ]; then
    # 检查主机名是否能够解析
    if ! getent hosts "$CURRENT_HOSTNAME" > /dev/null 2>&1; then
        echo -e "${YELLOW}主机名 '$CURRENT_HOSTNAME' 无法解析，正在修复...${NC}"
        # 检查是否已经有127.0.0.1条目
        if ! grep -q "^127.0.0.1" /etc/hosts; then
            echo "127.0.0.1 localhost localhost.localdomain" >> /etc/hosts
        fi
        # 添加当前主机名到127.0.0.1
        sed -i "/^127.0.0.1/ s/$/ $CURRENT_HOSTNAME/" /etc/hosts
        echo -e "${GREEN}已修复主机名解析${NC}"
    else
        echo -e "${GREEN}主机名解析正常${NC}"
    fi
fi

# 检查系统版本
if [ -f /etc/os-release ]; then
  . /etc/os-release
  if [ "$ID" != "ubuntu" ]; then
    echo -e "${RED}本脚本只针对 Ubuntu 系统，当前系统：$PRETTY_NAME${NC}"
    exit 1
  fi
  if [[ ! "$VERSION_ID" =~ ^(20|22|24)\. ]]; then
    echo -e "${YELLOW}警告：本脚本测试于 Ubuntu 20.04/22.04/24.04，当前系统：$PRETTY_NAME${NC}"
    echo -e "${YELLOW}继续安装可能不兼容，按 Ctrl+C 取消，或等待5秒继续...${NC}"
    sleep 5
  fi
else
  echo -e "${RED}无法检测系统版本，终止。${NC}"
  exit 1
fi

# 检测外网网卡
WAN_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {print $5; exit}')
if [ -z "$WAN_IF" ]; then
  WAN_IF=$(ip route | grep default | awk '{print $5}' | head -1)
  if [ -z "$WAN_IF" ]; then
    echo -e "${RED}无法自动检测外网网卡，请手动修改脚本中的 WAN_IF 变量后再运行。${NC}"
    exit 1
  fi
fi
echo -e "${GREEN}检测到外网网卡：$WAN_IF${NC}"

# 获取公网IP
PUBLIC_IP=""
for method in "curl -s ifconfig.me" "curl -s icanhazip.com" "curl -s ipinfo.io/ip" "wget -qO- ifconfig.me"; do
    if PUBLIC_IP=$(eval $method 2>/dev/null) && [ -n "$PUBLIC_IP" ] && [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
done
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="你的公网IP（请手动获取）"
fi
echo -e "${GREEN}公网IP：$PUBLIC_IP${NC}"

########################
# 安装依赖（修复冲突）
########################
echo -e "${YELLOW}正在更新软件源并安装依赖...${NC}"
export DEBIAN_FRONTEND=noninteractive

# 先更新包列表
apt update -y

# Ubuntu 24.04 特殊处理：不安装 iptables-persistent 和 netfilter-persistent
# 因为与 ufw 冲突
if [[ "$VERSION_ID" =~ ^24\. ]]; then
    echo -e "${YELLOW}检测到 Ubuntu 24.04，使用兼容模式安装...${NC}"
    apt install -y strongswan xl2tpd ppp iptables dante-server ufw curl wget
    # 不安装 iptables-persistent 和 netfilter-persistent
else
    apt install -y strongswan xl2tpd ppp iptables iptables-persistent dante-server ufw curl wget
fi

########################
# 创建 iptables 保存目录（Ubuntu 24.04）
########################
if [[ "$VERSION_ID" =~ ^24\. ]]; then
    mkdir -p /etc/iptables
    # 创建保存和恢复脚本
    cat > /etc/network/if-pre-up.d/iptables <<'EOF'
#!/bin/sh
/sbin/iptables-restore < /etc/iptables/rules.v4 2>/dev/null || true
EOF
    chmod +x /etc/network/if-pre-up.d/iptables
    
    cat > /etc/network/if-post-down.d/iptables <<'EOF'
#!/bin/sh
/sbin/iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
EOF
    chmod +x /etc/network/if-post-down.d/iptables
fi

########################
# UFW 防火墙配置（先停止防止冲突）
########################
echo -e "${YELLOW}配置 UFW 防火墙...${NC}"
if command -v ufw &> /dev/null; then
    # 确保 ufw 不会干扰 iptables
    ufw --force disable 2>/dev/null || true
    sleep 2
    ufw --force enable
    ufw allow 22/tcp comment 'SSH'
    ufw allow 500/udp comment 'IPsec IKE'
    ufw allow 4500/udp comment 'IPsec NAT-T'
    ufw allow 1701/udp comment 'L2TP'
    ufw allow $SOCKS_PORT/tcp comment 'SOCKS5'
    ufw reload
    echo -e "${GREEN}UFW 防火墙配置完成${NC}"
else
    echo -e "${YELLOW}UFW 未安装，跳过防火墙配置${NC}"
fi

########################
# IP 转发 & 内核参数
########################
echo -e "${YELLOW}配置内核参数...${NC}"
cat > /etc/sysctl.d/99-l2tp-ipsec.conf <<EOF2
net.ipv4.ip_forward=1
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1
EOF2
sysctl --system

########################
# strongSwan 配置
########################
echo -e "${YELLOW}配置 strongSwan...${NC}"
cat > /etc/ipsec.conf <<EOF2
config setup
  uniqueids=no
  charondebug="ike 2, knl 2, cfg 2"

conn L2TP-PSK
  keyexchange=ikev1
  authby=psk
  type=transport
  left=%any
  leftprotoport=17/1701
  right=%any
  rightprotoport=17/%any
  ike=aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024!
  esp=aes256-sha1,aes128-sha1,3des-sha1!
  dpddelay=30
  dpdtimeout=120
  dpdaction=clear
  auto=add
EOF2

cat > /etc/ipsec.secrets <<EOF2
: PSK "$VPN_PSK"
EOF2
chmod 600 /etc/ipsec.secrets

########################
# xl2tpd 配置
########################
echo -e "${YELLOW}配置 xl2tpd...${NC}"
cat > /etc/xl2tpd/xl2tpd.conf <<EOF2
[global]
port = 1701

[lns default]
ip range = $VPN_POOL_START-$VPN_POOL_END
local ip = $VPN_LOCAL
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF2

########################
# PPP / L2TP 配置
########################
echo -e "${YELLOW}配置 PPP...${NC}"
cat > /etc/ppp/options.xl2tpd <<EOF2
name l2tpd
auth
refuse-pap
refuse-chap
require-mschap-v2
mtu 1400
mru 1400
ms-dns 8.8.8.8
ms-dns 1.1.1.1
EOF2

# 添加 VPN 用户
cat > /etc/ppp/chap-secrets <<EOF2
$VPN_USER l2tpd $VPN_PASS *
EOF2
chmod 600 /etc/ppp/chap-secrets
chmod 600 /etc/ppp/options.xl2tpd

########################
# iptables NAT & 端口放行
########################
echo -e "${YELLOW}配置 iptables...${NC}"
# 备份现有规则
iptables-save > /tmp/iptables-backup-$(date +%Y%m%d-%H%M%S).rules 2>/dev/null || true

# 清空旧规则（保留默认策略）
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -X 2>/dev/null || true

# 设置默认策略
iptables -P INPUT DROP
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# 基础允许
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# IPsec / L2TP 端口
iptables -A INPUT -p udp --dport 500  -j ACCEPT
iptables -A INPUT -p udp --dport 4500 -j ACCEPT
iptables -A INPUT -p udp --dport 1701 -j ACCEPT

# SOCKS5 端口
iptables -A INPUT -p tcp --dport $SOCKS_PORT -j ACCEPT

# SSH 端口
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# VPN 网段 NAT
iptables -A FORWARD -s $VPN_NET -j ACCEPT
iptables -A FORWARD -d $VPN_NET -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -s $VPN_NET -o $WAN_IF -j MASQUERADE

# 保存 iptables 规则
if [[ "$VERSION_ID" =~ ^24\. ]]; then
    # Ubuntu 24.04: 使用自定义保存
    iptables-save > /etc/iptables/rules.v4
    echo -e "${GREEN}iptables 规则已保存到 /etc/iptables/rules.v4${NC}"
elif command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

########################
# Dante SOCKS5 配置
########################
echo -e "${YELLOW}配置 SOCKS5...${NC}"
# 非特权运行用户
id socks >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin socks

# SOCKS 登录用户
id "$SOCKS_USER" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin "$SOCKS_USER" || true
echo "$SOCKS_USER:$SOCKS_PASS" | chpasswd

cat > /etc/danted.conf <<EOF2
logoutput: /var/log/danted.log

internal: 0.0.0.0 port = $SOCKS_PORT
external: $WAN_IF

method: username
user.notprivileged: socks

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect disconnect error
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp udp
  log: connect disconnect error
}
EOF2

systemctl enable danted 2>/dev/null || true
systemctl restart danted || true

########################
# 启动服务
########################
echo -e "${YELLOW}启动所有服务...${NC}"
systemctl enable strongswan-starter 2>/dev/null || true
systemctl enable xl2tpd 2>/dev/null || true

# 停止旧服务避免冲突
systemctl stop strongswan-starter 2>/dev/null || true
systemctl stop xl2tpd 2>/dev/null || true
sleep 1

# 启动服务
systemctl start strongswan-starter
sleep 2
systemctl start xl2tpd
sleep 2

########################
# 服务健康检查
########################
echo -e "${YELLOW}执行服务健康检查...${NC}"

# 检查 strongSwan
if systemctl is-active --quiet strongswan-starter 2>/dev/null; then
    echo -e "${GREEN}✓ strongSwan 运行正常${NC}"
else
    echo -e "${RED}✗ strongSwan 启动失败${NC}"
    journalctl -u strongswan-starter -n 10 --no-pager 2>/dev/null || echo "无法查看日志"
fi

# 检查 xl2tpd
if systemctl is-active --quiet xl2tpd 2>/dev/null; then
    echo -e "${GREEN}✓ xl2tpd 运行正常${NC}"
else
    echo -e "${RED}✗ xl2tpd 启动失败${NC}"
    journalctl -u xl2tpd -n 10 --no-pager 2>/dev/null || echo "无法查看日志"
fi

# 检查 dante
if systemctl is-active --quiet danted 2>/dev/null; then
    echo -e "${GREEN}✓ danted (SOCKS5) 运行正常${NC}"
else
    echo -e "${RED}✗ danted 启动失败${NC}"
    journalctl -u danted -n 10 --no-pager 2>/dev/null || echo "无法查看日志"
fi

# 检查端口监听
echo -e "\n${YELLOW}端口监听状态：${NC}"
ss -lunp 2>/dev/null | grep -E '500|4500|1701' | while read line; do
    echo -e "${GREEN}  $line${NC}"
done
ss -tnlp 2>/dev/null | grep $SOCKS_PORT | while read line; do
    echo -e "${GREEN}  $line${NC}"
done

########################
# 输出信息
########################
echo ""
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}#           Telegram联系：@NameQC                   #${NC}"
echo -e "${GREEN}#    全球服务器 免实名服务器 高防服务器 站群服务器     #${NC}"
echo -e "${GREEN}#         Telegram双向机器人：@NameQCBot            #${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} 安装完成：L2TP/IPsec + SOCKS5（Ubuntu 终极版）   ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo ""
echo -e "${YELLOW}【L2TP/IPsec】${NC}"
echo "  服务器：$PUBLIC_IP"
echo "  账户：  $VPN_USER"
echo "  密码：  $VPN_PASS"
echo "  PSK：   $VPN_PSK"
echo ""
echo -e "${YELLOW}iPhone / iPad / macOS 设置：${NC}"
echo "  类型：      L2TP"
echo "  服务器：    $PUBLIC_IP"
echo "  账户：      $VPN_USER"
echo "  密码：      $VPN_PASS"
echo "  密钥(PSK)： $VPN_PSK"
echo "  发送所有流量：开启"
echo ""
echo -e "${YELLOW}【SOCKS5】${NC}"
echo "  地址： $PUBLIC_IP"
echo "  端口： $SOCKS_PORT"
echo "  用户： $SOCKS_USER"
echo "  密码： $SOCKS_PASS"
echo ""
echo -e "${YELLOW}检查命令：${NC}"
echo "  ipsec status"
echo "  systemctl status strongswan-starter xl2tpd danted"
echo "  journalctl -u strongswan-starter -n 30"
echo "  journalctl -u xl2tpd -n 30"
echo "  journalctl -u danted -n 30"
echo "  ss -lunp | grep -E '500|4500|1701'"
echo "  ss -tnlp | grep $SOCKS_PORT"
echo ""
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}如果 VPN 连接失败，请检查云服务商防火墙是否放行端口${NC}"
echo -e "${GREEN}====================================================${NC}"
