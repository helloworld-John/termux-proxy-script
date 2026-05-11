#!/bin/bash
# ==========================================
# Termux 局域网共享代理管理脚本 (Gost版) - 已修复下载Bug
# ==========================================

# --- 1. 全局变量配置 ---
GOST_VERSION="2.11.5"
BIN_DIR="$PREFIX/bin"
LOG_FILE="$HOME/gost_proxy.log"
PORT_SOCKS=10800
PORT_HTTP=80800

# --- 2. 基础功能函数 ---

# 获取局域网IP
get_local_ip() {
    LOCAL_IP=$(ifconfig wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}')
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP="127.0.0.1"
    fi
}

# 检查并安装 Gost 环境 (Bug已修复)
install_gost() {
    if [ ! -f "$BIN_DIR/gost" ]; then
        echo -e "\n[*] 未检测到 gost 核心，正在自动下载安装..."
        pkg update -y -q
        # 注意这里新增了 gzip 工具
        pkg install -y wget gzip inetutils -q 
        
        # 修正了官方的命名格式与后缀 (.gz) 以及更稳定的镜像源
        DOWNLOAD_URL="https://mirror.ghproxy.com/https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-armv8-${GOST_VERSION}.gz"
        
        echo "[*] 正在拉取核心组件，请稍候..."
        wget -qO gost.gz "$DOWNLOAD_URL"
        
        # 增加文件校验，防止静默失败
        if [ -s gost.gz ]; then
            gzip -d gost.gz
            mv gost "$BIN_DIR/gost"
            chmod +x "$BIN_DIR/gost"
            echo "[+] Gost 核心安装完毕！"
        else
            echo "[!] 下载失败，请检查网络。"
            rm -f gost.gz
            return 1
        fi
    fi
}

# 启动代理服务
start_proxy() {
    install_gost
    # 如果安装失败则中断启动
    if [ $? -ne 0 ]; then
        return
    fi
    
    # 清理可能残留的旧进程
    pkill -f "gost -L=socks5" 2>/dev/null
    sleep 1
    
    echo -e "\n[*] 正在启动双协议共享代理..."
    # 后台运行并记录日志
    nohup gost -L=socks5://:$PORT_SOCKS -L=http://:$PORT_HTTP > "$LOG_FILE" 2>&1 &
    sleep 1
    echo "[+] 代理已在后台稳定运行！"
    show_config
}

# 停止代理服务
stop_proxy() {
    pkill -f "gost -L=socks5" 2>/dev/null
    echo -e "\n[!] 已彻底停止代理进程，释放端口。"
}

# 显示节点配置与导入信息
show_config() {
    get_local_ip
    echo -e "\n========================================="
    echo -e "           节点配置与导入信息"
    echo -e "========================================="
    echo -e "【当前局域网 IP】: $LOCAL_IP"
    echo -e "【SOCKS5 端口 】: $PORT_SOCKS"
    echo -e "【HTTP   端口 】: $PORT_HTTP\n"

    echo -e "--- 🔗 通用 URI 链接 (Hiddify 等直接复制导入) ---"
    echo -e "socks5://$LOCAL_IP:$PORT_SOCKS#Termux-Socks5"
    echo -e "http://$LOCAL_IP:$PORT_HTTP#Termux-HTTP\n"

    echo -e "--- 💧 Loon 专属节点代码 (复制粘贴至配置文件) ---"
    echo -e "[Proxy]"
    echo -e "Termux-SOCKS5 = SOCKS5, $LOCAL_IP, $PORT_SOCKS"
    echo -e "Termux-HTTP = HTTP, $LOCAL_IP, $PORT_HTTP"
    echo -e "========================================="
}

# 查看运行日志
view_logs() {
    if [ -f "$LOG_FILE" ]; then
        echo -e "\n--- 实时运行日志 (按 Ctrl+C 退出) ---"
        tail -f "$LOG_FILE"
    else
        echo -e "\n[!] 暂无日志文件，请先启动服务。"
    fi
}

# --- 3. 交互式主菜单逻辑 ---
show_menu() {
    while true; do
        echo -e "\n========================================="
        echo -e "      Termux 局域网共享代理控制台"
        echo -e "========================================="
        
        # 动态检查代理是否在运行
        if pgrep -f "gost -L=socks5" > /dev/null; then
            echo -e "  当前状态: [🟢 运行中]"
        else
            echo -e "  当前状态: [🔴 已停止]"
        fi
        
        echo -e "-----------------------------------------"
        echo -e "  [1] 🚀 启动 / 重启代理"
        echo -e "  [2] ⏹️  停止代理"
        echo -e "  [3] 📋 查看配置与订阅链接"
        echo -e "  [4] 📄 实时查看日志"
        echo -e "  [0] 🚪 退出菜单"
        echo -e "========================================="
        read -p "请输入选项 [0-4]: " choice

        case $choice in
            1) start_proxy ;;
            2) stop_proxy ;;
            3) show_config ;;
            4) view_logs ;;
            0) 
                echo -e "\n已退出控制台界面。"
                echo "提示: 代理进程仍会在后台运行 (除非您刚才选择了 2 停止它)。"
                echo -e "随时输入 bash gv.sh 再次唤出本菜单。\n"
                exit 0 
                ;;
            *) echo -e "\n[!] 输入无效，请输入 0-4 之间的数字。" ;;
        esac
    done
}

# --- 4. 脚本入口 ---
show_menu
