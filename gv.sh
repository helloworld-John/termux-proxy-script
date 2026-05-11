#!/bin/bash
# ==========================================
# Local-Proxy-Hub 局域网共享代理 (Gost v3 通用版)
# 特性：全网卡监听 (0.0.0.0)，支持随机可用端口，自动架构检测
# ==========================================

# --- 全局路径与变量 ---
BIN_FILE="$HOME/gost"
CONF_FILE="$HOME/config.json"
LOG_FILE="$HOME/gost_proxy.log"
PREF_FILE="$HOME/.proxy_pref.conf"

# 加载本地保存的配置
[ -f "$PREF_FILE" ] && source "$PREF_FILE"

# 获取本机局域网 IP (仅用于展示，不用于绑定)
get_display_ip() {
    DISPLAY_IP=$(ifconfig wlan0 2>/dev/null | grep -w 'inet' | awk '{print $2}')
    if [ -z "$DISPLAY_IP" ]; then
        # 备选：尝试获取非 127.0.0.1 的第一个有效 IP
        DISPLAY_IP=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    fi
    [ -z "$DISPLAY_IP" ] && DISPLAY_IP="未知(请手动检查WLAN设置)"
}

install_core(){
    # 自动检测架构
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) GOST_ARCH="arm64" ;;
        x86_64|amd64) GOST_ARCH="amd64" ;;
        *) echo "暂不支持的架构: $ARCH"; exit 1 ;;
    esac

    # 官方版本号定义
    GOST_VER="3.0.0"
    DOWNLOAD_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VER}/gost_${GOST_VER}_linux_${GOST_ARCH}.tar.gz"

    if [ ! -e "$BIN_FILE" ]; then
        echo "正在下载 Gost 核心 ($GOST_ARCH)..."
        # 使用通用代理进行加速下载
        curl -L -o gost.tar.gz -# --retry 2 --insecure "https://ghproxy.com/${DOWNLOAD_URL}"
        tar zxvf gost.tar.gz
        
        # 解压提取核心文件
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

setup_proxy(){
    pkg install -y screen wget net-tools iproute2 2>/dev/null || apt install -y screen wget net-tools iproute2 2>/dev/null
    
    install_core

    echo "------------------------------------------------"
    echo "提示：直接回车将自动生成 10000-65535 之间的随机端口"
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

    # 保存偏好
    echo "PORT_SOCKS=$PORT_SOCKS" > "$PREF_FILE"
    echo "PORT_HTTP=$PORT_HTTP" >> "$PREF_FILE"

    # 生成 JSON 配置 (使用通配监听逻辑)
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

    # 清理并启动
    pkill -f "gost -C" 2>/dev/null
    nohup "$BIN_FILE" -C "$CONF_FILE" > "$LOG_FILE" 2>&1 &
    
    echo "配置更新并尝试启动完毕！"
    sleep 2
}

uninstall(){
    pkill -f "gost -C" 2>/dev/null
    rm -f "$BIN_FILE" "$CONF_FILE" "$LOG_FILE" "$PREF_FILE"
    echo "已彻底清理核心及配置文件。"
    sleep 2
}

show_menu(){
    while true; do
        get_display_ip
        clear
        echo "================================================" 
        echo "        Local-Proxy-Hub 局域网代理服务          "
        echo "================================================" 
        echo " 1. 安装/配置/重启代理"
        echo " 2. 卸载代理"
        echo " 3. 查看当前配置文件"
        echo " 4. 实时查看运行日志 (Ctrl+C 退出日志)"
        echo " 0. 退出脚本"
        echo "------------------------------------------------"
        
        if pgrep -f "gost -C" > /dev/null; then
            echo -e " 状态: \033[32m🟢 运行中\033[0m (全网卡被动监听模式)"
            echo "------------------------------------------------"
            echo " 局域网其他设备连接指南："
            echo " - 目标 IP : $DISPLAY_IP"
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
            3) [ -f "$CONF_FILE" ] && cat "$CONF_FILE" || echo "未找到配置文件！"; sleep 4 ;;
            4) [ -f "$LOG_FILE" ] && tail -f "$LOG_FILE" || echo "暂无日志！"; sleep 2 ;;
            0) echo "已退出。"; exit 0 ;;
            *) echo "无效输入，请重新选择"; sleep 1 ;;
        esac
    done
}

show_menu
