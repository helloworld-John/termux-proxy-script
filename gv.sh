#!/bin/bash
# ==========================================
# Termux 局域网共享代理管理脚本 (Gost v3 完美融合版)
# ==========================================

# --- 1. 全局变量与配置持久化 ---
GOST_VERSION="3.0.0"
BIN_DIR="$PREFIX/bin"
CONF_FILE="$HOME/gost_config.yaml"
LOG_FILE="$HOME/gost_proxy.log"
USER_PREF_FILE="$HOME/.gost_ports.conf"

PORT_SOCKS=10800
PORT_HTTP=80800
LOCAL_IP_OVERRIDE=""

if [ -f "$USER_PREF_FILE" ]; then
    source "$USER_PREF_FILE"
fi

# --- 2. 核心功能函数 ---

get_local_ip() {
    if [ -n "$LOCAL_IP_OVERRIDE" ]; then
        LOCAL_IP="$LOCAL_IP_OVERRIDE"
        return
    fi
    LOCAL_IP=$(ifconfig wlan0 2>/dev/null | grep -w 'inet' | awk '{print $2}')
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP="127.0.0.1"
    fi
}

install_gost() {
    if [ ! -f "$BIN_DIR/gost" ]; then
        echo -e "\n[*] 未检测到 gost v3 核心，正在下载..."
        pkg update -y -q
        pkg install -y wget tar inetutils -q 
        
        DOWNLOAD_URL="https://gh-proxy.com/https://raw.githubusercontent.com/yonggekkk/google_vpn_proxy/main/gost_3.0.0_linux_arm64.tar.gz"
        wget -qO gost.tar.gz "$DOWNLOAD_URL"
        
        if [ -s gost.tar.gz ]; then
            tar -xzf gost.tar.gz
            # 兼容解压后是否有文件夹
            if [ -f "gost_3.0.0_linux_arm64/gost" ]; then
                mv "gost_3.0.0_linux_arm64/gost" "$BIN_DIR/gost"
            else
                mv gost "$BIN_DIR/gost"
            fi
            chmod +x "$BIN_DIR/gost"
            rm -rf gost.tar.gz README* LICENSE* gost_3.0.0_linux_arm64/
            echo "[+] Gost v3 核心安装完毕！"
        else
            echo "[!] 下载失败，请检查网络！"
            rm -f gost.tar.gz
            return 1
        fi
    fi
    return 0
}

# 动态生成 YAML 配置文件
generate_yaml() {
    get_local_ip
    cat > "$CONF_FILE" <<EOF
services:
  - name: service-socks5
    addr: "${LOCAL_IP}:${PORT_SOCKS}"
    resolver: resolver-0
    handler:
      type: socks5
      metadata:
        udp: true
        udpbuffersize: 4096
    listener:
      type: tcp
  - name: service-http
    addr: "${LOCAL_IP}:${PORT_HTTP}"
    resolver: resolver-0
    handler:
      type: http
      metadata:
        udp: true
        udpbuffersize: 4096
    listener:
      type: tcp
resolvers:
  - name: resolver-0
    nameservers:
      - addr: tls://8.8.8.8:853
        prefer: ipv4
        ttl: 5m0s
        async: true
      - addr: tls://8.8.4.4:853
        prefer: ipv4
        ttl: 5m0s
        async: true
EOF
}

start_proxy() {
    install_gost
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    pkill -f "gost -C" 2>/dev/null
    sleep 1
    
    echo -e "\n[*] 正在生成配置并启动代理..."
    generate_yaml
    
    # 彻底杜绝使用 127.0.0.1 导致局域网失效的问题
    if [ "$LOCAL_IP" == "127.0.0.1" ]; then
        echo -e "\n\033[31m[错误] 当前获取到的 IP 为 127.0.0.1，局域网共享必将失败！\033[0m"
        echo -e "请在主菜单按 [5] 手动绑定您手机在 Wi-Fi 下的真实 IP！"
        return 1
    fi
    
    nohup gost -C "$CONF_FILE" > "$LOG_FILE" 2>&1 &
    sleep 1
    echo "[+] 代理已在后台基于真实 IP 稳定运行！"
    return 0
}

stop_proxy() {
    pkill -f "gost -C" 2>/dev/null
    echo -e "\n[!] 已彻底停止代理进程。"
    return 0
}

change_config() {
    echo -e "\n========================================="
    echo -e "           ⚙️ 修改网络配置"
    echo -e "========================================="
    
    echo -e "当前绑定的局域网 IP: \033[32m${LOCAL_IP_OVERRIDE:-自动获取(如为127.0.0.1请务必手动绑定)}\033[0m"
    read -p "请输入真实 IP (回车保持不变，输入 auto 恢复自动): " new_ip
    if [ "$new_ip" == "auto" ]; then
        LOCAL_IP_OVERRIDE=""
    elif [ -n "$new_ip" ]; then
        LOCAL_IP_OVERRIDE=$new_ip
    fi

    echo -e "\n当前 SOCKS5 端口: \033[32m$PORT_SOCKS\033[0m"
    read -p "请输入新的 SOCKS5 端口 (直接回车保持不变): " new_socks
    if [ -n "$new_socks" ] && [[ "$new_socks" =~ ^[0-9]+$ ]]; then
        PORT_SOCKS=$new_socks
    fi

    echo -e "当前 HTTP 端口: \033[32m$PORT_HTTP\033[0m"
    read -p "请输入新的 HTTP 端口 (直接回车保持不变): " new_http
    if [ -n "$new_http" ] && [[ "$new_http" =~ ^[0-9]+$ ]]; then
        PORT_HTTP=$new_http
    fi

    echo "PORT_SOCKS=$PORT_SOCKS" > "$USER_PREF_FILE"
    echo "PORT_HTTP=$PORT_HTTP" >> "$USER_PREF_FILE"
    echo "LOCAL_IP_OVERRIDE=\"$LOCAL_IP_OVERRIDE\"" >> "$USER_PREF_FILE"
    echo -e "\n[+] 配置已保存！"

    if pgrep -f "gost -C" > /dev/null; then
        echo "[*] 检测到代理运行中，正在重启以应用新配置..."
        stop_proxy
        start_proxy
    fi
    return 0
}

show_config() {
    get_local_ip
    echo -e "\n========================================="
    if [ "$LOCAL_IP" == "127.0.0.1" ]; then
        echo -e "⚠️ \033[31m严重警告: IP 为 127.0.0.1，请按 5 绑定真实 IP\033[0m"
    else
        echo -e "【真实局域网 IP】: \033[32m$LOCAL_IP\033[0m  <-- 请填入 v2rayNG"
    fi
    echo -e "【SOCKS5 端口 】: $PORT_SOCKS"
    echo -e "【HTTP   端口 】: $PORT_HTTP"
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

# --- 3. 交互式主菜单路由 (严格单一出口) ---
show_menu() {
    local running=1
    while [ $running -eq 1 ]; do
        echo -e "\n========================================="
        echo -e "    Termux 代理控制台 (Gost v3 DNS强化版)"
        echo -e "========================================="
        
        if pgrep -f "gost -C" > /dev/null; then
            echo -e "  状态: [\033[32m🟢 运行中\033[0m]"
        else
            echo -e "  状态: [\033[31m🔴 已停止\033[0m]"
        fi
        
        echo -e "-----------------------------------------"
        echo -e "  [1] 🚀 启动 / 重启代理"
        echo -e "  [2] ⏹️  停止代理"
        echo -e "  [3] 📋 查看配置参数"
        echo -e "  [4] 📄 实时查看日志 (排障专用)"
        echo -e "  [5] ⚙️  绑定真实 IP 与端口 (必须配置)"
        echo -e "  [0] 🚪 退出菜单"
        echo -e "========================================="
        read -p "请输入选项 [0-5]: " choice

        case $choice in
            1) start_proxy ;;
            2) stop_proxy ;;
            3) show_config ;;
            4) view_logs ;;
            5) change_config ;;
            0) 
                echo -e "\n已退出控制台 (代理运行状态不受影响)。"
                running=0
                ;;
            *) echo -e "\n[!] 输入无效。" ;;
        esac
    done
    exit 0
}

# --- 4. 脚本入口 ---
show_menu
