#!/bin/bash
# ==========================================
# Local-Proxy-Hub (Gost v3 增强版)
# 特性：直观显示 ifconfig、全网卡监听、全局快捷指令
# ==========================================

# --- 全局路径与变量 ---
BIN_FILE="$HOME/gost"
CONF_FILE="$HOME/config.json"
LOG_FILE="$HOME/gost_proxy.log"
PREF_FILE="$HOME/.proxy_pref.conf"
SHORTCUT_NAME="gv"

# 加载保存的端口
[ -f "$PREF_FILE" ] && source "$PREF_FILE"

# --- 核心逻辑：设置全局快捷指令 ---
setup_shortcut() {
    # 找到脚本当前的绝对路径
    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    
    # 确定可执行目录
    if [ -d "/data/data/com.termux/files/usr/bin" ]; then
        TARGET_BIN="/data/data/com.termux/files/usr/bin/$SHORTCUT_NAME"
    else
        TARGET_BIN="/usr/local/bin/$SHORTCUT_NAME"
    fi

    # 写入快捷脚本
    if [ ! -f "$TARGET_BIN" ]; then
        echo -e "#!/bin/bash\nbash \"$SCRIPT_PATH\"" > "$TARGET_BIN"
        chmod +x "$TARGET_BIN"
    fi
}

# --- 核心逻辑：获取原始网络信息 ---
get_raw_net_info() {
    # 获取所有非 127.0.0.1 的 IP 地址，并保留它们所属的网卡名
    RAW_IP_LIST=$(ifconfig | grep -E "inet |flags" | awk '
        /flags/ {interface=$1} 
        /inet / {print "    网卡 [" interface "] 地址: " $2}
    ' | grep -v "127.0.0.1" | tr -d ':')
    
    # 尝试提取一个建议 IP (优先 WiFi)
    SUGGEST_IP=$(ifconfig wlan0 2>/dev/null | grep "inet " | awk '{print $2}' | tr -d 'addr:')
    if [ -z "$SUGGEST_IP" ]; then
        SUGGEST_IP=$(ifconfig 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | head -n 1 | awk '{print $2}' | tr -d 'addr:')
    fi
    [ -z "$SUGGEST_IP" ] && SUGGEST_IP="请检查网络"
}

# --- 核心逻辑：下载核心 ---
install_core(){
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) GOST_ARCH="arm64" ;;
        x86_64|amd64) GOST_ARCH="amd64" ;;
        *) echo "暂不支持的架构: $ARCH"; exit 1 ;;
    esac

    GOST_VER="3.0.0"
    if [ ! -x "$BIN_FILE" ]; then
        echo "核心缺失，正在从加速通道下载..."
        curl -L -o gost.tar.gz -# "https://ghproxy.com/https://github.com/go-gost/gost/releases/download/v${GOST_VER}/gost_${GOST_VER}_linux_${GOST_ARCH}.tar.gz"
        tar zxvf gost.tar.gz
        [ -d "gost_${GOST_VER}_linux_${GOST_ARCH}" ] && mv "gost_${GOST_VER}_linux_${GOST_ARCH}/gost" "$BIN_FILE"
        chmod +x "$BIN_FILE"
        rm -rf gost.tar.gz gost_*
    fi
}

# --- 核心逻辑：配置并运行 ---
run_proxy(){
    install_core
    echo "------------------------------------------------"
    echo "⚠️  注意：端口范围需在 1024 - 65535 之间"
    echo "------------------------------------------------"
    read -p "请输入 Socks5 端口 [当前: ${PORT_SOCKS:-随机}]: " s_p
    PORT_SOCKS=${s_p:-${PORT_SOCKS:-$(shuf -i 10000-60000 -n 1)}}
    
    read -p "请输入 Http 端口 [当前: ${PORT_HTTP:-随机}]: " h_p
    PORT_HTTP=${h_p:-${PORT_HTTP:-$(shuf -i 10000-60000 -n 1)}}

    # 保存配置到文件
    echo "PORT_SOCKS=$PORT_SOCKS" > "$PREF_FILE"
    echo "PORT_HTTP=$PORT_HTTP" >> "$PREF_FILE"

    # 生成 Gost 配置文件 (监听 0.0.0.0)
    cat > "$CONF_FILE" <<EOF
{
  "services": [
    {
      "name": "service-socks5",
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
    echo -e "\n代理已尝试启动！请通过菜单查看状态。"
    sleep 2
}

# --- 卸载 ---
uninstall(){
    pkill -f "gost -C" 2>/dev/null
    rm -f "$BIN_FILE" "$CONF_FILE" "$LOG_FILE" "$PREF_FILE"
    echo "卸载成功。"
    sleep 2
}

# --- 主菜单 ---
show_menu(){
    setup_shortcut
    while true; do
        get_raw_net_info
        clear
        echo "================================================"
        echo "        Local-Proxy-Hub 局域网面板             "
        echo "================================================"
        echo -e " 📡 \033[36m当前实时网络信息 (ifconfig):\033[0m"
        echo -e "$RAW_IP_LIST"
        echo "------------------------------------------------"
        echo " 1. 启动/重新配置代理 (设置端口)"
        echo " 2. 停止并完全卸载"
        echo " 3. 查看实时运行日志"
        echo " 0. 退出 (退出后输入 gv 即可再次打开)"
        echo "------------------------------------------------"
        
        if pgrep -f "gost -C" > /dev/null; then
            echo -e " 状态: \033[32m🟢 正在运行\033[0m"
            echo -e " \033[33mV2ray 连接参考信息:\033[0m"
            echo -e " 建议 IP : $SUGGEST_IP"
            echo -e " Socks5  : $PORT_SOCKS"
            echo -e " Http    : $PORT_HTTP"
        else
            echo -e " 状态: \033[31m🔴 已停止\033[0m"
        fi
        echo "================================================"
        
        read -p "请输入选项: " opt
        case $opt in
            1) run_proxy ;;
            2) uninstall ;;
            3) [ -f "$LOG_FILE" ] && tail -f "$LOG_FILE" || echo "暂无日志";;
            0) exit 0 ;;
            *) echo "无效输入" ;;
        esac
    done
}

show_menu
