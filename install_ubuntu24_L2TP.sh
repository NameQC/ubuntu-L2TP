#!/usr/bin/env bash
set -e

########################
# 自动修复换行符（防止 Windows CRLF 问题）
########################
if [[ -f "$0" ]]; then
    if grep -q $'\r' "$0"; then
        echo "检测到 Windows 换行符 (CRLF)，正在自动转换..."
        TMP_FILE=$(mktemp)
        tr -d '\r' < "$0" > "$TMP_FILE"
        cat "$TMP_FILE" > "$0"
        rm -f "$TMP_FILE"
        echo "换行符已转换为 Unix 格式 (LF)"
        exec bash "$0" "$@"
    fi
fi

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

# VLESS 配置
VLESS_PORT=443
VLESS_UUID=""
VLESS_PATH="/"

########################
# 函数：检测已安装服务
########################
check_installed_services() {
    INSTALLED_L2TP=0
    INSTALLED_SOCKS5=0
    INSTALLED_VLESS=0
    
    if [ -f /etc/ppp/chap-secrets ] && [ -f /etc/ipsec.conf ]; then
        INSTALLED_L2TP=1
    fi
    
    if [ -f /etc/danted.conf ] && systemctl list-units --type=service 2>/dev/null | grep -q danted; then
        INSTALLED_SOCKS5=1
    fi
    
    if [ -f /usr/local/bin/xray ] || [ -f /usr/local/bin/v2ray ]; then
        INSTALLED_VLESS=1
    fi
}

########################
# 函数：L2TP 管理菜单
########################
show_l2tp_menu() {
    echo "===================================================="
    echo "           L2TP/IPSec VPN 管理菜单"
    echo "===================================================="
    if [ $INSTALLED_L2TP -eq 0 ]; then
        echo "⚠️  L2TP/IPSec VPN 未安装，请先安装"
        echo "===================================================="
        read -p "按回车键继续..."
        return 1
    fi
    
    echo "当前VPN用户列表："
    if [ -f /etc/ppp/chap-secrets ]; then
        grep -v "^#" /etc/ppp/chap-secrets | awk '{print "  用户名: " $1 " | 密码: " $3}'
    fi

    echo ""
    echo "请选择要执行的操作："
    echo "  1) 修改现有用户密码"
    echo "  2) 添加新用户"
    echo "  3) 删除用户"
    echo "  4) 修改预共享密钥(PSK)"
    echo "  5) 查看VPN连接信息"
    echo "  6) 重启VPN服务"
    echo "  7) 卸载L2TP服务"
    echo "  0) 返回主菜单"
    read -p "请输入选项 (0-7): " ACTION

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
        7)
            read -p "确认要卸载L2TP服务吗？(y/n): " CONFIRM
            if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
                echo "正在卸载L2TP服务..."
                systemctl stop strongswan-starter xl2tpd 2>/dev/null
                systemctl disable strongswan-starter xl2tpd 2>/dev/null
                apt remove -y strongswan xl2tpd 2>/dev/null
                rm -rf /etc/ipsec.conf /etc/ipsec.secrets /etc/xl2tpd /etc/ppp/chap-secrets
                echo "✅ L2TP服务已卸载！"
                INSTALLED_L2TP=0
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
# 函数：SOCKS5 管理菜单
########################
show_socks5_menu() {
    echo "===================================================="
    echo "           SOCKS5 代理管理菜单"
    echo "===================================================="
    if [ $INSTALLED_SOCKS5 -eq 0 ]; then
        echo "⚠️  SOCKS5 代理未安装，请先安装"
        echo "===================================================="
        read -p "按回车键继续..."
        return 1
    fi
    
    echo "当前SOCKS5用户列表："
    if [ -f /etc/danted.conf ]; then
        local SOCKS_USER_LIST=$(grep -E "^user\." /etc/danted.conf | head -1 | awk -F'.' '{print $2}')
        if [ -n "$SOCKS_USER_LIST" ]; then
            echo "  用户名: $SOCKS_USER_LIST"
            if grep -q "^$SOCKS_USER_LIST:" /etc/shadow 2>/dev/null; then
                echo "  密码: 已设置"
            else
                echo "  密码: 未设置"
            fi
        else
            echo "  未找到SOCKS5用户配置"
        fi
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
            local CURRENT_PORT=$(grep -E "^internal: 0.0.0.0 port =" /etc/danted.conf | awk '{print $5}')
            read -p "请输入新的SOCKS5端口 (当前: $CURRENT_PORT): " NEW_PORT
            if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
                echo "错误：端口必须是1-65535之间的数字！"
                return 1
            fi
            sed -i "s/internal: 0.0.0.0 port = $CURRENT_PORT/internal: 0.0.0.0 port = $NEW_PORT/" /etc/danted.conf
            iptables -A INPUT -p tcp --dport $NEW_PORT -j ACCEPT 2>/dev/null
            netfilter-persistent save 2>/dev/null
            echo "✅ SOCKS5端口已更新为 $NEW_PORT，服务将重启..."
            systemctl restart danted
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
                apt remove -y danted 2>/dev/null
                rm -f /etc/danted.conf
                echo "✅ SOCKS5服务已卸载！"
                INSTALLED_SOCKS5=0
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
# 函数：VLESS 管理菜单
########################
show_vless_menu() {
    echo "===================================================="
    echo "           VLESS 代理管理菜单"
    echo "===================================================="
    if [ $INSTALLED_VLESS -eq 0 ]; then
        echo "⚠️  VLESS 代理未安装，请先安装"
        echo "===================================================="
        read -p "按回车键继续..."
        return 1
    fi
    
    # 检测使用Xray还是v2ray
    if [ -f /usr/local/bin/xray ]; then
        VLESS_BIN="xray"
        VLESS_SERVICE="xray"
    else
        VLESS_BIN="v2ray"
        VLESS_SERVICE="v2ray"
    fi
    
    echo "当前VLESS配置信息："
    if [ -f /usr/local/etc/$VLESS_BIN/config.json ]; then
        local PORT=$(grep -o '"port": [0-9]*' /usr/local/etc/$VLESS_BIN/config.json 2>/dev/null | head -1 | awk '{print $2}')
        local UUID=$(grep -o '"id": "[^"]*"' /usr/local/etc/$VLESS_BIN/config.json 2>/dev/null | head -1 | cut -d'"' -f4)
        local PATH=$(grep -o '"path": "[^"]*"' /usr/local/etc/$VLESS_BIN/config.json 2>/dev/null | head -1 | cut -d'"' -f4)
        echo "  端口: ${PORT:-未设置}"
        echo "  UUID: ${UUID:-未设置}"
        echo "  Path: ${PATH:-/}"
    fi

    echo ""
    echo "请选择要执行的操作："
    echo "  1) 修改VLESS端口"
    echo "  2) 修改VLESS UUID"
    echo "  3) 修改VLESS Path"
    echo "  4) 查看VLESS服务状态"
    echo "  5) 重启VLESS服务"
    echo "  6) 显示VLESS连接URL"
    echo "  7) 卸载VLESS服务"
    echo "  0) 返回主菜单"
    read -p "请输入选项 (0-7): " ACTION

    case $ACTION in
        1)
            local CURRENT_PORT=$(grep -o '"port": [0-9]*' /usr/local/etc/$VLESS_BIN/config.json 2>/dev/null | head -1 | awk '{print $2}')
            read -p "请输入新的端口 (当前: ${CURRENT_PORT:-443}): " NEW_PORT
            if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
                echo "错误：端口必须是1-65535之间的数字！"
                return 1
            fi
            sed -i "s/\"port\": [0-9]*/\"port\": $NEW_PORT/" /usr/local/etc/$VLESS_BIN/config.json
            echo "✅ 端口已更新为 $NEW_PORT"
            systemctl restart $VLESS_SERVICE
            ;;
        2)
            local NEW_UUID=$(cat /proc/sys/kernel/random/uuid)
            echo "生成新UUID: $NEW_UUID"
            read -p "确认使用此UUID？(y/n): " CONFIRM
            if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
                sed -i "s/\"id\": \"[^\"]*\"/\"id\": \"$NEW_UUID\"/" /usr/local/etc/$VLESS_BIN/config.json
                echo "✅ UUID已更新"
                systemctl restart $VLESS_SERVICE
            fi
            ;;
        3)
            local CURRENT_PATH=$(grep -o '"path": "[^"]*"' /usr/local/etc/$VLESS_BIN/config.json 2>/dev/null | head -1 | cut -d'"' -f4)
            read -p "请输入新的Path (当前: ${CURRENT_PATH:-/}): " NEW_PATH
            if [ -z "$NEW_PATH" ]; then
                NEW_PATH="/"
            fi
            sed -i "s/\"path\": \"[^\"]*\"/\"path\": \"$NEW_PATH\"/" /usr/local/etc/$VLESS_BIN/config.json
            echo "✅ Path已更新为 $NEW_PATH"
            systemctl restart $VLESS_SERVICE
            ;;
        4)
            echo ""
            echo "【VLESS 服务状态】"
            systemctl status $VLESS_SERVICE --no-pager 2>/dev/null | grep "Active:"
            echo ""
            echo "【端口监听】"
            local PORT=$(grep -o '"port": [0-9]*' /usr/local/etc/$VLESS_BIN/config.json 2>/dev/null | head -1 | awk '{print $2}')
            ss -tnlp 2>/dev/null | grep ":$PORT" || echo "  未监听"
            echo ""
            echo "【最新日志】"
            journalctl -u $VLESS_SERVICE -n 10 --no-pager 2>/dev/null || echo "  无日志"
            ;;
        5)
            echo "正在重启VLESS服务..."
            systemctl restart $VLESS_SERVICE
            echo "✅ VLESS服务已重启！"
            ;;
        6)
            show_vless_url
            ;;
        7)
            read -p "确认要卸载VLESS服务吗？(y/n): " CONFIRM
            if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
                echo "正在卸载VLESS服务..."
                systemctl stop $VLESS_SERVICE 2>/dev/null
                systemctl disable $VLESS_SERVICE 2>/dev/null
                rm -rf /usr/local/etc/$VLESS_BIN
                rm -f /usr/local/bin/$VLESS_BIN
                rm -f /etc/systemd/system/$VLESS_SERVICE.service
                systemctl daemon-reload
                echo "✅ VLESS服务已卸载！"
                INSTALLED_VLESS=0
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
# 函数：显示VLESS连接URL
########################
show_vless_url() {
    if [ $INSTALLED_VLESS -eq 0 ]; then
        echo "VLESS未安装"
        return 1
    fi
    
    if [ -f /usr/local/bin/xray ]; then
        VLESS_BIN="xray"
    else
        VLESS_BIN="v2ray"
    fi
    
    local PORT=$(grep -o '"port": [0-9]*' /usr/local/etc/$VLESS_BIN/config.json 2>/dev/null | head -1 | awk '{print $2}')
    local UUID=$(grep -o '"id": "[^"]*"' /usr/local/etc/$VLESS_BIN/config.json 2>/dev/null | head -1 | cut -d'"' -f4)
    local PATH=$(grep -o '"path": "[^"]*"' /usr/local/etc/$VLESS_BIN/config.json 2>/dev/null | head -1 | cut -d'"' -f4)
    local DOMAIN=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "未知")
    
    echo ""
    echo "===================================================="
    echo "           VLESS 连接信息"
    echo "===================================================="
    echo "  服务器: $DOMAIN"
    echo "  端口: ${PORT:-443}"
    echo "  UUID: ${UUID:-未设置}"
    echo "  Path: ${PATH:-/}"
    echo ""
    echo "【VLESS链接】"
    echo "vless://${UUID:-}@$DOMAIN:${PORT:-443}?encryption=none&security=none&type=ws&path=${PATH:-/}#VLESS"
    echo ""
    echo "【客户端配置】"
    echo "{"
    echo "  \"v\": \"2\","
    echo "  \"ps\": \"VLESS\","
    echo "  \"add\": \"$DOMAIN\","
    echo "  \"port\": \"${PORT:-443}\","
    echo "  \"id\": \"${UUID:-}\","
    echo "  \"aid\": \"0\","
    echo "  \"net\": \"ws\","
    echo "  \"type\": \"none\","
    echo "  \"host\": \"\","
    echo "  \"path\": \"${PATH:-/}\","
    echo "  \"tls\": \"none\""
    echo "}"
    echo "===================================================="
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
        echo "              QC 综合管理菜单"
        echo "===================================================="
        
        check_installed_services
        
        echo ""
        echo "  1) 管理 L2TP/IPSec VPN $([ $INSTALLED_L2TP -eq 1 ] && echo "[已安装]" || echo "[未安装]")"
        echo "  2) 管理 SOCKS5 代理 $([ $INSTALLED_SOCKS5 -eq 1 ] && echo "[已安装]" || echo "[未安装]")"
        echo "  3) 管理 VLESS 代理 $([ $INSTALLED_VLESS -eq 1 ] && echo "[已安装]" || echo "[未安装]")"
        echo "  4) 查看服务整体状态"
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
                show_vless_menu
                ;;
            4)
                show_service_status
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
# 函数：查看服务整体状态
########################
show_service_status() {
    echo ""
    echo "===================================================="
    echo "              服务整体状态"
    echo "===================================================="
    
    check_installed_services
    
    echo "【L2TP/IPSec】$([ $INSTALLED_L2TP -eq 1 ] && echo "[已安装]" || echo "[未安装]")"
    if [ $INSTALLED_L2TP -eq 1 ]; then
        systemctl status strongswan-starter --no-pager 2>/dev/null | grep "Active:" || echo "  strongSwan: 未运行"
        systemctl status xl2tpd --no-pager 2>/dev/null | grep "Active:" || echo "  xl2tpd: 未运行"
    fi
    echo ""
    
    echo "【SOCKS5】$([ $INSTALLED_SOCKS5 -eq 1 ] && echo "[已安装]" || echo "[未安装]")"
    if [ $INSTALLED_SOCKS5 -eq 1 ]; then
        systemctl status danted --no-pager 2>/dev/null | grep "Active:" || echo "  未运行"
    fi
    echo ""
    
    echo "【VLESS】$([ $INSTALLED_VLESS -eq 1 ] && echo "[已安装]" || echo "[未安装]")"
    if [ $INSTALLED_VLESS -eq 1 ]; then
        if [ -f /usr/local/bin/xray ]; then
            systemctl status xray --no-pager 2>/dev/null | grep "Active:" || echo "  未运行"
        elif [ -f /usr/local/bin/v2ray ]; then
            systemctl status v2ray --no-pager 2>/dev/null | grep "Active:" || echo "  未运行"
        fi
    fi
    echo ""
    
    echo "【端口监听】"
    ss -lunp 2>/dev/null | grep -E '500|4500|1701|1080|443|80' || echo "  无相关端口"
    echo ""
    read -p "按回车键继续..."
}

########################
# 函数：安装 L2TP
########################
install_l2tp() {
    echo "===================================================="
    echo "           正在安装：L2TP/IPSec VPN"
    echo "===================================================="
    
    if [ $INSTALLED_L2TP -eq 1 ]; then
        echo "检测到L2TP已安装"
        read -p "是否重新安装？(y/n): " REINSTALL
        if [[ "$REINSTALL" != "y" && "$REINSTALL" != "Y" ]]; then
            return 0
        fi
    fi
    
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

    # 检测外网网卡
    WAN_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {print $5; exit}')
    if [ -z "$WAN_IF" ]; then
        echo "无法自动检测外网网卡，请手动修改脚本中的 WAN_IF 变量后再运行。"
        return 1
    fi
    echo "检测到外网网卡：$WAN_IF"

    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt install -y strongswan xl2tpd ppp iptables iptables-persistent

    # IP 转发 & 内核参数
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

    # strongSwan 配置
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

    # xl2tpd 配置
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

    # iptables NAT & 端口放行
    iptables -A INPUT -i lo -j ACCEPT 2>/dev/null
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -A INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null
    iptables -A INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null
    iptables -A INPUT -p udp --dport 1701 -j ACCEPT 2>/dev/null
    iptables -A FORWARD -s $VPN_NET -j ACCEPT 2>/dev/null
    iptables -A FORWARD -d $VPN_NET -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -t nat -A POSTROUTING -s $VPN_NET -o $WAN_IF -j MASQUERADE 2>/dev/null

    netfilter-persistent save 2>/dev/null

    systemctl enable strongswan-starter
    systemctl enable xl2tpd
    systemctl restart strongswan-starter
    systemctl restart xl2tpd

    INSTALLED_L2TP=1
    echo "✅ L2TP/IPSec VPN 安装完成！"
    echo "  服务器IP: $(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo '未知')"
    echo "  用户名: $VPN_USER"
    echo "  密码: $VPN_PASS"
    echo "  PSK: $VPN_PSK"
    echo ""
    read -p "按回车键继续..."
}

########################
# 函数：安装 SOCKS5
########################
install_socks5() {
    echo "===================================================="
    echo "           正在安装：SOCKS5 代理"
    echo "===================================================="
    
    if [ $INSTALLED_SOCKS5 -eq 1 ]; then
        echo "检测到SOCKS5已安装"
        read -p "是否重新安装？(y/n): " REINSTALL
        if [[ "$REINSTALL" != "y" && "$REINSTALL" != "Y" ]]; then
            return 0
        fi
    fi
    
    echo "是否自定义SOCKS5账号密码和端口？(y/n)"
    read -r CUSTOM_CHOICE

    if [[ "$CUSTOM_CHOICE" == "y" || "$CUSTOM_CHOICE" == "Y" ]]; then
        echo "请输入SOCKS5用户名:"
        read -r SOCKS_USER
        echo "请输入SOCKS5密码:"
        read -r SOCKS_PASS
        echo "请输入SOCKS5端口 (默认1080):"
        read -r SOCKS_PORT
        if [ -z "$SOCKS_PORT" ]; then
            SOCKS_PORT=1080
        fi
    else
        SOCKS_USER="NameQC"
        SOCKS_PASS="NameQC"
        SOCKS_PORT=1080
        echo "使用默认值: 用户名=$SOCKS_USER, 密码=$SOCKS_PASS, 端口=$SOCKS_PORT"
    fi

    WAN_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {print $5; exit}')
    if [ -z "$WAN_IF" ]; then
        echo "无法自动检测外网网卡"
        return 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt install -y dante-server

    id socks >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin socks
    id "$SOCKS_USER" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin "$SOCKS_USER"
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

    iptables -A INPUT -p tcp --dport $SOCKS_PORT -j ACCEPT 2>/dev/null
    netfilter-persistent save 2>/dev/null

    systemctl enable danted
    systemctl restart danted

    INSTALLED_SOCKS5=1
    echo "✅ SOCKS5 代理安装完成！"
    echo "  服务器IP: $(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo '未知')"
    echo "  端口: $SOCKS_PORT"
    echo "  用户名: $SOCKS_USER"
    echo "  密码: $SOCKS_PASS"
    echo ""
    read -p "按回车键继续..."
}

########################
# 函数：安装 VLESS
########################
install_vless() {
    echo "===================================================="
    echo "           正在安装：VLESS 代理"
    echo "===================================================="
    
    if [ $INSTALLED_VLESS -eq 1 ]; then
        echo "检测到VLESS已安装"
        read -p "是否重新安装？(y/n): " REINSTALL
        if [[ "$REINSTALL" != "y" && "$REINSTALL" != "Y" ]]; then
            return 0
        fi
    fi
    
    echo "请选择使用 Xray 还是 v2ray："
    echo "  1) Xray (推荐)"
    echo "  2) v2ray"
    read -r VLESS_CHOICE

    echo "是否自定义VLESS配置？(y/n)"
    read -r CUSTOM_CHOICE

    if [[ "$CUSTOM_CHOICE" == "y" || "$CUSTOM_CHOICE" == "Y" ]]; then
        echo "请输入VLESS端口 (默认443):"
        read -r VLESS_PORT
        if [ -z "$VLESS_PORT" ]; then
            VLESS_PORT=443
        fi
        echo "请输入UUID (直接回车自动生成):"
        read -r VLESS_UUID
        if [ -z "$VLESS_UUID" ]; then
            VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
        fi
        echo "请输入Path (默认/):"
        read -r VLESS_PATH
        if [ -z "$VLESS_PATH" ]; then
            VLESS_PATH="/"
        fi
    else
        VLESS_PORT=443
        VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
        VLESS_PATH="/"
        echo "使用默认配置: 端口=$VLESS_PORT, UUID=$VLESS_UUID, Path=$VLESS_PATH"
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt install -y curl wget unzip

    # 安装 Xray 或 v2ray
    if [ "$VLESS_CHOICE" == "1" ] || [ -z "$VLESS_CHOICE" ]; then
        echo "安装 Xray..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        VLESS_BIN="xray"
        VLESS_SERVICE="xray"
    else
        echo "安装 v2ray..."
        bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
        VLESS_BIN="v2ray"
        VLESS_SERVICE="v2ray"
    fi

    # 生成VLESS配置
    mkdir -p /usr/local/etc/$VLESS_BIN
    cat > /usr/local/etc/$VLESS_BIN/config.json <<EOF2
{
  "inbounds": [
    {
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$VLESS_UUID",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$VLESS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF2

    # 放行端口
    iptables -A INPUT -p tcp --dport $VLESS_PORT -j ACCEPT 2>/dev/null
    netfilter-persistent save 2>/dev/null

    systemctl enable $VLESS_SERVICE
    systemctl restart $VLESS_SERVICE

    INSTALLED_VLESS=1
    echo "✅ VLESS 代理安装完成！"
    echo "  服务器IP: $(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo '未知')"
    echo "  端口: $VLESS_PORT"
    echo "  UUID: $VLESS_UUID"
    echo "  Path: $VLESS_PATH"
    echo ""
    echo "【VLESS链接】"
    echo "vless://$VLESS_UUID@$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null):$VLESS_PORT?encryption=none&security=none&type=ws&path=$VLESS_PATH#VLESS"
    echo ""
    read -p "按回车键继续..."
}

########################
# 函数：安装菜单
########################
show_install_menu() {
    clear
    echo "===================================================="
    echo "#           Telegram联系：@NameQC                   #"
    echo "#    全球服务器 免实名服务器 高防服务器 站群服务器  #"
    echo "#         Telegram双向机器人：@NameQCBot            #"
    echo "===================================================="
    echo "              选择要安装的服务"
    echo "===================================================="
    echo ""
    echo "  1) 安装 L2TP/IPSec VPN"
    echo "  2) 安装 SOCKS5 代理"
    echo "  3) 安装 VLESS 代理"
    echo "  4) 安装 L2TP + SOCKS5 (组合)"
    echo "  0) 退出"
    echo ""
    read -p "请输入选项 (0-4): " INSTALL_CHOICE

    case $INSTALL_CHOICE in
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
            echo "安装 L2TP + SOCKS5 组合..."
            install_l2tp
            install_socks5
            ;;
        0)
            exit 0
            ;;
        *)
            echo "无效选项！"
            read -p "按回车键继续..."
            show_install_menu
            ;;
    esac
}

########################
# 主入口：根据参数和安装状态决定行为
########################
if [[ "$1" == "install" ]]; then
    show_install_menu
    cp -f "$0" /usr/local/bin/qc
    chmod +x /usr/local/bin/qc
    echo "✅ 管理命令已安装：输入 'qc' 即可管理"
elif [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "用法:"
    echo "  qc install    - 安装服务"
    echo "  qc            - 显示管理菜单"
else
    check_installed_services
    if [ $INSTALLED_L2TP -eq 1 ] || [ $INSTALLED_SOCKS5 -eq 1 ] || [ $INSTALLED_VLESS -eq 1 ]; then
        show_main_menu
    else
        show_install_menu
        cp -f "$0" /usr/local/bin/qc
        chmod +x /usr/local/bin/qc
        echo "✅ 管理命令已安装：输入 'qc' 即可管理"
    fi
fi
