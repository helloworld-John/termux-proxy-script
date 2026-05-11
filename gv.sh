#!/bin/bash
# ==========================================
# Local-Proxy-Hub 局域网共享代理 (Gost v3 通用版)
# 特性：全网卡被动监听，智能过滤局域网IP，随机端口，全局快捷指令
# ==========================================

# --- 全局路径与变量 ---
BIN_FILE="$HOME/gost"
CONF_FILE="$HOME/config.json"
LOG_FILE="$HOME/gost_proxy.log"
PREF_FILE="$HOME/.proxy_pref.conf"
SHORTCUT_NAME="gv"

# 加载本地保存的配置
[ -f "$PREF_FILE" ] && source "$PREF_FILE"

# --- 暴力设置全局快捷指令 ---
setup_shortcut() {
    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    
    # 暴力判断存放环境 (优先 Termux 真实路径)
    if [ -d "/data/data/com.termux/files/usr/bin" ]; then
        BIN_DIR="/data/data/com.termux/files/usr/bin"
    elif [ -w "/usr/local/bin" ]; then
        BIN_DIR="/usr/local/bin"
    else
        BIN_DIR="$HOME/.local/bin"
        mkdir -p "$BIN_DIR" 2>/dev/null
    fi

    # 写入快捷唤醒脚本
    if [ -d "$BIN_DIR" ]; then
        cat > "$BIN_DIR/$SHORTCUT_NAME" <<EOF
#!/bin/bash
bash "$SCRIPT_PATH"
EOF
        chmod +x "$BIN_DIR/$SHORTCUT_NAME"
    fi
}

# --- 智能获取真实局域网 IP (过滤蜂窝网络) ---
get_network_status() {
    DISPLAY_IP=""
    IP_WARNING=""

    # 1. 第一优先级：强制寻找标准局域网网段 (192.168.x.x, 10.x.x.x, 172.16~31.x.x)
    DISPLAY_IP=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -E '^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[0-1]))\.' | head -n 1)

    # 2. 第二优先级：如果没找到标准内网 IP，尝试抓取 WiFi (wlan) 或 热点 (ap/rndis)
    if [ -z "$DISPLAY_IP" ]; then
        DISPLAY_IP=$(ip -4 addr show 2>/dev/null | grep -E 'wlan|ap|rndis|usb' -A 2 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    fi

    # 3. 兜底方案：抓取除了 127.0.0.1 以外的任何 IP
    if [ -z "$DISPLAY_IP" ]; then
        DISPLAY_IP=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    fi

    [ -z "$DISPLAY_IP" ] && DISPLAY_IP="未获取到 IP (请检查WIFI)"

    # --- 智能警告逻辑 ---
    if [[ "$DISPLAY_IP" == 100.* ]]; then
        IP_WARNING="\033[31m⚠️ 警告: 检测到运营商蜂窝IP ($DISPLAY_IP)，外部设备无法连接！请连上 WiFi 或开启个人热点。\033[0m"
    fi

    # 获取网卡详细信息用于展示
    NET_INFO=$(ip -4 addr show 2>/dev/null | grep -w "inet $DISPLAY_IP" | awk '{print $2, $NF}' | head -n 1)
    [ -z "$NET_INFO" ] && NET_INFO="未知网卡"
}

# --- 核心下载与安装 ---
install_core(){
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) GOST_ARCH="arm64" ;;
        x86_64|amd64) GOST_ARCH="amd64" ;;
        *) echo "暂不支持的架构: $ARCH"; exit 1 ;;
    esac

    GOST_VER="3.0.0"
    DOWNLOAD_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VER}/gost_${GOST_VER}_linux_${GOST_ARCH}.tar.gz"

    if [ ! -e "$BIN_FILE" ]; then
        echo "正在下载 Gost 核心 ($GOST_ARCH)..."
        curl -L -o gost.tar.gz -# --retry 2 --insecure "https://ghproxy.com/${DOWNLOAD_URL}"
        tar zxvf gost.tar.gz
        
        EXTRACTED_DIR="gost_${GOST_VER}_linux_${GOST_ARCH}"
        if [ -d "$EXTRACTED_DIR" ]; then
            mv "${EXTRACTED_DIR}/gost" "$BIN_FILE"
        elif [ -f "gost" ]; then
            mv gost "$BIN_FILE"
        fi
        
        chmod +x "$BIN_FILE"
        rm -rf gost.tar.gz README* LICENSE* "$EXTRACTED_DIR"
    fi
}

# --- 配置与启动代理 ---
setup_proxy(){
    pkg install -y screen wget net-tools iproute2 2>/dev/null || apt install -y screen wget net-tools iproute2 2>/dev/null
    
    install_core

    echo "------------------------------------------------"
    echo "提示：非 Root 权限必须使用 1024 以上的端口。"
    echo "留空直接回车将自动分配 10000-65535 之间的随机端口"
    echo "------------------------------------------------"
    
    read -p "设置 Socks5 端口 [范围: 1024-65535] (当前: ${PORT_SOCKS:-无}): " input_socks
    if [ -n "$input_socks" ]; then
        PORT_SOCKS=$input_socks
    elif [ -z "$PORT_SOCKS" ]; then
        PORT_SOCKS=$(shuf -i 10000-65535 -n 1)
    fi

    read -p "设置 Http 端口 [范围: 1024-65535] (当前: ${PORT_HTTP:-无}): " input_http
    if [ -n "$input_http" ]; then
        PORT_HTTP=$input_http
    elif [ -z "$PORT_HTTP" ]; then
        PORT_HTTP=$(shuf -i 10000-65535 -n 1)
    fi

    echo "PORT_SOCKS=$PORT_SOCKS" > "$PREF_FILE"
    echo "PORT_HTTP=$PORT_HTTP" >> "$PREF_FILE"

    cat > "$CONF_FILE" <<EOF
{
  "services": [
    {
      "name": "service-socks5",
      "addr": ":${PORT_SOCKS}",
      "handler": {"type": "socks5", "metadata": {"udp": true}},
      "listener": {"type": "tcp"}
    },
    {
      "name": "service-http",
      "addr": ":${PORT_HTTP}",
      "handler": {"type": "http"},
      "listener": {"type": "tcp"}
    }
  ]
}
EOF

    pkill -f "gost -C" 2>/dev/null
    nohup "$BIN_FILE" -C "$CONF_FILE" > "$LOG_FILE" 2>&1 &
    
    echo "配置更新并尝试启动完毕！"
    sleep 2
}

# --- 彻底卸载 ---
uninstall(){
    pkill -f "gost -C" 2>/dev/null
    rm -f "$BIN_FILE" "$CONF_FILE" "$LOG_FILE" "$PREF_FILE"
    
    if [ -d "/data/data/com.termux/files/usr/bin" ]; then
        rm -f "/data/data/com.termux/files/usr/bin/$SHORTCUT_NAME"
    fi
    echo "已彻底清理核心及配置文件。"
    sleep 2
}

# --- 主菜单 ---
show_menu(){
    setup_shortcut

    while true; do
        get_network_status
        clear
        echo "================================================" 
        echo "        Local-Proxy-Hub 局域网代理服务          "
        echo "================================================" 
        echo -e " 📡 \033[36m智能网卡捕获状态:\033[0m"
        echo -e "    网络详情 : $NET_INFO"
        if [ -n "$IP_WARNING" ]; then
            echo -e "    $IP_WARNING"
        fi
        echo "------------------------------------------------"
        echo " 1. 安装/配置/重启代理"
        echo " 2. 卸载代理"
        echo " 3. 查看当前配置文件"
        echo " 4. 实时查看运行日志 (Ctrl+C 退出日志)"
        echo " 0. 退出面板"
        echo "------------------------------------------------"
        
        if pgrep -f "gost -C" > /dev/null; then
            echo -e " 状态: \033[32m🟢 运行中\033[0m (0.0.0.0 全网卡被动监听)"
            echo "------------------------------------------------"
            echo " V2ray/局域网设备 连接指南:"
            echo -e " - 目标 IP : \033[33m$DISPLAY_IP\033[0m"
            echo " - Socks5  : ${PORT_SOCKS}"
            echo " - Http    : ${PORT_HTTP}"
        else
            echo -e " 状态: \033[31m🔴 已停止\033[0m"
        fi
        echo "================================================"
        
        read -p "请输入选项 [0-4]: " Input
        case "$Input" in     
            1) setup_proxy ;;
            2) uninstall ;;
            3) [ -f "$CONF_FILE" ] && cat "$CONF_FILE" || echo "未找到配置文件！"; read -n 1 -s -r -p "按任意键继续..." ;;
            4) [ -f "$LOG_FILE" ] && tail -f "$LOG_FILE" || echo "暂无日志！"; sleep 2 ;;
            0) 
                echo -e "\n已退出。"
                echo -e "💡 \033[32m提示：全局快捷指令已生效！请直接输入 \033[33mgv\033[32m 并回车即可再次进入此面板。\033[0m\n"
                exit 0 
                ;;
            *) echo "无效输入，请重新选择"; sleep 1 ;;
        esac
    done
}

# 运行主程序
show_menu
