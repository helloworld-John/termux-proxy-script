#!/bin/bash
# ==========================================
# Local-Proxy-Hub 局域网共享代理 (Gost v3 通用版)
# 特性：全网卡被动监听，随机可用端口，强力IP提取，全局快捷指令
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
    # 绝对定位当前脚本
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

# --- 强力获取局域网 IP ---
get_network_status() {
    DISPLAY_IP=""
    NET_INFO=""

    # 1. 尝试使用 ip 命令精准匹配 (最可靠)
    DISPLAY_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    
    # 2. 如果失败，尝试使用 ifconfig 匹配 (兼容老安卓，去除可能存在的 addr: 字符)
    if [ -z "$DISPLAY_IP" ]; then
        DISPLAY_IP=$(ifconfig wlan0 2>/dev/null | grep -i 'inet' | grep -v '127.0.0.1' | awk '{print $2}' | tr -d 'addr:')
    fi
    
    # 3. 如果连 wlan0 都没有，尝试获取能上网的主路由 IP
    if [ -z "$DISPLAY_IP" ]; then
        DISPLAY_IP=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+')
    fi

    # 4. 兜底方案：随便找一个非本地环回的 IP
    if [ -z "$DISPLAY_IP" ]; then
        DISPLAY_IP=$(ifconfig 2>/dev/null | grep -i 'inet' | grep -v '127.0.0.1' | head -n 1 | awk '{print $2}' | tr -d 'addr:')
    fi

    [ -z "$DISPLAY_IP" ] && DISPLAY_IP="未知 (请检查WIFI)"

    # 生成展示信息
    NET_INFO=$(ifconfig wlan0 2>/dev/null | grep -i 'inet' | head -n 1)
    [ -z "$NET_INFO" ] && NET_INFO="当前主IP: $DISPLAY_IP"
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
    echo "提示：直接回车将自动分配 10000-65535 之间的随机端口"
    echo "------------------------------------------------"
    
    read -p "设置 Socks5 端口 [当前: ${PORT_SOCKS:-无}]: " input_socks
    if [ -n "$input_socks" ]; then
        PORT_SOCKS=$input_socks
    elif [ -z "$PORT_SOCKS" ]; then
        PORT_SOCKS=$(shuf -i 10000-65535 -n 1)
    fi

    read -p "设置 Http 端口 [当前: ${PORT_HTTP:-无}]: " input_http
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
    
    # 顺手删掉快捷指令
    if [ -d "/data/data/com.termux/files/usr/bin" ]; then
        rm -f "/data/data/com.termux/files/usr/bin/$SHORTCUT_NAME"
    fi
    echo "已彻底清理核心及配置文件。"
    sleep 2
}

# --- 主菜单 ---
show_menu(){
    # 每次进入菜单自动修复快捷指令
    setup_shortcut

    while true; do
        get_network_status
        clear
        echo "================================================" 
        echo "        Local-Proxy-Hub 局域网代理服务          "
        echo "================================================" 
        echo -e " 📡 \033[36m实时网卡状态 (ifconfig/ip):\033[0m"
        echo -e "    $NET_INFO"
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
            echo " 其他设备连接指南 (请确保设备在同一WIFI或热点下):"
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
                echo -e "💡 \033[32m提示：全局快捷指令已注入！你现在可以直接输入 \033[33mgv\033[32m 并回车来唤出此面板。\033[0m\n"
                exit 0 
                ;;
            *) echo "无效输入，请重新选择"; sleep 1 ;;
        esac
    done
}

# 运行主程序
show_menu
