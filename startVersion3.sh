#!/usr/bin/env bash
# =========================================================
# Termux 局域网共享代理管理面板 (基于 gost)
# =========================================================

# ---------------------------------------------------------
# 1. 基础配置与全局变量
# ---------------------------------------------------------
# ANSI 终端颜色
readonly RED='\033[1;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;34m'
readonly DIM='\033[2m'
readonly NC='\033[0m' # No Color

# 文件路径预设
readonly CONFIG_FILE="$HOME/.start_config"
readonly PID_FILE="$HOME/.start_proxy.pid"
readonly LOG_FILE="$HOME/.start_proxy.log"

# Termux 前缀环境变量适配
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# ---------------------------------------------------------
# 2. 环境自固化与快捷全局入口
# ---------------------------------------------------------
auto_install_env() {
    local current_script
    # 智能获取当前绝对路径
    current_script=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$PWD/$0")
    local target_script="$HOME/start.sh"

    # 如果当前脚本不在目标位置，自动复制自身
    if [[ "$current_script" != "$target_script" ]]; then
        cp -f "$current_script" "$target_script" 2>/dev/null
        chmod +x "$target_script" 2>/dev/null
    fi

    # 注入全局快捷命令 start
    local bin_start="$PREFIX/bin/start"
    if [[ ! -f "$bin_start" ]]; then
        mkdir -p "$PREFIX/bin" 2>/dev/null
        echo -e "#!/usr/bin/env bash\nbash $target_script" > "$bin_start"
        chmod +x "$bin_start" 2>/dev/null
    fi

    # 注入 ~/.bashrc 和 ~/.zshrc 别名
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rc" ]] && ! grep -q "alias start=" "$rc" 2>/dev/null; then
            echo "alias start='bash $target_script'" >> "$rc"
        fi
    done
}

# ---------------------------------------------------------
# 3. 智能依赖注入 (gost 安装)
# ---------------------------------------------------------
check_and_install_gost() {
    if command -v gost &>/dev/null; then
        return 0
    fi

    echo -e "${YELLOW}[!] 检测到未安装 gost，正在启动自动安装链...${NC}"
    
    # 尝试包管理器静默安装
    if pkg install gost -y >/dev/null 2>&1; then
        echo -e "${GREEN}[✔] 通过 Termux 包管理器安装 gost 成功！${NC}"
        return 0
    fi

    # 包管理器失败则启用动态硬件架构识别与源码部署
    echo -e "${DIM}[*] 包管理器安装失败，尝试从 GitHub 官方 Release 部署...${NC}"
    local arch
    local gost_arch
    arch=$(uname -m)
    
    case "$arch" in
        aarch64) gost_arch="armv8" ;;
        armv7*|armv8l|aarch32) gost_arch="armv7" ;;
        x86_64) gost_arch="amd64" ;;
        i*86) gost_arch="386" ;;
        *) gost_arch="armv8" ;;
    esac

    local version="2.11.5"
    local url="https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-${gost_arch}-${version}.gz"
    local tmp_gz="$HOME/gost.tmp.gz"

    # 确保有 curl 和 gzip
    command -v curl >/dev/null || pkg install curl -y >/dev/null 2>&1
    command -v gzip >/dev/null || pkg install gzip -y >/dev/null 2>&1

    echo -e "${DIM}[*] 正在下载 gost (架构: ${gost_arch})...${NC}"
    if curl -sL "$url" -o "$tmp_gz"; then
        gzip -d "$tmp_gz" 2>/dev/null
        mv -f "$HOME/gost.tmp" "$PREFIX/bin/gost" 2>/dev/null
        chmod +x "$PREFIX/bin/gost" 2>/dev/null
        echo -e "${GREEN}[✔] 二进制编译版 gost 部署成功！${NC}"
    else
        echo -e "${RED}[✘] 严重错误：gost 安装失败，请检查网络环境（可能需要挂载临时前置代理）。${NC}"
        read -n 1 -r -p "按任意键返回..."
        return 1
    fi
}

# ---------------------------------------------------------
# 4. 核心网络逻辑：有效内网 IP 提取与端口检测
# ---------------------------------------------------------
get_lan_ip() {
    # 依赖 ifconfig, awk 提取 inet 后面的 IP。
    # 严格排除 127 开头的回环，严格排除以 .255 结尾的广播
    local ips
    ips=$(ifconfig 2>/dev/null | grep 'inet ' | awk '{print $2}' | sed 's/addr://g' | grep -v '^127\.' | grep -v '\.255$')
    
    if [[ -z "$ips" ]]; then
        echo "未检测到有效局域网IP"
    else
        # 考虑到可能有多网卡（如蜂窝+Wi-Fi或VPN虚拟网卡），横向排版输出
        echo "$ips" | tr '\n' ' ' | sed 's/ $//'
    fi
}

is_port_in_use() {
    local port=$1
    # 兼容 netstat 和 ss 检查
    if command -v ss >/dev/null; then
        ss -tlun 2>/dev/null | grep -q ":$port " && return 0
    elif command -v netstat >/dev/null; then
        netstat -tlun 2>/dev/null | grep -q ":$port " && return 0
    fi
    return 1 # 未被占用
}

generate_random_port() {
    local port
    while true; do
        # 生成 10000 - 60000 范围端口
        port=$((10000 + RANDOM % 50001))
        if ! is_port_in_use "$port"; then
            echo "$port"
            return
        fi
    done
}

# ---------------------------------------------------------
# 5. 进程守护与代理控制
# ---------------------------------------------------------
get_proxy_status() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        # 精确探活：仅 PID 文件存在不够，必须向该 PID 发送探针信号 0
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${GREEN}运行中 (PID: $pid)${NC}"
            return 0
        fi
    fi
    echo -e "${DIM}已停止${NC}"
    return 1
}

start_proxy() {
    check_and_install_gost || return
    
    if get_proxy_status >/dev/null; then
        echo -e "${YELLOW}[!] 代理已在运行中。请先停止后再启动。${NC}"
        read -n 1 -r -p "按任意键继续..."
        return
    fi

    local port=""
    if [[ -f "$CONFIG_FILE" ]]; then
        port=$(cat "$CONFIG_FILE" 2>/dev/null)
    fi

    if [[ -z "$port" ]]; then
        echo -ne "请输入要开放的代理端口号 (按 ${GREEN}[回车]${NC} 自动生成随机端口): "
        read -r user_port
        if [[ -z "$user_port" ]]; then
            port=$(generate_random_port)
            echo -e "${DIM}[*] 已自动分配空闲端口: $port${NC}"
        else
            port=$user_port
        fi
        
        # 端口占用死循环检测
        while is_port_in_use "$port"; do
            echo -e "${RED}[!] 端口 $port 已被其他程序占用！${NC}"
            echo -ne "请重新输入端口号 (按 ${GREEN}[回车]${NC} 自动生成): "
            read -r user_port
            if [[ -z "$user_port" ]]; then
                port=$(generate_random_port)
                echo -e "${DIM}[*] 已自动分配空闲端口: $port${NC}"
            else
                port=$user_port
            fi
        done
        
        echo "$port" > "$CONFIG_FILE"
    fi

    # 清理旧日志并推入后台执行 (Gost 默认缺省协议为 HTTP & SOCKS5 并存)
    > "$LOG_FILE"
    nohup gost -L=:$port > "$LOG_FILE" 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$PID_FILE"
    
    sleep 1 # 等待 gost 申请端口与初始化
    if kill -0 "$new_pid" 2>/dev/null; then
        echo -e "${GREEN}[✔] 代理启动成功！生效端口: $port${NC}"
    else
        echo -e "${RED}[✘] 代理启动失败，请检查日志。${NC}"
    fi
    read -n 1 -r -p "按任意键继续..."
}

stop_proxy() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            echo -e "${GREEN}[✔] 代理进程 (PID: $pid) 已安全终止。${NC}"
        else
            echo -e "${DIM}[*] 未发现存活的代理进程，已清理冗余文件。${NC}"
        fi
    else
        echo -e "${DIM}[*] 代理原本就没有运行。${NC}"
    fi
    
    # 彻底抹除配置与运行痕迹
    rm -f "$PID_FILE" "$CONFIG_FILE" "$LOG_FILE" 2>/dev/null
    read -n 1 -r -p "按任意键继续..."
}

modify_port() {
    if get_proxy_status >/dev/null; then
        echo -e "${YELLOW}[!] 检测到代理正在运行中，修改端口前需先停止。${NC}"
        stop_proxy
    fi
    # 删除旧配置后直接调用 start 引导交互
    rm -f "$CONFIG_FILE" 2>/dev/null
    start_proxy
}

view_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        echo -e "${YELLOW}[!] 日志文件不存在或代理尚未运行过。${NC}"
        read -n 1 -r -p "按任意键继续..."
        return
    fi
    clear
    echo -e "==========================================="
    echo -e " ${GREEN}实时日志查看 (按 Ctrl+C 退出查看)${NC}"
    echo -e "==========================================="
    # 使用 trap 防止 Ctrl+C 把整个面板脚本杀掉
    trap 'break' INT
    tail -f "$LOG_FILE"
    trap - INT
}

# ---------------------------------------------------------
# 6. ASCII UI 与交互主循环
# ---------------------------------------------------------
draw_menu() {
    clear
    local current_status
    local current_ip
    local current_port="未设置"

    current_status=$(get_proxy_status)
    current_ip=$(get_lan_ip)
    if [[ -f "$CONFIG_FILE" ]]; then
        current_port=$(cat "$CONFIG_FILE" 2>/dev/null)
    fi

    echo -e "${BLUE}╔═════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}          ${GREEN}局域网共享代理管理面板${NC} (gost版)        ${BLUE}║${NC}"
    echo -e "${BLUE}╠═════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} 当前状态 : $current_status"
    echo -e "${BLUE}║${NC} 本机内网 : ${YELLOW}$current_ip${NC}"
    echo -e "${BLUE}║${NC} 代理端口 : ${YELLOW}$current_port${NC}"
    echo -e "${BLUE}╠═════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}  ${YELLOW}1.${NC} 启动 / 重启代理 (首次启动引导设置)           ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${YELLOW}2.${NC} 卸载代理 (停止进程并清理所有痕迹)            ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${YELLOW}3.${NC} 查看当前配置详情                             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${YELLOW}4.${NC} 实时查看底层日志 (排错专用)                  ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${YELLOW}5.${NC} 修改端口号                                   ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${RED}0.${NC} 退出面板 (代理后台常驻，敲 ${GREEN}start${NC} 随时唤出)   ${BLUE}║${NC}"
    echo -e "${BLUE}╚═════════════════════════════════════════════════╝${NC}"
    echo -ne " ${DIM}请选择操作选项 [0-5]:${NC} "
}

main_loop() {
    # 执行环境自检与固化
    auto_install_env
    
    while true; do
        draw_menu
        read -r choice
        case "$choice" in
            1)
                start_proxy
                ;;
            2)
                stop_proxy
                ;;
            3)
                echo -e "\n${BLUE}========== 当前配置参数 ==========${NC}"
                if [[ -f "$CONFIG_FILE" ]]; then
                    echo -e "连接协议 : HTTP / SOCKS5 双栈自适应"
                    echo -e "连接地址 : $(get_lan_ip)"
                    echo -e "端口号码 : $(cat "$CONFIG_FILE")"
                    echo -e "底层日志 : $LOG_FILE"
                else
                    echo -e "${DIM}尚未生成配置文件，请先启动代理。${NC}"
                fi
                echo -e "${BLUE}==================================${NC}"
                read -n 1 -r -p "按任意键继续..."
                ;;
            4)
                view_logs
                ;;
            5)
                modify_port
                ;;
            0)
                echo -e "\n${GREEN}[✔] 已退出面板！${NC}"
                echo -e "${DIM}提示：哪怕完全关闭 Termux 会话，只要安卓未杀后台，代理将持续有效。${NC}"
                echo -e "${DIM}若要再次呼出面板，随时随地输入命令: ${GREEN}start${NC}\n"
                exit 0
                ;;
            *)
                echo -e "${RED}[!] 无效的输入，请重新选择。${NC}"
                sleep 1
                ;;
        esac
    done
}

# 启动入口
main_loop
