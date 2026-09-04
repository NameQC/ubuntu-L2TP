#!/usr/bin/env bash
set -e

########################
# 颜色定义
########################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

########################
# 显示Banner
########################
show_banner() {
    clear
    echo "===================================================="
    echo "#           Telegram联系：@NameQC                   #"
    echo "#    全球服务器 免实名服务器 高防服务器 站群服务器  #"
    echo "#         Telegram双向机器人：@NameQCBot            #"
    echo "===================================================="
    echo "              QC 综合安装管理器"
    echo "===================================================="
}

########################
# 安装 L2TP/IPSec
########################
install_l2tp() {
    echo -e "${GREEN}>>> 开始安装 L2TP/IPSec VPN${NC}"

    echo "是否自定义VPN账号密码和预共享密钥？(y/n)"
    echo "输入 y 则自定义，输入 n 或直接回车则使用默认值"
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

    if [ -f /etc/ppp/chap-secrets ]; then
        echo -e "${YELLOW}检测到L2TP已安装，跳过安装步骤${NC}"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt install -y strongswan xl2tpd ppp iptables iptables-persistent

    cat > /etc/sysctl.d/99-l2tp-ipsec.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
    sysctl --system

    cat > /etc/ipsec.conf <<EOF
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
EOF

    cat > /etc/ipsec.secrets <<EOF
: PSK "$VPN_PSK"
EOF

    cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

[lns default]
ip range = 10.10.10.10-10.10.10.200
local ip = 10.10.10.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

    cat > /etc/ppp/options.xl2tpd <<EOF
name l2tpd
auth
refuse-pap
refuse-chap
require-mschap-v2
mtu 1400
mru 1400
ms-dns 8.8.8.8
ms-dns 1.1.1.1
EOF

    cat > /etc/ppp/chap-secrets <<EOF
$VPN_USER l2tpd $VPN_PASS *
EOF
    chmod 600 /etc/ppp/chap-secrets

    WAN_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {print $5; exit}')
    iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o $WAN_IF -j MASQUERADE
    iptables -A FORWARD -s 10.10.10.0/24 -j ACCEPT
    iptables -A INPUT -p udp --dport 500 -j ACCEPT
    iptables -A INPUT -p udp --dport 4500 -j ACCEPT
    iptables -A INPUT -p udp --dport 1701 -j ACCEPT
    netfilter-persistent save

    systemctl enable strongswan-starter
    systemctl enable xl2tpd
    systemctl restart strongswan-starter
    systemctl restart xl2tpd

    if [ -f /usr/local/bin/l2tp-mgr ]; then
        rm -f /usr/local/bin/l2tp-mgr
    fi
    cat > /usr/local/bin/l2tp-mgr <<'EOF2'
#!/usr/bin/env bash
show_l2tp_menu() {
    echo "===================================================="
    echo "           L2TP/IPSec VPN 管理菜单"
    echo "===================================================="
    echo "当前VPN用户列表："
    if [ -f /etc/ppp/chap-secrets ]; then
        grep -v "^#" /etc/ppp/chap-secrets | awk '{print "  用户名: " $1 " | 密码: " $3}'
    else
        echo "  (未检测到VPN安装)"
        return 1
    fi
    echo ""
    echo "请选择要执行的操作："
    echo "  1) 修改现有用户密码"
    echo "  2) 添加新用户"
    echo "  3) 删除用户"
    echo "  4) 修改预共享密钥(PSK)"
    echo "  5) 查看VPN连接信息"
    echo "  6) 重启VPN服务"
    echo "  0) 退出"
    read -p "请输入选项 (0-6): " ACTION

    case $ACTION in
        1)
            read -p "请输入要修改密码的用户名: " MOD_USER
            if ! grep -q "^$MOD_USER " /etc/ppp/chap-secrets; then
                echo "错误：用户 $MOD_USER 不存在！"
                return 1
            fi
            read -p "请输入新密码: " NEW_PASS
            sed -i "/^$MOD_USER /s/ [^ ]* / $NEW_PASS /" /etc/ppp/chap-secrets
            echo "✅ 用户 $MOD_USER 的密码已更新！"
            systemctl restart xl2tpd
            ;;
        2)
            read -p "请输入新用户名: " NEW_USER
            if grep -q "^$NEW_USER " /etc/ppp/chap-secrets; then
                echo "错误：用户 $NEW_USER 已存在！"
                return 1
            fi
            read -p "请输入密码: " NEW_PASS
            echo "$NEW_USER l2tpd $NEW_PASS *" >> /etc/ppp/chap-secrets
            chmod 600 /etc/ppp/chap-secrets
            echo "✅ 用户 $NEW_USER 已添加！"
            systemctl restart xl2tpd
            ;;
        3)
            read -p "请输入要删除的用户名: " DEL_USER
            if ! grep -q "^$DEL_USER " /etc/ppp/chap-secrets; then
                echo "错误：用户 $DEL_USER 不存在！"
                return 1
            fi
            sed -i "/^$DEL_USER /d" /etc/ppp/chap-secrets
            echo "✅ 用户 $DEL_USER 已删除！"
            systemctl restart xl2tpd
            ;;
        4)
            read -p "请输入新的预共享密钥(PSK): " NEW_PSK
            cat > /etc/ipsec.secrets <<EOF
: PSK "$NEW_PSK"
EOF
            echo "✅ 预共享密钥已更新！"
            systemctl restart strongswan-starter
            ;;
        5)
            echo ""
            SERVER_IP=$(curl -s ifconfig.me || echo "未知")
            echo "【L2TP/IPsec 连接信息】"
            echo "  服务器IP: $SERVER_IP"
            echo "  当前用户列表："
            grep -v "^#" /etc/ppp/chap-secrets | awk '{print "    用户名: " $1 ", 密码: " $3}'
            echo ""
            echo "【服务状态】"
            systemctl status strongswan-starter --no-pager | grep "Active:"
            systemctl status xl2tpd --no-pager | grep "Active:"
            ;;
        6)
            echo "正在重启VPN服务..."
            systemctl restart strongswan-starter
            systemctl restart xl2tpd
            echo "✅ 服务已重启！"
            ;;
        0)
            return 0
            ;;
        *)
            echo "无效选项！"
            ;;
    esac

    echo ""
    read -p "按回车键继续..."
}

if [ -f /etc/ppp/chap-secrets ]; then
    show_l2tp_menu
else
    echo "L2TP/IPSec VPN 未安装，请先运行安装脚本。"
fi
EOF2
    chmod +x /usr/local/bin/l2tp-mgr

    SERVER_IP=$(curl -s ifconfig.me || echo "未知")

    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}           L2TP/IPSec VPN 安装完成！${NC}"
    echo "===================================================="
    echo "【L2TP/IPsec】"
    echo "  服务器：$SERVER_IP"
    echo "  账户：  $VPN_USER"
    echo "  密码：  $VPN_PASS"
    echo "  PSK：   $VPN_PSK"
    echo ""
    echo "iPhone / iPad / macOS 设置："
    echo "  类型：      L2TP"
    echo "  服务器：    $SERVER_IP"
    echo "  账户：      $VPN_USER"
    echo "  密码：      $VPN_PASS"
    echo "  密钥(PSK)： $VPN_PSK"
    echo "  发送所有流量：开启"
    echo ""
    echo "【管理命令】"
    echo "  输入 'l2tp-mgr' 即可管理L2TP"
    echo "===================================================="
}

########################
# 安装 SOCKS5
########################
install_socks5() {
    echo -e "${GREEN}>>> 开始安装 SOCKS5 代理${NC}"

    echo "是否自定义SOCKS5账号密码？(y/n)"
    echo "输入 y 则自定义，输入 n 或直接回车则使用默认值"
    read -r CUSTOM_CHOICE

    if [[ "$CUSTOM_CHOICE" == "y" || "$CUSTOM_CHOICE" == "Y" ]]; then
        echo "请输入SOCKS5用户名:"
        read -r SOCKS_USER
        echo "请输入SOCKS5密码:"
        read -r SOCKS_PASS
    else
        SOCKS_USER="NameQC"
        SOCKS_PASS="NameQC"
        echo "使用默认值: 用户名=$SOCKS_USER, 密码=$SOCKS_PASS"
    fi

    if systemctl status danted &>/dev/null; then
        echo -e "${YELLOW}检测到SOCKS5已安装，跳过安装步骤${NC}"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt install -y dante-server iptables iptables-persistent

    WAN_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {print $5; exit}')

    id socks >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin socks
    id "$SOCKS_USER" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin "$SOCKS_USER"
    echo "$SOCKS_USER:$SOCKS_PASS" | chpasswd

    cat > /etc/danted.conf <<EOF
logoutput: /var/log/danted.log

internal: 0.0.0.0 port = 1080
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
EOF

    iptables -A INPUT -p tcp --dport 1080 -j ACCEPT
    netfilter-persistent save

    systemctl enable danted
    systemctl restart danted

    if [ -f /usr/local/bin/socks5-mgr ]; then
        rm -f /usr/local/bin/socks5-mgr
    fi
    cat > /usr/local/bin/socks5-mgr <<'EOF2'
#!/usr/bin/env bash
show_socks5_menu() {
    echo "===================================================="
    echo "           SOCKS5 代理管理菜单"
    echo "===================================================="
    echo "当前SOCKS5用户列表："
    if [ -f /etc/danted.conf ]; then
        local SOCKS_USER_LIST=$(grep -E "^user\." /etc/danted.conf | head -1 | awk -F'.' '{print $2}')
        if [ -n "$SOCKS_USER_LIST" ]; then
            echo "  用户名: $SOCKS_USER_LIST"
            if grep -q "^$SOCKS_USER_LIST:" /etc/shadow; then
                echo "  密码: 已设置"
            else
                echo "  密码: 未设置"
            fi
        else
            echo "  未找到SOCKS5用户配置"
        fi
    else
        echo "  (未检测到SOCKS5安装)"
        return 1
    fi

    echo ""
    echo "请选择要执行的操作："
    echo "  1) 修改SOCKS5用户密码"
    echo "  2) 修改SOCKS5监听端口"
    echo "  3) 查看SOCKS5服务状态"
    echo "  4) 重启SOCKS5服务"
    echo "  0) 退出"
    read -p "请输入选项 (0-4): " ACTION

    case $ACTION in
        1)
            read -p "请输入要修改密码的用户名: " MOD_USER
            if ! id "$MOD_USER" &>/dev/null; then
                echo "错误：用户 $MOD_USER 不存在！"
                return 1
            fi
            read -p "请输入新密码: " NEW_PASS
            echo "$MOD_USER:$NEW_PASS" | chpasswd
            echo "✅ 用户 $MOD_USER 的密码已更新！"
            systemctl restart danted
            ;;
        2)
            CURRENT_PORT=$(grep "^internal:" /etc/danted.conf | awk -F'=' '{print $2}' | tr -d ' ')
            read -p "请输入新的SOCKS5端口 (当前: $CURRENT_PORT): " NEW_PORT
            if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
                echo "错误：端口必须是1-65535之间的数字！"
                return 1
            fi
            sed -i "s/internal: 0.0.0.0 port = $CURRENT_PORT/internal: 0.0.0.0 port = $NEW_PORT/" /etc/danted.conf
            iptables -A INPUT -p tcp --dport $NEW_PORT -j ACCEPT
            netfilter-persistent save
            echo "✅ SOCKS5端口已更新为 $NEW_PORT"
            systemctl restart danted
            ;;
        3)
            echo ""
            echo "【SOCKS5 服务状态】"
            systemctl status danted --no-pager | grep "Active:"
            echo ""
            echo "【端口监听】"
            ss -tnlp | grep danted
            ;;
        4)
            echo "正在重启SOCKS5服务..."
            systemctl restart danted
            echo "✅ SOCKS5服务已重启！"
            ;;
        0)
            return 0
            ;;
        *)
            echo "无效选项！"
            ;;
    esac

    echo ""
    read -p "按回车键继续..."
}

if systemctl status danted &>/dev/null; then
    show_socks5_menu
else
    echo "SOCKS5 未安装，请先运行安装脚本。"
fi
EOF2
    chmod +x /usr/local/bin/socks5-mgr

    SERVER_IP=$(curl -s ifconfig.me || echo "未知")

    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}           SOCKS5 代理安装完成！${NC}"
    echo "===================================================="
    echo "【SOCKS5】"
    echo "  地址： $SERVER_IP"
    echo "  端口： 1080"
    echo "  用户： $SOCKS_USER"
    echo "  密码： $SOCKS_PASS"
    echo ""
    echo "【管理命令】"
    echo "  输入 'socks5-mgr' 即可管理SOCKS5"
    echo "===================================================="
}

########################
# 安装 VLESS (默认端口: 8443)
########################
install_vless() {
    echo -e "${GREEN}>>> 开始安装 VLESS (Xray) 节点${NC}"

    echo "是否自定义VLESS配置？(y/n)"
    echo "输入 y 则自定义，输入 n 或直接回车则使用默认值"
    read -r CUSTOM_CHOICE

    DEFAULT_PORT="8443"
    DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)
    DEFAULT_PATH="/vless"

    if [[ "$CUSTOM_CHOICE" == "y" || "$CUSTOM_CHOICE" == "Y" ]]; then
        echo "请输入端口 (默认: $DEFAULT_PORT):"
        read -r PORT
        echo "请输入UUID (直接回车生成随机UUID):"
        read -r UUID
        echo "请输入路径 (默认: $DEFAULT_PATH):"
        read -r PATH
    else
        PORT="$DEFAULT_PORT"
        UUID="$DEFAULT_UUID"
        PATH="$DEFAULT_PATH"
    fi

    if systemctl status xray &>/dev/null; then
        echo -e "${YELLOW}检测到VLESS已安装，跳过安装步骤${NC}"
        return 0
    fi

    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "level": 0,
            "email": "user@example.com"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none",
        "tcpSettings": {
          "header": {
            "type": "none"
          }
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

    iptables -A INPUT -p tcp --dport $PORT -j ACCEPT
    netfilter-persistent save 2>/dev/null || true

    systemctl restart xray
    systemctl enable xray

    if [ -f /usr/local/bin/vless-mgr ]; then
        rm -f /usr/local/bin/vless-mgr
    fi
    cat > /usr/local/bin/vless-mgr <<'EOF2'
#!/usr/bin/env bash
show_vless_menu() {
    echo "===================================================="
    echo "           VLESS (Xray) 管理菜单"
    echo "===================================================="
    echo ""
    echo "请选择要执行的操作："
    echo "  1) 查看节点信息"
    echo "  2) 查看服务状态"
    echo "  3) 查看日志"
    echo "  4) 重启服务"
    echo "  5) 停止服务"
    echo "  6) 启动服务"
    echo "  0) 退出"
    read -p "请输入选项 (0-6): " ACTION

    case $ACTION in
        1)
            if [ -f /usr/local/etc/xray/config.json ]; then
                SERVER_IP=$(curl -s ifconfig.me || echo "未知")
                PORT=$(grep -A2 '"port"' /usr/local/etc/xray/config.json | grep -o '[0-9]*' | head -1)
                UUID=$(grep -A5 '"clients"' /usr/local/etc/xray/config.json | grep '"id"' | awk -F'"' '{print $4}')
                echo ""
                echo "【VLESS 节点信息】"
                echo "  地址: $SERVER_IP"
                echo "  端口: $PORT"
                echo "  UUID: $UUID"
                echo "  流控: xtls-rprx-vision"
                echo "  加密: none"
                echo "  传输: tcp"
                echo ""
                echo "【VLESS 链接】"
                echo "vless://$UUID@$SERVER_IP:$PORT?flow=xtls-rprx-vision&encryption=none&security=none&type=tcp&headerType=none#VLESS"
            else
                echo "错误：未找到配置文件"
            fi
            ;;
        2)
            systemctl status xray --no-pager | grep -E "Active:|Loaded:"
            ;;
        3)
            journalctl -u xray -n 30 --no-pager
            ;;
        4)
            systemctl restart xray
            echo "✅ Xray 服务已重启"
            ;;
        5)
            systemctl stop xray
            echo "✅ Xray 服务已停止"
            ;;
        6)
            systemctl start xray
            echo "✅ Xray 服务已启动"
            ;;
        0)
            return 0
            ;;
        *)
            echo "无效选项！"
            ;;
    esac

    echo ""
    read -p "按回车键继续..."
}

if systemctl status xray &>/dev/null; then
    show_vless_menu
else
    echo "VLESS (Xray) 未安装，请先运行安装脚本。"
fi
EOF2
    chmod +x /usr/local/bin/vless-mgr

    SERVER_IP=$(curl -s ifconfig.me || echo "未知")

    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}           VLESS 节点安装完成！${NC}"
    echo "===================================================="
    echo "【VLESS 链接】"
    echo "vless://$UUID@$SERVER_IP:$PORT?flow=xtls-rprx-vision&encryption=none&security=none&type=tcp&headerType=none#VLESS"
    echo ""
    echo "【配置信息】"
    echo "  地址: $SERVER_IP"
    echo "  端口: $PORT"
    echo "  UUID: $UUID"
    echo "  流控: xtls-rprx-vision"
    echo "  加密: none"
    echo "  传输: tcp"
    echo ""
    echo "【管理命令】"
    echo "  输入 'vless-mgr' 即可管理VLESS"
    echo "===================================================="
}

########################
# 安装 L2TP + SOCKS5（组合）
########################
install_l2tp_socks5() {
    echo -e "${GREEN}>>> 开始安装 L2TP/IPSec + SOCKS5 组合${NC}"
    install_l2tp
    install_socks5
}

########################
# 主安装菜单
########################
main_menu() {
    show_banner
    echo ""
    echo "请选择要安装的协议："
    echo "  1) 安装 L2TP/IPSec VPN"
    echo "  2) 安装 SOCKS5 代理"
    echo "  3) 安装 VLESS (Xray) 节点"
    echo "  4) 安装 L2TP + SOCKS5（组合）"
    echo "  0) 退出"
    echo ""
    read -p "请输入选项 (0-4): " CHOICE

    case $CHOICE in
        1)
            install_l2tp
            ;;
        2)
            install_socks5
            ;;
        3)
            install_vless
            ;;
        4)
            install_l2tp_socks5
            ;;
        0)
            echo "退出。"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项！${NC}"
            read -p "按回车键继续..."
            main_menu
            ;;
    esac
}

########################
# 入口
########################
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请使用 root 用户执行本脚本。${NC}"
    exit 1
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "ubuntu" ] || [[ "$VERSION_ID" != 24.* ]]; then
        echo -e "${RED}本脚本只针对 Ubuntu 24.x，当前系统：$PRETTY_NAME${NC}"
        exit 1
    fi
else
    echo -e "${RED}无法检测系统版本，终止。${NC}"
    exit 1
fi

echo -e "${YELLOW}等待APT可用...${NC}"
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    sleep 1
done

main_menu
