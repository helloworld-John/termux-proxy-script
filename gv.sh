#!/bin/bash
# ==========================================
# Local-Proxy-Hub 局域网共享代理 (Gost v3 通用版)
# 特性：全网卡被动监听 (0.0.0.0)，随机可用端口，自动架构检测，全局快捷指令
# ==========================================

# --- 全局路径与变量 ---
BIN_FILE="$HOME/gost"
CONF_FILE="$HOME/config.json"
LOG_FILE="$HOME/gost_proxy.log"
PREF_FILE="$HOME/.proxy_pref.conf"
SHORTCUT_NAME="gv"

# 加载本地保存的配置
[ -f "$PREF_FILE" ] && source "$PREF_FILE"

# --- 自动设置全局快捷指令 ---
setup_shortcut() {
    # 获取当前脚本的绝对路径
    SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)
    SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
    
    # 检测运行环境以确定可执行目录
    if [ -n "$PREFIX" ] && [ -d "$PREFIX/bin" ]; then
        BIN_DIR="$PREFIX/bin" # Termux 环境
    elif [ -w "/usr/local/bin" ]; then
        BIN_DIR="/usr/local/bin" # 拥有 root 权限的 Linux
    elif [ -d "$HOME/.local/bin" ]; then
        BIN_DIR="$HOME/.local/bin" # 普通用户 Linux
        export PATH="$HOME/.local/bin:$PATH"
    else
        BIN_DIR=""
    fi

    # 创建快捷指令
    if [ -n "$BIN_DIR" ]; then
        if [ ! -f "$BIN_DIR/$SHORTCUT_NAME" ] || [ "$(cat "$BIN_DIR/$SHORTCUT_NAME")" != "#!/bin/bash"$'\n'"bash \"$SCRIPT_PATH\"" ]; then
            echo "#!/bin/bash" > "$BIN_DIR/$SHORTCUT_NAME"
            echo "bash \"$SCRIPT_PATH\"" >> "$BIN_DIR/$SHORTCUT_NAME"
            chmod +x "$BIN_DIR/$SHORTCUT_NAME"
        fi
    else
        # 降级方案：写入 alias
        if ! grep -q "alias $SHORTCUT_NAME=" "$HOME/.bashrc" 2>/dev/null; then
            echo "alias $SHORTCUT_NAME='bash \"$SCRIPT_PATH\"'" >> "$HOME/.bashrc"
            source "$HOME/.bashrc" 2>/dev/null
        fi
    fi
}

# --- 实时获取并显示网卡 IP ---
get_network_status() {
    # 尝试提取 wlan0 (WIFI) 的 IP 信息
    NET_INFO=$(ifconfig wlan0 2>/dev/null | grep -w 'inet')
    DISPLAY_IP=$(echo "$NET_INFO" | awk '{print $2}')
    
    # 如果没有 wlan0，尝试获取系统默认主网卡 IP
    if [ -z "$DISPLAY_IP" ]; then
        NET_INFO=$(ip -4 addr show 2>/dev/null | grep -w 'inet' | grep -v '127.0.0.1' | head -n 1)
        DISPLAY_IP=$(echo "$NET_INFO" | awk '{print $2}' | cut -d/ -f1)
    fi

    [ -z "$DISPLAY_IP" ] && DISPLAY_IP="未知 (请检查 WIFI 或热点是否开启)"
    [ -z "$NET_INFO" ] && NET_INFO="无活动网卡信息"
}

# --- 核心下载与安装 ---
install_core(){
    # 自动检测架构
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
        # 使用通用加速代理
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
    # 安装必要依赖
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

    # 保存配置
    echo "PORT_SOCKS=$PORT_SOCKS" > "$PREF_FILE"
    echo "PORT_HTTP=$PORT_HTTP" >> "$PREF_FILE"

    # 生成 JSON 配置（采用 0.0.0.0 全网卡监听方案）
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

    # 重启服务
    pkill -f "gost -C" 2>/dev/null
    nohup "$BIN_FILE" -C "$CONF_FILE" > "$LOG_FILE" 2>&1 &
    
    echo "配置更新并尝试启动完毕！"
    sleep 2
}

# --- 彻底卸载 ---
uninstall(){
    pkill -f "gost -C" 2>/dev/null
    rm -f "$BIN_FILE" "$CONF_FILE" "$LOG_FILE" "$PREF_FILE"
    echo "已彻底清理核心及配置文件。"
    sleep 2
}

# --- 主菜单 ---
show_menu(){
    # 启动前静默配置快捷指令
    setup_shortcut

    while true; do
        get_network_status
        clear
        echo "================================================" 
        echo "        Local-Proxy-Hub 局域网代理服务          "
        echo "================================================" 
        echo -e " 📡 \033[36m实时网卡状态:\033[0m"
        echo -e "    $NET_INFO"
        echo "------------------------------------------------"
        echo " 1. 安装/配置/重启代理"
        echo " 2. 卸载代理"
        echo " 3. 查看当前配置文件"
        echo " 4. 实时查看运行日志 (Ctrl+C 退出日志)"
        echo " 0. 退出面板"
        echo "------------------------------------------------"
        
        if pgrep -f "gost -C" > /dev/null; then
            echo -e " 状态: \033[32m🟢 运行中\033[0m (全网卡被动监听模式)"
            echo "------------------------------------------------"
            echo " 其他设备连接指南 (请确保设备在同一局域网):"
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
                echo -e "💡 \033[32m提示：你已经可以直接输入 \033[33mgv\033[32m 命令随时唤出此面板，无需输入繁琐路径！\033[0m\n"
                exit 0 
                ;;
            *) echo "无效输入，请重新选择"; sleep 1 ;;
        esac
    done
}

# 运行主程序
show_menu
