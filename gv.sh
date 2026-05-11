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
