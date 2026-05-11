#!/bin/bash

# ================= 环境变量与全局配置 =================
GOST_DIR="$HOME/google_vpn_proxy"
CONFIG_FILE="$GOST_DIR/config.yaml"
GOST_BIN="$GOST_DIR/gost"
SUB_DIR="$GOST_DIR/sub_server"
SUB_PORT=8080  # 订阅分发端口
LOG_FILE="$GOST_DIR/gost.log"

# 颜色输出宏
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ================= 核心依赖与安装 =================
check_dependencies() {
    local pkgs="screen coreutils curl"
    for pkg in $pkgs; do
        if ! command -v $pkg &> /dev/null; then
            echo -e "${YELLOW}检测到缺少基础工具: $pkg，正在安装...${NC}"
            pkg install -y $pkg
        fi
    done

    mkdir -p "$GOST_DIR"
    mkdir -p "$SUB_DIR" 
    cd "$GOST_DIR" || exit

    if [ ! -f "$GOST_BIN" ]; then
        echo -e "${YELLOW}正在下载 Gost 核心...${NC}"
        curl -L -o gost.tar.gz -# --retry 2 --insecure https://gh-proxy.com/https://raw.githubusercontent.com/yonggekkk/google_vpn_proxy/main/gost_3.0.0_linux_arm64.tar.gz
        if [ $? -ne 0 ]; then
             echo -e "${RED}下载失败，请确保您已有网络权限。${NC}"
             exit 1
        fi
        tar zxvf gost.tar.gz
        rm -f gost.tar.gz README* LICENSE*
        chmod +x gost
    fi
}

# ================= 辅助函数 =================
# 端口验证交互 (范围: 10000-65535)
get_valid_port() {
    local prompt_text="$1"
    local default_port="$2"
    local input_port
    
    while true; do
        echo -ne "${BLUE}$prompt_text [默认: $default_port, 回车跳过]: ${NC}"
        read input_port
        
        if [ -z "$input_port" ]; then
            if [ -z "$default_port" ]; then
                echo $(shuf -i 10000-65535 -n 1)
            else
                echo "$default_port"
            fi
            return
        fi
        
        if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 10000 ] && [ "$input_port" -le 65535 ]; then
            echo "$input_port"
            return
        else
            echo -e "${RED}[错误] 端口必须是 10000 到 65535 之间的纯数字，请重新输入！${NC}" >&2
        fi
    done
}

# ================= 核心功能：生成配置与订阅 =================
generate_config() {
    local socks_port=$(get_valid_port "请设置 Socks5 端口" "")
    local http_port=$(get_valid_port "请设置 HTTP 端口" "")
    
    echo -e "${GREEN}正在生成 Gost 配置...${NC}"
    
    cat <<EOF > "$CONFIG_FILE"
services:
  - name: service-socks5
    addr: ":$socks_port"
    resolver: resolver-0
    handler:
      type: socks5
      metadata:
        udp: true
        udpbuffersize: 4096
    listener:
      type: tcp
  - name: service-http
    addr: ":$http_port"
    resolver: resolver-0
    handler:
      type: http
      metadata:
        udp: true
        udpbuffersize: 4096
    listener:
      type: tcp
  - name: service-sub
    addr: ":$SUB_PORT"
    handler:
      type: file
      metadata:
        dir: "$SUB_DIR"
    listener:
      type: tcp
resolvers:
  - name: resolver-0
    nameservers:
      - addr: tls://8.8.8.8:853
        prefer: ipv4
        async: true
      - addr: tls://8.8.4.4:853
        prefer: ipv4
        async: true
EOF
    
    echo -e "${GREEN}配置生成完毕！Socks5: $socks_port | HTTP: $http_port${NC}"
}

update_subscription() {
    mkdir -p "$SUB_DIR"
    
    # 完全采用原版提取端口的方法
    local s_port=$(cat "$CONFIG_FILE" 2>/dev/null | grep 'service-socks5' -A 2 | grep 'addr' | awk -F':' '{print $3}' | tr -d '"')
    local h_port=$(cat "$CONFIG_FILE" 2>/dev/null | grep 'service-http' -A 2 | grep 'addr' | awk -F':' '{print $3}' | tr -d '"')
    
    # 既然无法自动获取IP，订阅文件内写入 127.0.0.1，防止客户端解析报错
    cat <<EOF | base64 > "$SUB_DIR/sub.txt"
socks5://127.0.0.1:$s_port#LAN-Socks5
http://127.0.0.1:$h_port#LAN-HTTP
EOF
}

# ================= 代理控制台操作 =================
start_proxy() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}未检测到配置文件，请先进行配置。${NC}"
        generate_config
    fi
    
    update_subscription
    stop_proxy > /dev/null 2>&1
    
    echo -e "${YELLOW}正在启动核心服务...${NC}"
    cd "$GOST_DIR" || exit
    
    screen -dmS gost_proxy bash -c "./gost -C $CONFIG_FILE > $LOG_FILE 2>&1"
    
    echo -e "${GREEN}✓ 启动成功！${NC}"
    sleep 1
}

stop_proxy() {
    screen -S gost_proxy -X quit 2>/dev/null
    echo -e "${GREEN}✓ 服务已停止。${NC}"
    sleep 1
}

show_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
         echo -e "${RED}尚未配置代理服务！${NC}"
         read -n 1 -s -r -p "按任意键返回..."
         return
    fi
    
    # 完全采用原版提取端口的方法
    local s_port=$(cat "$CONFIG_FILE" 2>/dev/null | grep 'service-socks5' -A 2 | grep 'addr' | awk -F':' '{print $3}' | tr -d '"')
    local h_port=$(cat "$CONFIG_FILE" 2>/dev/null | grep 'service-http' -A 2 | grep 'addr' | awk -F':' '{print $3}' | tr -d '"')
    
    clear
    echo "================ 局域网代理信息 ================"
    echo -e "Socks5 端口 : ${GREEN}$s_port${NC}"
    echo -e "HTTP 端口   : ${GREEN}$h_port${NC}"
    echo -e "设备内网 IP : ${RED}需前往手机 WLAN 设置中手动查看${NC}"
    echo "================================================"
    
    echo -e "\n${YELLOW}[方案A] Hiddify / V2ray 一键订阅分发${NC}"
    echo "请将下方链接中的【手机IP】替换为您查到的真实 IP："
    echo -e "${BLUE}http://【手机IP】:$SUB_PORT/sub.txt${NC}"
    echo "注意：由于无法自动获取真实IP，导入节点后，需在客户端内将节点的 127.0.0.1 手动修改为真实IP。"
    
    echo -e "\n${YELLOW}[方案B] Loon / Surge 配置语法 (手动填空)${NC}"
    echo "请将下方配置复制进 Loon，并将【手机IP】替换为真实 IP："
    echo "[Proxy]"
    echo "LAN_Socks5 = socks5, 【手机IP】, $s_port, fast-open=false, udp=true"
    echo "LAN_HTTP = http, 【手机IP】, $h_port, fast-open=false, udp=true"
    echo "================================================"
    echo
    read -n 1 -s -r -p "按任意键返回菜单..."
}

show_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${RED}暂无日志文件。${NC}"
    else
        echo -e "${GREEN}正在实时追踪日志 (按 Ctrl+C 退出)...${NC}"
        tail -f "$LOG_FILE"
    fi
    read -n 1 -s -r -p "按任意键返回..."
}

# ================= TUI 交互式菜单 =================
main_menu() {
    check_dependencies
    
    while true; do
        clear
        echo -e "${BLUE}==============================================${NC}"
        echo -e " ${GREEN}局域网 VPN 共享控制台 - (原版提取逻辑)${NC}"
        echo -e "${BLUE}==============================================${NC}"
        
        if screen -list | grep -q "gost_proxy"; then
            echo -e " 当前状态: ${GREEN}▶ 运行中${NC}"
        else
            echo -e " 当前状态: ${RED}■ 已停止${NC}"
        fi
        echo -e "${BLUE}----------------------------------------------${NC}"
        
        echo " [1] 启动/重启共享代理"
        echo " [2] 停止共享代理"
        echo " [3] 查看客户端配置 (需自行填入内网 IP)"
        echo " [4] 重新配置端口号"
        echo " [5] 实时查看运行日志"
        echo " [0] 退出脚本"
        echo -e "${BLUE}----------------------------------------------${NC}"
        
        read -p "请输入对应的数字选项: " choice
        
        case $choice in
            1) start_proxy ;;
            2) stop_proxy ;;
            3) show_info ;;
            4) generate_config; start_proxy ;;
            5) show_logs ;;
            0) echo "已退出。"; exit 0 ;;
            *) echo -e "${RED}无效输入，请输入正确的数字！${NC}"; sleep 1 ;;
        esac
    done
}

# 启动主函数
main_menu
