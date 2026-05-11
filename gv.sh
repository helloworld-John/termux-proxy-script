#!/bin/bash
# ==========================================
# Google_VPN 局域网共享代理 (DNS 强化版)
# ==========================================

BIN_FILE="$HOME/gost"
CONF_FILE="$HOME/config.json"
LOG_FILE="$HOME/gost_proxy.log"
PREF_FILE="$HOME/.proxy_pref.conf"

PORT_SOCKS=10800
PORT_HTTP=18080
BIND_IP=""

[ -f "$PREF_FILE" ] && source "$PREF_FILE"

get_ip() {
    if [ -n "$BIND_IP" ]; then
        LOCAL_IP="$BIND_IP"
    else
        LOCAL_IP=$(ifconfig wlan0 2>/dev/null | grep -w 'inet' | awk '{print $2}')
        [ -z "$LOCAL_IP" ] && LOCAL_IP="127.0.0.1"
    fi
}

gvinstall(){
    pkg install -y screen wget net-tools
    if [ ! -e "$BIN_FILE" ]; then
        echo "核心下载中……"
        curl -L -o gost.tar.gz -# --retry 2 --insecure https://gh-proxy.com/https://raw.githubusercontent.com/yonggekkk/google_vpn_proxy/main/gost_3.0.0_linux_arm64.tar.gz
        tar zxvf gost.tar.gz
        [ -d "gost_3.0.0_linux_arm64" ] && mv gost_3.0.0_linux_arm64/gost "$BIN_FILE"
        chmod +x "$BIN_FILE"
        rm -rf gost.tar.gz README* LICENSE* gost_3.0.0_linux_arm64/
    fi

    get_ip
    echo "当前绑定 IP: $LOCAL_IP"
    read -p "设置 Socks5 端口 [$PORT_SOCKS]: " s_p
    PORT_SOCKS=${s_p:-$PORT_SOCKS}
    read -p "设置 Http 端口 [$PORT_HTTP]: " h_p
    PORT_HTTP=${h_p:-$PORT_HTTP}

    echo "PORT_SOCKS=$PORT_SOCKS" > "$PREF_FILE"
    echo "PORT_HTTP=$PORT_HTTP" >> "$PREF_FILE"
    echo "BIND_IP=\"$BIND_IP\"" >> "$PREF_FILE"

    # 核心修复：将 resolver 强制绑定到 handler，并改用 8.8.8.8
    cat > "$CONF_FILE" <<EOF
{
  "services": [
    {
      "name": "service-socks5",
      "addr": "${LOCAL_IP}:${PORT_SOCKS}",
      "handler": {
        "type": "socks5",
        "metadata": {"udp": true},
        "resolver": "resolver-0"
      },
      "listener": {"type": "tcp"}
    },
    {
      "name": "service-http",
      "addr": "${LOCAL_IP}:${PORT_HTTP}",
      "handler": {
        "type": "http",
        "resolver": "resolver-0"
      },
      "listener": {"type": "tcp"}
    }
  ],
  "resolvers": [
    {
      "name": "resolver-0",
      "nameservers": [
        {
          "addr": "8.8.8.8:53",
          "ttl": "60s"
        },
        {
          "addr": "8.8.4.4:53",
          "ttl": "60s"
        }
      ]
    }
  ]
}
EOF

    pkill -f "gost -C" 2>/dev/null
    nohup "$BIN_FILE" -C "$CONF_FILE" > "$LOG_FILE" 2>&1 &
    
    echo "启动命令已发出，请按 4 观察日志是否不再报错。"
    sleep 2
}

uninstall(){
    pkill -f "gost -C" 2>/dev/null
    rm -f "$BIN_FILE" "$CONF_FILE" "$LOG_FILE" "$PREF_FILE"
    echo "卸载完毕"
    sleep 2
}

change_ip(){
    echo "当前绑定 IP: ${BIND_IP:-自动获取}"
    read -p "请输入真实局域网 IP (输入 auto 恢复自动): " input_ip
    BIND_IP=$([ "$input_ip" == "auto" ] && echo "" || echo "$input_ip")
    echo "BIND_IP=\"$BIND_IP\"" > "$PREF_FILE"
    echo "PORT_SOCKS=$PORT_SOCKS" >> "$PREF_FILE"
    echo "PORT_HTTP=$PORT_HTTP" >> "$PREF_FILE"
    echo "设置成功，请按 1 重启生效。"
    sleep 2
}

show_menu(){
    while true; do
        get_ip
        clear
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
        echo "Google_VPN局域网共享代理 (DNS 修复版)"
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
        echo " 1. 启动 / 重新启动代理"
        echo " 2. 卸载代理"
        echo " 3. 查看当前配置"
        echo " 4. 实时查看日志"
        echo " 5. 绑定局域网 IP (当前: $LOCAL_IP)"
        echo " 0. 退出"
        echo "------------------------------------------------"
        pgrep -f "gost -C" > /dev/null && echo -e "状态: \033[32m🟢 运行中\033[0m" || echo -e "状态: \033[31m🔴 已停止\033[0m"
        echo "------------------------------------------------"
        read -p "请输入数字:" Input
        case "$Input" in     
            1) gvinstall ;;
            2) uninstall ;;
            3) [ -f "$CONF_FILE" ] && cat "$CONF_FILE" || echo "未安装"; sleep 5 ;;
            4) tail -f "$LOG_FILE" ;;
            5) change_ip ;;
            0) exit ;;
            *) echo "无效输入" ;;
        esac
    done
}

show_menu
