#!/usr/bin/env bash
set -e

########################
# 可自定义参数（若安装时选择默认，则使用 @NameQC）
########################
VPN_USER="@NameQC"
VPN_PASS="@NameQC"
VPN_PSK="@NameQC"

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
# 函数：L2TP 管理菜单
########################
show_l2tp_menu() {
    echo "===================================================="
    echo "           L2TP/IPSec VPN 管理菜单"
    echo "===================================================="
    echo "当前VPN用户列表："
    if [ -f /etc/ppp/chap-secrets ]; then
        grep -v "^#" /etc/ppp/chap-secrets | awk '{print "  用户名: " $1 " | 密码: " $3}'
    else
        echo "  (未检测到VPN安装，请先运行 'vpn install' 进行安装)"
        echo "===================================================="
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
    echo "  0) 返回主菜单"
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
            SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "未知")
            echo "【L2TP/IPsec 连接信息】"
            echo "  服务器IP: $SERVER_IP"
            echo "  当前用户列表："
            grep -v "^#" /etc/ppp/chap-secrets | awk '{print "    用户名: " $1 ", 密码: " $3}'
            echo ""
            echo "【服务状态】"
            systemctl status strongswan-starter --no-pager 2>/dev/null | grep "Active:" || echo "  strongSwan: 未运行"
            systemctl status xl2tpd --no-pager 2>/dev/null | grep "Active:" || echo "  xl2tpd: 未运行"
            ;;
        6)
            echo "正在重启VPN服务..."
            systemctl restart strongswan-starter 2>/dev/null
            systemctl restart xl2tpd 2>/dev/null
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

########################
# 函数：SOCKS5 管理菜单
########################
show_socks5_menu() {
    echo "===================================================="
    echo "           SOCKS5 代理管理菜单"
    echo "===================================================="
    echo "当前SOCKS5用户列表："
    if [ -f /etc/danted.conf ]; then
        # 从凭证文件读取用户名和密码
        if [ -f /root/.socks5_credentials ]; then
            local SOCKS_USER=$(grep "^SOCKS5_USER=" /root/.socks5_credentials | cut -d'=' -f2)
            local SOCKS_PASS=$(grep "^SOCKS5_PASS=" /root/.socks5_credentials | cut -d'=' -f2)
            if [ -n "$SOCKS_USER" ]; then
                echo "  用户名: $SOCKS_USER"
                echo "  密码: $SOCKS_PASS"
            else
                echo "  未找到SOCKS5用户配置"
            fi
        else
            echo "  未找到SOCKS5凭证文件"
        fi
    else
        echo "  (未检测到SOCKS5安装，请先运行 'vpn install' 进行安装)"
        echo "===================================================="
        return 1
    fi

    echo ""
    echo "请选择要执行的操作："
    echo "  1) 修改SOCKS5用户密码"
    echo "  2) 修改SOCKS5监听端口"
    echo "  3) 查看SOCKS5服务状态"
    echo "  4) 重启SOCKS5服务"
    echo "  5) 卸载SOCKS5服务"
    echo "  0) 返回主菜单"
    read -p "请输入选项 (0-5): " ACTION

    case $ACTION in
        1)
            # 从凭证文件读取用户名
            local CURRENT_USER=$(grep "^SOCKS5_USER=" /root/.socks5_credentials | cut -d'=' -f2)
            if [ -z "$CURRENT_USER" ]; then
                echo "错误：无法获取当前SOCKS5用户名！"
                return 1
            fi
            echo "当前SOCKS5用户: $CURRENT_USER"
            read -p "请输入新密码: " NEW_PASS
            echo "$CURRENT_USER:$NEW_PASS" | chpasswd
            echo "✅ 用户 $CURRENT_USER 的密码已更新！"
            systemctl restart danted
            
            # 更新凭证文件中的密码
            if [ -f /root/.socks5_credentials ]; then
                sed -i "s/^SOCKS5_PASS=.*/SOCKS5_PASS=$NEW_PASS/" /root/.socks5_credentials
                echo "✅ 凭证文件已同步更新"
            fi
            ;;
        2)
            local CURRENT_PORT=$(grep -E "^internal: 0.0.0.0 port =" /etc/danted.conf | awk '{print $5}')
            read -p "请输入新的SOCKS5端口 (当前: $CURRENT_PORT): " NEW_PORT
            if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
                echo "错误：端口必须是1-65535之间的数字！"
                return 1
            fi
            sed -i "s/internal: 0.0.0.0 port = $CURRENT_PORT/internal: 0.0.0.0 port = $NEW_PORT/" /etc/danted.conf
            # 更新防火墙规则
            iptables -D INPUT -p tcp --dport $CURRENT_PORT -j ACCEPT 2>/dev/null
            iptables -A INPUT -p tcp --dport $NEW_PORT -j ACCEPT 2>/dev/null
            netfilter-persistent save 2>/dev/null
            echo "✅ SOCKS5端口已更新为 $NEW_PORT，服务将重启..."
            systemctl restart danted
            
            # 更新凭证文件中的端口
            if [ -f /root/.socks5_credentials ]; then
                sed -i "s/^SOCKS5_PORT=.*/SOCKS5_PORT=$NEW_PORT/" /root/.socks5_credentials
            fi
            ;;
        3)
            echo ""
            echo "【SOCKS5 服务状态】"
            systemctl status danted --no-pager 2>/dev/null | grep "Active:"
            echo ""
            echo "【端口监听】"
            ss -tnlp 2>/dev/null | grep danted || echo "  未监听"
            echo ""
            echo "【最新日志】"
            journalctl -u danted -n 10 --no-pager 2>/dev/null || echo "  无日志"
            ;;
        4)
            echo "正在重启SOCKS5服务..."
            systemctl restart danted
            echo "✅ SOCKS5服务已重启！"
            ;;
        5)
            read -p "确认要卸载SOCKS5服务吗？(y/n): " CONFIRM
            if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
                echo "正在卸载SOCKS5服务..."
                systemctl stop danted 2>/dev/null
                systemctl disable danted 2>/dev/null
                apt remove -y dante-server 2>/dev/null
                rm -f /etc/danted.conf
                rm -f /root/.socks5_credentials
                echo "✅ SOCKS5服务已卸载！"
            else
                echo "已取消卸载。"
            fi
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

########################
# 函数：主菜单
########################
show_main_menu() {
    while true; do
        clear
        echo "===================================================="
        echo "#           Telegram联系：@NameQC                   #"
        echo "#    全球服务器 免实名服务器 高防服务器 站群服务器  #"
        echo "#         Telegram双向机器人：@NameQCBot            #"
        echo "===================================================="
        echo "              VPN 综合管理菜单"
        echo "===================================================="
        echo ""
        echo "  1) 管理 L2TP/IPSec VPN"
        echo "  2) 管理 SOCKS5 代理"
        echo "  3) 查看服务整体状态"
        echo "  4) 卸载所有服务"
        echo "  0) 退出"
        echo ""
        read -p "请输入选项 (0-4): " MAIN_CHOICE

        case $MAIN_CHOICE in
            1)
                show_l2tp_menu
                ;;
            2)
                show_socks5_menu
                ;;
            3)
                echo ""
                echo "===================================================="
                echo "              服务整体状态"
                echo "===================================================="
                echo "【L2TP/IPSec】"
                systemctl status strongswan-starter --no-pager 2>/dev/null | grep "Active:" || echo "  未安装或未运行"
                systemctl status xl2tpd --no-pager 2>/dev/null | grep "Active:" || echo "  未安装或未运行"
                echo ""
                echo "【SOCKS5】"
                systemctl status danted --no-pager 2>/dev/null | grep "Active:" || echo "  未安装或未运行"
                echo ""
                echo "【端口监听】"
                ss -lunp 2>/dev/null | grep -E '500|4500|1701|1080' || echo "  无相关端口"
                echo ""
                read -p "按回车键继续..."
                ;;
            4)
                read -p "确认要卸载所有服务吗？这将删除所有配置和数据！(y/n): " CONFIRM
                if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
                    echo "正在卸载..."
                    systemctl stop strongswan-starter xl2tpd danted 2>/dev/null
                    systemctl disable strongswan-starter xl2tpd danted 2>/dev/null
                    apt remove -y strongswan xl2tpd dante-server 2>/dev/null
                    rm -rf /etc/ipsec.conf /etc/ipsec.secrets /etc/xl2tpd /etc/ppp/chap-secrets /etc/danted.conf
                    rm -f /usr/local/bin/vpn
                    rm -f /root/.socks5_credentials
                    echo "✅ 所有服务已卸载！"
                    exit 0
                else
                    echo "已取消卸载。"
                fi
                ;;
            0)
                echo "退出。"
                exit 0
                ;;
            *)
                echo "无效选项！"
                read -p "按回车键继续..."
                ;;
        esac
    done
}

########################
# 主安装流程
########################
install_vpn() {
    # 检查是否已安装
    if [ -f /etc/ppp/chap-secrets ]; then
        echo "检测到VPN已安装，输入 'vpn' 命令进行管理。"
        echo "如需重新安装，请先运行 'vpn' 选择 '4) 卸载所有服务'"
        exit 0
    fi

    # 交互式询问是否自定义账号密码
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
        SOCKS_USER="$VPN_USER"
        SOCKS_PASS="$VPN_PASS"
    else
        VPN_USER="@NameQC"
        VPN_PASS="@NameQC"
        VPN_PSK="@NameQC"
        SOCKS_USER="NameQC"
        SOCKS_PASS="NameQC"
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
    iptables -F
    iptables -t nat -F

    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    iptables -A INPUT -p udp --dport 500  -j ACCEPT
    iptables -A INPUT -p udp --dport 4500 -j ACCEPT
    iptables -A INPUT -p udp --dport 1701 -j ACCEPT

    iptables -A INPUT -p tcp --dport $SOCKS_PORT -j ACCEPT

    iptables -A FORWARD -s $VPN_NET -j ACCEPT
    iptables -A FORWARD -d $VPN_NET -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -t nat -A POSTROUTING -s $VPN_NET -o $WAN_IF -j MASQUERADE

    netfilter-persistent save

    ########################
    # Dante SOCKS5 配置（使用 socksmethod 替代 method）
    ########################
    id socks >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin socks

    id "$SOCKS_USER" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin "$SOCKS_USER"
    echo "$SOCKS_USER:$SOCKS_PASS" | chpasswd

    # 使用 /tmp 作为日志目录（避免只读文件系统问题）
    cat > /etc/danted.conf <<EOF2
logoutput: /tmp/danted.log

internal: 0.0.0.0 port = $SOCKS_PORT
external: $WAN_IF

socksmethod: username
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

    # 创建日志文件
    touch /tmp/danted.log
    chmod 644 /tmp/danted.log

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
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "无法自动获取，请手动查询")

    # 保存 SOCKS5 凭证到文件（仅 root 可读）
    cat > /root/.socks5_credentials <<EOF
SOCKS5_USER=$SOCKS_USER
SOCKS5_PASS=$SOCKS_PASS
SOCKS5_PORT=$SOCKS_PORT
EOF
    chmod 600 /root/.socks5_credentials

    echo "===================================================="
    echo "#           Telegram联系：@NameQC                   #"
    echo "#    全球服务器 免实名服务器 高防服务器 站群服务器  #"
    echo "#         Telegram双向机器人：@NameQCBot            #"
    echo "===================================================="
    echo " 安装完成：L2TP/IPsec + SOCKS5（Ubuntu 24 终极版）"
    echo "===================================================="
    echo "检查命令："
    echo "  ipsec status"
    echo "  journalctl -u strongswan-starter -n 30"
    echo "  journalctl -u xl2tpd -n 30"
    echo "  journalctl -u danted -n 30"
    echo "  ss -lunp  | grep -E '500|4500|1701'"
    echo "  ss -tnlp  | grep $SOCKS_PORT"
    echo "---------------------------------------------------"
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
    echo "【管理命令】"
    echo "  输入 'vpn' 即可调出综合管理菜单"
    echo "===================================================="
}

########################
# 主入口：根据参数和安装状态决定行为
########################
if [[ "$1" == "install" ]]; then
    install_vpn
    cp -f "$0" /usr/local/bin/vpn
    chmod +x /usr/local/bin/vpn
    echo "✅ 管理命令已安装：输入 'vpn' 即可管理"
elif [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "用法:"
    echo "  vpn install    - 安装服务"
    echo "  vpn            - 显示管理菜单"
else
    if [ -f /etc/ppp/chap-secrets ]; then
        show_main_menu
    else
        install_vpn
        cp -f "$0" /usr/local/bin/vpn
        chmod +x /usr/local/bin/vpn
        echo "✅ 管理命令已安装：输入 'vpn' 即可管理"
    fi
fi
