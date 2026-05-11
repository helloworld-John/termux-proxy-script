#!/bin/bash
# ==========================================
# Termux 局域网共享代理管理脚本 (支持自定义端口)
# ==========================================

# --- 1. 全局变量与配置持久化 ---
GOST_VERSION="2.11.5"
BIN_DIR="$PREFIX/bin"
LOG_FILE="$HOME/gost_proxy.log"
CONFIG_FILE="$HOME/.gost_ports.conf"

# 初始化默认端口
PORT_SOCKS=10800
PORT_HTTP=80800

# 如果存在配置文件，则读取用户自定义端口
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# --- 2. 基础功能函数 ---

get_local_ip() {
    # 优化了 IP 提取正则，避免提取到广播地址
    LOCAL_IP=$(ifconfig wlan0 2>/dev/null | grep -w 'inet' | awk '{print $2}')
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP="127.0.0.1"
    fi
}

install_gost() {
    if [ ! -f "$BIN_DIR/gost" ]; then
        echo -e "\n[*] 未检测到 gost 核心，正在自动下载安装..."
        pkg update -y -q
        pkg install -y wget gzip inetutils -q 
        
        DOWNLOAD_URL="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-armv8-${GOST_VERSION}.gz"
        echo "[*] 正在拉取核心组件，请稍候..."
        wget -O gost.gz "$DOWNLOAD_URL"
        
        if [ -s gost.gz ]; then
            gzip -d gost.gz
            mv gost "$BIN_DIR/gost"
            chmod +x "$BIN_DIR/gost"
            echo "[+] Gost 核心安装完毕！"
        else
            echo "[!] 下载失败！请确保你的网络可以直连 GitHub。"
            rm -f gost.gz
            return 1
        fi
    fi
    return 0
}

start_proxy() {
    install_gost
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    pkill -f "gost -L=socks5" 2>/dev/null
    sleep 1
    
    echo -e "\n[*] 正在启动双协议共享代理..."
    nohup gost -L=socks5://:$PORT_SOCKS -L=http://:$PORT_HTTP > "$LOG_FILE" 2>&1 &
    sleep 1
    echo "[+] 代理已在后台稳定运行！"
    show_config
    return 0
}

stop_proxy() {
    pkill -f "gost -L=socks5" 2>/dev/null
    echo -e "\n[!] 已彻底停止代理进程，释放端口。"
    return 0
}

# --- 新增功能：自定义端口 ---
change_ports() {
    echo -e "\n========================================="
    echo -e "           ⚙️ 修改代理端口"
    echo -e "========================================="
    echo -e "当前 SOCKS5 端口: \033[32m$PORT_SOCKS\033[0m"
    read -p "请输入新的 SOCKS5 端口 (直接回车保持不变): " new_socks
    if [ -n "$new_socks" ] && [[ "$new_socks" =~ ^[0-9]+$ ]]; then
        PORT_SOCKS=$new_socks
    fi

    echo -e "当前 HTTP 端口: \033[32m$PORT_HTTP\033[0m"
    read -p "请输入新的 HTTP 端口 (直接回车保持不变): " new_http
    if [ -n "$new_http" ] && [[ "$new_http" =~ ^[0-9]+$ ]]; then
        PORT_HTTP=$new_http
    fi

    # 保存配置到文件
    echo "PORT_SOCKS=$PORT_SOCKS" > "$CONFIG_FILE"
    echo "PORT_HTTP=$PORT_HTTP" >> "$CONFIG_FILE"
    echo -e "\n[+] 端口配置已保存！"

    # 动态重启服务
    if pgrep -f "gost -L=socks5" > /dev/null; then
        echo "[*] 检测到代理正在运行，正在重启以应用新端口..."
        stop_proxy
        start_proxy
    fi
    return 0
}

show_config() {
    get_local_ip
    echo -e "\n========================================="
    echo -e "           节点配置与导入信息"
    echo -e "========================================="
    if [ "$LOCAL_IP" == "127.0.0.1" ]; then
        echo -e "⚠️ \033[31m警告: 未检测到有效的局域网IP，请确认手机已连入Wi-Fi！\033[0m"
    else
        echo -e "【真实局域网 IP】: \033[32m$LOCAL_IP\033[0m  <-- 请填入 v2rayNG 的地址栏"
    fi
    echo -e "【SOCKS5 端口 】: $PORT_SOCKS"
    echo -e "【HTTP   端口 】: $PORT_HTTP\n"

    echo -e "--- 🔗 通用 URI 链接 (Hiddify 等直接复制导入) ---"
    echo -e "socks5://$LOCAL_IP:$PORT_SOCKS#Termux-Socks5"
    echo -e "http://$LOCAL_IP:$PORT_HTTP#Termux-HTTP\n"

    echo -e "--- 💧 Loon 专属节点代码 (复制粘贴) ---"
    echo -e "Termux-SOCKS5 = SOCKS5, $LOCAL_IP, $PORT_SOCKS"
    echo -e "Termux-HTTP = HTTP, $LOCAL_IP, $PORT_HTTP"
    echo -e "========================================="
    return 0
}

view_logs() {
    if [ -f "$LOG_FILE" ]; then
        echo -e "\n--- 实时运行日志 (按 Ctrl+C 退出) ---"
        tail -f "$LOG_FILE"
    else
        echo -e "\n[!] 暂无日志文件，请先启动服务。"
    fi
    return 0
}

# --- 3. 交互式主菜单路由逻辑 ---
show_menu() {
    local running=1
    while [ $running -eq 1 ]; do
        echo -e "\n========================================="
        echo -e "      Termux 局域网共享代理控制台"
        echo -e "========================================="
        
        if pgrep -f "gost -L=socks5" > /dev/null; then
            echo -e "  当前状态: [\033[32m🟢 运行中\033[0m]"
        else
            echo -e "  当前状态: [\033[31m🔴 已停止\033[0m]"
        fi
        
        echo -e "-----------------------------------------"
        echo -e "  [1] 🚀 启动 / 重启代理"
        echo -e "  [2] ⏹️  停止代理"
        echo -e "  [3] 📋 查看配置与订阅链接"
        echo -e "  [4] 📄 实时查看日志"
        echo -e "  [5] ⚙️  修改代理端口 (自动保存)"
        echo -e "  [0] 🚪 退出菜单"
        echo -e "========================================="
        read -p "请输入选项 [0-5]: " choice

        case $choice in
            1) start_proxy ;;
            2) stop_proxy ;;
            3) show_config ;;
            4) view_logs ;;
            5) change_ports ;;
            0) 
                echo -e "\n已退出控制台界面 (代理进程状态不受影响)。"
                running=0 # 单一出口触发
                ;;
            *) echo -e "\n[!] 输入无效，请输入 0-5 之间的数字。" ;;
        esac
    done
    exit 0 # 唯一的退出点
}

# --- 4. 脚本入口 ---
show_menu
