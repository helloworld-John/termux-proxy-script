#!/bin/bash
# ==========================================
# Local-Proxy-Hub 局域网代理面板 (极简暴力版)
# ==========================================

# --- 全局路径与变量 ---
BIN_FILE="$HOME/gost"
CONF_FILE="$HOME/config.json"
LOG_FILE="$HOME/gost_proxy.log"
PREF_FILE="$HOME/.proxy_pref.conf"
SHORTCUT_FILE="$HOME/gv.sh"

# 加载保存的端口
[ -f "$PREF_FILE" ] && source "$PREF_FILE"

# --- 核心逻辑 1：生成最简单的快捷运行脚本 ---
setup_shortcut() {
    # 找到你当前运行这个脚本的绝对位置
    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    
    # 直接在你的主目录 ($HOME) 生成 gv.sh
    echo "#!/bin/bash" > "$SHORTCUT_FILE"
    echo "bash \"$SCRIPT_PATH\"" >> "$SHORTCUT_FILE"
    chmod +x "$SHORTCUT_FILE"
}

# --- 核心逻辑 2：暴力抓取 192.168 等局域网 IP ---
get_lan_ip() {
    # 直接扫描 ifconfig 输出，暴力抠出 192.168.x.x 或 10.x.x.x 或 172.x.x.x
    DISPLAY_IP=$( (ifconfig 2>/dev/null || ip addr 2>/dev/null) | grep -Eo '(192\.168\.[0-9]{1,3}\.[0-9]{1,3}|10\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3})' | head -n 1 )
    
    if [ -z "$DISPLAY_IP" ]; then
        DISPLAY_IP="未找到 192.168.x.x (请确认手机已连WiFi或开启热点)"
    fi
}

# --- 下载核心 ---
install_core(){
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) GOST_ARCH="arm64" ;;
        x86_64|amd64) GOST_ARCH="amd64" ;;
        *) echo "暂不支持的架构: $ARCH"; exit 1 ;;
    esac

    GOST_VER="3.0.0"
    if [ ! -x "$BIN_FILE" ]; then
        echo "核心缺失，正在下载..."
        curl -L -o gost.tar.gz -# "https://ghproxy.com/https://github.com/go-gost/gost/releases/download/v${GOST_VER}/gost_${GOST_VER}_linux_${GOST_ARCH}.tar.gz"
        tar zxvf gost.tar.gz
        [ -d "gost_${GOST_VER}_linux_${GOST_ARCH}" ] && mv "gost_${GOST_VER}_linux_${GOST_ARCH}/gost" "$BIN_FILE"
        chmod +x "$BIN_FILE"
        rm -rf gost.tar.gz gost_*
    fi
}

# --- 配置并运行 ---
run_proxy(){
    install_core
    echo "------------------------------------------------"
    echo "⚠️  请输入端口号 (范围: 1024 - 65535，直接回车则随机生成)"
    echo "------------------------------------------------"
    
    # 按照你的要求，全部改为 Socks
    read -p "请输入 Socks 端口 [当前: ${PORT_SOCKS:-随机}]: " s_p
    PORT_SOCKS=${s_p:-${PORT_SOCKS:-$(shuf -i 10000-60000 -n 1)}}
    
    read -p "请输入 Http 端口 [当前: ${PORT_HTTP:-随机}]: " h_p
    PORT_HTTP=${h_p:-${PORT_HTTP:-$(shuf -i 10000-60000 -n 1)}}

    # 保存配置
    echo "PORT_SOCKS=$PORT_SOCKS" > "$PREF_FILE"
    echo "PORT_HTTP=$PORT_HTTP" >> "$PREF_FILE"

    # 生成 Gost 配置文件 (0.0.0.0 监听)
    # 注意：Gost引擎强制要求 handler type 为 "socks5"，这是程序语法，但服务名我已改为 socks
    cat > "$CONF_FILE" <<EOF
{
  "services": [
    {
      "name": "service-socks",
      "addr": ":$PORT_SOCKS",
      "handler": {"type": "socks5", "metadata": {"udp": true}},
      "listener": {"type": "tcp"}
    },
    {
      "name": "service-http",
      "addr": ":$PORT_HTTP",
      "handler": {"type": "http"},
      "listener": {"type": "tcp"}
    }
  ]
}
EOF

    pkill -f "gost -C" 2>/dev/null
    nohup "$BIN_FILE" -C "$CONF_FILE" > "$LOG_FILE" 2>&1 &
    echo -e "\n代理已启动！请看上方菜单的连接信息。"
    sleep 2
}

# --- 卸载 ---
uninstall(){
    pkill -f "gost -C" 2>/dev/null
    rm -f "$BIN_FILE" "$CONF_FILE" "$LOG_FILE" "$PREF_FILE" "$SHORTCUT_FILE"
    echo "卸载成功，快捷脚本已清除。"
    sleep 2
}

# --- 主菜单 ---
show_menu(){
    # 每次打开自动生成/更新 gv.sh
    setup_shortcut
    
    while true; do
        get_lan_ip
        clear
        echo "================================================"
        echo "        局域网代理服务面板 (极简版)             "
        echo "================================================"
        
        if pgrep -f "gost -C" > /dev/null; then
            echo -e " 状态: \033[32m🟢 正在运行\033[0m"
            echo "------------------------------------------------"
            echo -e " \033[36m请将以下信息填入 V2ray 或其他设备：\033[0m"
            echo -e " 目标 IP : \033[33m$DISPLAY_IP\033[0m"
            echo -e " Socks   : \033[32m$PORT_SOCKS\033[0m"
            echo -e " Http    : \033[32m$PORT_HTTP\033[0m"
        else
            echo -e " 状态: \033[31m🔴 已停止\033[0m"
        fi
        
        echo "================================================"
        echo " 1. 启动/重新配置代理 (设置 Socks/Http 端口)"
        echo " 2. 停止并完全卸载"
        echo " 3. 查看实时运行日志"
        echo -e " 0. \033[31m退出面板\033[0m"
        echo "------------------------------------------------"
        
        read -p "请输入选项: " opt
        case $opt in
            1) run_proxy ;;
            2) uninstall ;;
            3) [ -f "$LOG_FILE" ] && tail -f "$LOG_FILE" || echo "暂无日志"; sleep 2;;
            0) 
               echo -e "\n已退出。"
               echo -e "💡 快捷指令已生成！下次只需输入 \033[32mbash ~/gv.sh\033[0m 即可再次打开本菜单。\n"
               exit 0 
               ;;
            *) echo "无效输入" ;;
        esac
    done
}

show_menu
