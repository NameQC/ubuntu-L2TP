#!/usr/bin/env bash
set -e

########################
# 可自定义参数（若安装时选择默认）
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

########################
# 交互式询问是否自定义账号密码
########################
echo "===================================================="
echo "           正在安装：L2TP/IPsec + SOCKS5            "
echo "===================================================="
echo "是否自定义VPN账号密码和预共享密钥？(y/n)"
echo "输入 y 则自定义，输入 n 或直接回车则使用默认值"
echo "===================================================="
read -r CUSTOM_CHOICE

if [[ "$CUSTOM_CHOICE" == "y" || "$CUSTOM_CHOICE" == "Y" ]]; then
    echo "请输入VPN用户名:"
    read -r VPN_USER
    echo "请输入VPN密码:"
    read -r VPN_PASS
    echo "请输入预共享密钥(PSK):"
    read -r VPN_PSK
else
    VPN_USER="@NameQC"
    VPN_PASS="@NameQC"
    VPN_PSK="@NameQC"
    echo "使用默认值: 用户名=$VPN_USER, 密码=$VPN_PASS, PSK=$VPN_PSK"
fi

########################
# 基础检查
########################
if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 用户执行本脚本。"
  exit 1
fi

if [ -f /etc/os-release ]; then
  . /etc/os-release
  if [ "$ID" != "ubuntu" ] || [[ "$VERSION_ID" != 24.* ]]; then
    echo "本脚本只针对 Ubuntu 24.x，当前系统：$PRETTY_NAME"
    exit 1
  fi
else
  echo "无法检测系统版本，终止。"
  exit 1
fi

# 检测外网网卡
WAN_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {print $5; exit}')
if [ -z "$WAN_IF" ]; then
  echo "无法自动检测外网网卡，请手动修改脚本中的 WAN_IF 变量后再运行。"
  exit 1
fi
echo "检测到外网网卡：$WAN_IF"

########################
# 安装依赖
########################
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y strongswan xl2tpd ppp iptables iptables-persistent dante-server

########################
# IP 转发 & 内核参数
########################
cat > /etc/sysctl.d/99-l2tp-ipsec.conf <<EOF2
net.ipv4.ip_forward=1
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF2
sysctl --system

########################
# strongSwan 配置
########################
cat > /etc/ipsec.conf <<EOF2
config setup
  uniqueids=no

conn L2TP-PSK
  keyexchange=ikev1
  authby=psk
  type=transport
  left=%any
  leftprotoport=17/1701
  right=%any
  rightprotoport=17/%any
  ike=aes256-sha1-modp1024!
  esp=aes256-sha1!
  dpddelay=30
  dpdtimeout=120
  dpdaction=clear
  auto=add
EOF2

cat > /etc/ipsec.secrets <<EOF2
: PSK "$VPN_PSK"
EOF2

########################
# xl2tpd 配置
########################
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
# PPP / L2TP 配置（适配 Ubuntu24 + iOS）
########################
cat > /etc/ppp/options.xl2tpd <<EOF2
name l2tpd
auth

refuse-pap
refuse-chap
require-mschap-v2

# MPPE 加密不强制，完全由 IPsec 负责隧道加密
# require-mppe-128

mtu 1400
mru 1400

ms-dns 8.8.8.8
ms-dns 1.1.1.1
EOF2

cat > /etc/ppp/chap-secrets <<EOF2
$VPN_USER l2tpd $VPN_PASS *
EOF2
chmod 600 /etc/ppp/chap-secrets
chmod 600 /etc/ppp/options.xl2tpd

########################
# iptables NAT & 端口放行
########################
# 清空旧规则（假设新机器上没自定义防火墙）
iptables -F
iptables -t nat -F

# 基础允许：回环、本机已建立连接
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# IPsec / L2TP 端口
iptables -A INPUT -p udp --dport 500  -j ACCEPT
iptables -A INPUT -p udp --dport 4500 -j ACCEPT
iptables -A INPUT -p udp --dport 1701 -j ACCEPT

# SOCKS5 端口
iptables -A INPUT -p tcp --dport $SOCKS_PORT -j ACCEPT

# VPN 网段 NAT
iptables -A FORWARD -s $VPN_NET -j ACCEPT
iptables -A FORWARD -d $VPN_NET -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -s $VPN_NET -o $WAN_IF -j MASQUERADE

# 保持其余 INPUT 默认策略为 ACCEPT，避免误杀其他服务
netfilter-persistent save

########################
# Dante SOCKS5 配置
########################
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

systemctl enable danted
systemctl restart danted

########################
# 启动 strongSwan & xl2tpd
########################
systemctl enable strongswan-starter
systemctl enable xl2tpd
systemctl restart strongswan-starter
systemctl restart xl2tpd

# 获取本机公网IP
SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipinfo.io/ip || echo "无法自动获取，请手动查询")

echo "===================================================="
echo "#           Telegram联系：@NameQC                   #"
echo "#    全球服务器 免实名服务器 高防服务器 站群服务器     #"
echo "#         Telegram双向机器人：@NameQCBot            #"
echo "===================================================="
echo "===================================================="
echo " 安装完成：L2TP/IPsec + SOCKS5（Ubuntu 24 终极版）   "
echo "===================================================="
echo
echo "【L2TP/IPsec】"
echo "  服务器：$SERVER_IP"
echo "  账户：  $VPN_USER"
echo "  密码：  $VPN_PASS"
echo "  PSK：   $VPN_PSK"
echo
echo "iPhone / iPad / macOS 设置："
echo "  类型：      L2TP"
echo "  服务器：    $SERVER_IP"
echo "  账户：      $VPN_USER"
echo "  密码：      $VPN_PASS"
echo "  密钥(PSK)： $VPN_PSK"
echo "  发送所有流量：开启"
echo
echo "【SOCKS5】"
echo "  地址： $SERVER_IP"
echo "  端口： $SOCKS_PORT"
echo "  用户： $SOCKS_USER"
echo "  密码： $SOCKS_PASS"
echo
echo "检查命令："
echo "  ipsec status"
echo "  journalctl -u strongswan-starter -n 30"
echo "  journalctl -u xl2tpd -n 30"
echo "  journalctl -u danted -n 30"
echo "  ss -lunp  | grep -E '500|4500|1701'"
echo "  ss -tnlp  | grep $SOCKS_PORT"
echo "===================================================="
