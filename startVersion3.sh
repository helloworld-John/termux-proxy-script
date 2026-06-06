#!/usr/bin/env bash
# =========================================================
#  Production-grade LAN Proxy Panel (Powered by gost)
#  Author: Gemini (Expert Bash Scripter)
# =========================================================

# --- 1. 全局配置与环境自适应 ---
# 终端颜色定义
readonly RED='\033[1;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;34m'
readonly CYAN='\033[1;36m'
readonly DIM='\033[2m'
readonly RESET='\033[0m'
readonly BOLD='\033[1m'

# 文件路径定义（统一定位到家目录）
readonly CONFIG_FILE="$HOME/.start_config"
readonly PID_FILE="$HOME/.start_proxy.pid"
readonly LOG_FILE="$HOME/.start_proxy.log"

# 环境适配：兼容 Android Termux 与 标准 Linux
if [ -n "$PREFIX" ]; then
    readonly BIN_DIR="$PREFIX/bin"
else
    # 优先尝试使用 /usr/local/bin，无权限则使用 $HOME/.local/bin
    if [ -w "/usr/local/bin" ]; then
        readonly BIN_DIR="/usr/local/bin"
    else
        readonly BIN_DIR="$HOME/.local/bin"
        mkdir -p "$BIN_DIR" 2>/dev/null
    fi
fi

# --- 2. 自固化与全局入口设计 ---
auto_cure_and_inject() {
    local current_script target_script
    # 智能获取当前脚本的绝对路径
    current_script=$(readlink -f "$0" 2>/dev/null || echo "${BASH_SOURCE[0]}")
    target_script="$HOME/start.sh"

    # 1. 脚本自我迁移
    if [ "$current_script" != "$target_script" ]; then
        cp -f "$current_script" "$target_script" 2>/dev/null
        chmod +x "$target_script" 2>/dev/null
        # 转移后以新路径启动自身并退出旧进程
        exec bash "$target_script" "$@"
    fi

    # 2. 全局入口注入 (快捷命令 start)
    # 尝试写入 bin 目录
    if [ -w "$BIN_DIR" ] && [ ! -f "$BIN_DIR/start" ]; then
        echo -e "#!/usr/bin/env bash\nbash $target_script \"\$@\"" > "$BIN_DIR/start" 2>/dev/null
        chmod +x "$BIN_DIR/start" 2>/dev/null
    fi

    # 尝试写入 shell alias
    for shell_rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$shell_rc" ] && ! grep -q "alias start=" "$shell_rc" 2>/dev/null; then
            echo "alias start='bash ~/start.sh'" >> "$shell_rc" 2>/dev/null
        fi
    done
}

# --- 3. 智能依赖注入 (自动安装 gost) ---
install_gost() {
    if command -v gost >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}检测到缺少核心组件 'gost'，正在触发自动化安装链...${RESET}"
    
    # 尝试包管理器静默安装
    if command -v pkg >/dev/null 2>&1; then
        pkg install -y gost >/dev/null 2>&1 && return 0
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update >/dev/null 2>&1
        sudo apt-get install -y gost >/dev/null 2>&1 && return 0
    fi

    # 包管理器无源，通过官方 GitHub Release 编译部署
    echo -e "${CYAN}包管理器无可用版本，尝试跨平台官方拉取 (v2.11.5)...${RESET}"
    local gost_version="2.11.5"
    local arch sys_os gost_arch url tmp_dir
    
    arch=$(uname -m)
    case "$arch" in
        x86_64)          gost_arch="amd64" ;;
        aarch64|arm64)   gost_arch="armv8" ;;
        armv7l|armv7)    gost_arch="armv7" ;;
        i386|i686)       gost_arch="386" ;;
        *)               echo -e "${RED}致命错误: 不支持的硬件架构 $arch${RESET}"; exit 1 ;;
    esac

    sys_os="linux"
    [[ "$OSTYPE" == "darwin"* ]] && sys_os="darwin"

    url="https://github.com/ginuerzh/gost/releases/download/v${gost_version}/gost-${sys_os}-${gost_arch}-${gost_version}.gz"
    tmp_dir=$(mktemp -d)

    echo -e "${DIM}下载链路: $url${RESET}"
    if curl -L --fail --progress-bar -o "$tmp_dir/gost.gz" "$url"; then
        gzip -d "$tmp_dir/gost.gz" 2>/dev/null
        chmod +x "$tmp_dir/gost" 2>/dev/null
        
        # 尝试提权移动到标准目录
        if [ -w "$BIN_DIR" ]; then
            mv -f "$tmp_dir/gost" "$BIN_DIR/" 2>/dev/null
        else
            sudo mv -f "$tmp_dir/gost" "$BIN_DIR/" 2>/dev/null
        fi
        rm -rf "$tmp_dir"
        echo -e "${GREEN}组件依赖 'gost' 极速安装完毕！${RESET}"
        sleep 1
    else
        echo -e "${RED}安装失败，请检查网络连接或手动安装 gost。${RESET}"
        rm -rf "$tmp_dir"
        exit 1
    fi
}

# --- 4. 网络与端口碰撞检测 ---
get_lan_ips() {
    local ips
    # 通过标准 ip 或 ifconfig 命令提取，并用 grep 排除广播和回环地址
    if command -v ip >/dev/null 2>&1; then
        ips=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '\.255$')
    else
        ips=$(ifconfig 2>/dev/null | grep -w inet | awk '{print $2}' | sed 's/addr://' | grep -v '127.0.0.1' | grep -v '\.255$')
    fi
    # 格式化输出为逗号分隔
    echo "$ips" | tr '\n' ' ' | sed 's/ $//' | sed 's/ /, /g'
}

check_port() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -q ":$port "
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | grep -q ":$port "
    else
        # 兜底检测方案
        (lsof -i ":$port" >/dev/null 2>&1)
    fi
}

get_random_port() {
    local port
    while true; do
        port=$(shuf -i 10000-60000 -n 1)
        if ! check_port "$port"; then
            echo "$port"
            return
        fi
    done
}

# --- 5. 进程守护与日志管理 ---
get_pid() {
    if [ -f "$PID_FILE" ]; then
        cat "$PID_FILE" 2>/dev/null
    fi
}

is_running() {
    local pid
    pid=$(get_pid)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

stop_proxy() {
    if is_running; then
        local pid
        pid=$(get_pid)
        kill "$pid" 2>/dev/null
        sleep 0.5
        kill -9 "$pid" 2>/dev/null # 补刀
    fi
    rm -f "$PID_FILE" 2>/dev/null
}

start_proxy() {
    install_gost

    # 读取配置
    local socks_p http_p
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    socks_p=${SOCKS_PORT:-}
    http_p=${HTTP_PORT:-}

    # 初次启动要求配置端口
    if [ -z "$socks_p" ] || [ -z "$http_p" ]; then
        echo -e "${CYAN}首次启动配置 (直接回车将自动分配 10000-60000 安全端口)${RESET}"
        
        # Socks5
        read -r -p "设置 SOCKS5 代理端口: " input_socks
        if [ -z "$input_socks" ]; then
            socks_p=$(get_random_port)
            echo -e "${DIM}└─ 分配随机端口: $socks_p${RESET}"
        else
            while check_port "$input_socks"; do
                echo -e "${RED}端口 $input_socks 被占用，请重新输入!${RESET}"
                read -r -p "设置 SOCKS5 代理端口: " input_socks
            done
            socks_p=$input_socks
        fi

        # HTTP
        read -r -p "设置 HTTP 代理端口: " input_http
        if [ -z "$input_http" ]; then
            http_p=$(get_random_port)
            echo -e "${DIM}└─ 分配随机端口: $http_p${RESET}"
        else
            while check_port "$input_http" || [ "$input_http" == "$socks_p" ]; do
                echo -e "${RED}端口冲突或被占用，请重新输入!${RESET}"
                read -r -p "设置 HTTP 代理端口: " input_http
            done
            http_p=$input_http
        fi

        # 写入配置
        echo "SOCKS_PORT=$socks_p" > "$CONFIG_FILE"
        echo "HTTP_PORT=$http_p" >> "$CONFIG_FILE"
    fi

    stop_proxy # 确保旧进程已停
    
    # 核心推入后台并静默挂载
    nohup gost -L="socks5://:$socks_p" -L="http://:$http_p" > "$LOG_FILE" 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$PID_FILE"

    sleep 1 # 等待进程稳定
    if is_running; then
        echo -e "${GREEN}代理已成功启动! PID: $new_pid${RESET}"
        sleep 1
    else
        echo -e "${RED}代理启动失败，请查看日志分析原因。${RESET}"
        sleep 2
    fi
}

# --- 6. ASCII UI 面板与交互循环 ---
show_ui() {
    clear
    local status_text pid_text socks_text http_text lan_ips
    lan_ips=$(get_lan_ips)
    [ -z "$lan_ips" ] && lan_ips="未检测到有效内网IP"

    if is_running; then
        status_text="${GREEN}运行中${RESET}"
        pid_text="${DIM}$(get_pid)${RESET}"
        source "$CONFIG_FILE" 2>/dev/null
        socks_text="${BLUE}${SOCKS_PORT}${RESET}"
        http_text="${BLUE}${HTTP_PORT}${RESET}"
    else
        status_text="${RED}已停止${RESET}"
        pid_text="${DIM}N/A${RESET}"
        socks_text="${DIM}N/A${RESET}"
        http_text="${DIM}N/A${RESET}"
    fi

    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║${RESET} ${BOLD}               局域网代理控制面板 (Powered by gost)         ${RESET}${CYAN}║${RESET}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
    printf "${CYAN}║${RESET} 状态: [%b] | PID: %-37b ${CYAN}║${RESET}\n" "$status_text" "$pid_text"
    printf "${CYAN}║${RESET} SOCKS5 端口: %-46b ${CYAN}║${RESET}\n" "$socks_text"
    printf "${CYAN}║${RESET} HTTP 端口:   %-46b ${CYAN}║${RESET}\n" "$http_text"
    printf "${CYAN}║${RESET} 可用内网 IP: %-46b ${CYAN}║${RESET}\n" "${YELLOW}${lan_ips}${RESET}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
    echo -e "${CYAN}║${RESET} [1] 启动 / 重启代理                                          ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET} [2] 停止并卸载代理                                           ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET} [3] 查看当前配置明细                                         ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET} [4] 实时查看日志 (Ctrl+C 退出查看)                           ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET} [5] 重新设置端口                                             ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET} [0] 退出面板                                                 ${CYAN}║${RESET}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
}

interactive_loop() {
    while true; do
        show_ui
        read -r -p "请选择操作 [0-5]: " choice
        case "$choice" in
            1)
                start_proxy
                ;;
            2)
                stop_proxy
                rm -f "$CONFIG_FILE" "$LOG_FILE" 2>/dev/null
                echo -e "${GREEN}代理已停止，配置及日志已清除。${RESET}"
                sleep 1.5
                ;;
            3)
                if [ -f "$CONFIG_FILE" ]; then
                    echo -e "\n${BOLD}当前配置详情：${RESET}"
                    cat "$CONFIG_FILE"
                else
                    echo -e "\n${YELLOW}未发现有效配置。${RESET}"
                fi
                read -r -n 1 -s -p "$(echo -e ${DIM}按任意键返回...${RESET})"
                ;;
            4)
                if [ -f "$LOG_FILE" ]; then
                    echo -e "\n${YELLOW}正在进入实时日志查看 (按 Ctrl+C 返回菜单)...${RESET}\n"
                    # 使用 trap 捕获此处的 Ctrl+C 以防止整个脚本退出
                    trap 'trap - INT; return 2>/dev/null || true' INT
                    tail -f "$LOG_FILE"
                    trap - INT
                else
                    echo -e "\n${YELLOW}当前无日志文件。${RESET}"
                    read -r -n 1 -s -p "$(echo -e ${DIM}按任意键返回...${RESET})"
                fi
                ;;
            5)
                rm -f "$CONFIG_FILE" 2>/dev/null
                echo -e "\n${GREEN}已重置配置，稍后重启将引导重新生成端口。${RESET}"
                sleep 1.5
                start_proxy
                ;;
            0)
                echo -e "\n${GREEN}面板已退出。${RESET}"
                if is_running; then
                    echo -e "${DIM}提示: 代理在后台静默运行中。在任何目录下输入 ${BOLD}'start'${RESET}${DIM} 即可随时唤出面板。${RESET}\n"
                fi
                exit 0
                ;;
            *)
                ;;
        esac
    done
}

# --- 7. 主程序入口 ---
auto_cure_and_inject
interactive_loop
