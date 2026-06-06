#!/data/data/com.termux/files/usr/bin/bash
# ================================================================
#  start.sh — LAN Proxy Management Panel (gost-powered)
#  Designed for Android Termux | Production-Grade | Self-Healing
# ================================================================

# ── ANSI 颜色变量 ────────────────────────────────────────────────
R='\033[0;31m'   # Red
G='\033[0;32m'   # Green
Y='\033[0;33m'   # Yellow
B='\033[0;34m'   # Blue
C='\033[0;36m'   # Cyan
W='\033[1;37m'   # White Bold
M='\033[0;35m'   # Magenta
DIM='\033[2m'    # Dim
NC='\033[0m'     # No Color / Reset

# ── 全局文件路径 ─────────────────────────────────────────────────
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
CONFIG_FILE="$HOME/.start_config"
PID_FILE="$HOME/.start_proxy.pid"
LOG_FILE="$HOME/.start_proxy.log"
SELF_PATH="$HOME/start.sh"
LAUNCHER="$PREFIX/bin/start"
GOST_BIN="$PREFIX/bin/gost"
GOST_VER="2.11.5"

# ================================================================
#  § 1  自固化与全局入口注入
# ================================================================

get_real_path() {
    local src="${BASH_SOURCE[0]:-$0}"
    local real
    real="$(readlink -f "$src" 2>/dev/null || realpath "$src" 2>/dev/null || echo "$src")"
    echo "$real"
}

self_solidify() {
    local real_path
    real_path="$(get_real_path)"

    # 若当前位置不是 ~/start.sh，则复制自身
    if [[ "$real_path" != "$SELF_PATH" ]]; then
        cp "$real_path" "$SELF_PATH" 2>/dev/null
        chmod +x "$SELF_PATH" 2>/dev/null
    fi

    # 写入 $PREFIX/bin/start 全局启动器
    if [[ ! -f "$LAUNCHER" ]] || ! grep -q "start.sh" "$LAUNCHER" 2>/dev/null; then
        cat > "$LAUNCHER" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
exec bash "$HOME/start.sh" "$@"
EOF
        chmod +x "$LAUNCHER" 2>/dev/null
    fi

    # 向 .bashrc 注入别名
    local alias_line="alias start='bash ~/start.sh'"
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rc" ]] && ! grep -qF "$alias_line" "$rc" 2>/dev/null; then
            echo "$alias_line" >> "$rc"
        fi
    done
}

# ================================================================
#  § 2  gost 智能依赖安装
# ================================================================

get_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        aarch64|arm64) echo "armv8" ;;
        armv7*|armv7)  echo "armv7" ;;
        x86_64)        echo "amd64" ;;
        i686|i386)     echo "386"   ;;
        *)             echo "armv8" ;;  # 默认 fallback
    esac
}

install_gost() {
    echo -e "${Y}[*] gost 未找到，正在尝试自动安装...${NC}"
    sleep 1

    # 方式一：pkg 包管理器
    echo -e "${DIM}    尝试 pkg install gost ...${NC}"
    if pkg install gost -y 2>/dev/null; then
        if command -v gost &>/dev/null || [[ -x "$GOST_BIN" ]]; then
            echo -e "${G}[✓] pkg 安装 gost 成功${NC}"
            return 0
        fi
    fi

    # 方式二：GitHub Release 手动下载
    local arch
    arch="$(get_arch)"
    local fname="gost_${GOST_VER}_linux_${arch}.tar.gz"
    local url="https://github.com/ginuerzh/gost/releases/download/v${GOST_VER}/${fname}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    echo -e "${DIM}    架构识别: ${arch}${NC}"
    echo -e "${DIM}    下载: ${url}${NC}"

    if curl -fsSL --connect-timeout 20 --retry 3 -o "${tmp_dir}/${fname}" "$url" 2>/dev/null; then
        tar -xzf "${tmp_dir}/${fname}" -C "$tmp_dir" 2>/dev/null
        local gost_exe
        gost_exe="$(find "$tmp_dir" -name "gost" -type f 2>/dev/null | head -1)"
        if [[ -n "$gost_exe" ]]; then
            cp "$gost_exe" "$GOST_BIN" && chmod +x "$GOST_BIN"
            rm -rf "$tmp_dir" 2>/dev/null
            echo -e "${G}[✓] GitHub 手动安装 gost 成功${NC}"
            return 0
        fi
    fi

    rm -rf "$tmp_dir" 2>/dev/null
    echo -e "${R}[✗] gost 安装失败，请检查网络连接后重试${NC}"
    return 1
}

check_gost() {
    command -v gost &>/dev/null || [[ -x "$GOST_BIN" ]]
}

# ================================================================
#  § 3  网络工具函数
# ================================================================

get_lan_ips() {
    ifconfig 2>/dev/null \
        | grep -oP 'inet \K[\d.]+' \
        | grep -v '^127\.' \
        | grep -v '^100\.' \
        | grep -v '\.255$' \
        | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' \
        | sort -u
}

is_port_in_use() {
    local port="$1"
    ss -lntu 2>/dev/null | grep -qP "[:.]${port}\b" \
        || netstat -lntu 2>/dev/null | grep -qP "[:.]${port}\b"
}

random_free_port() {
    local port
    while true; do
        port=$(( RANDOM % 50001 + 10000 ))
        if ! is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done
}

prompt_port() {
    local label="$1"
    local port_var="$2"
    local suggested
    suggested="$(random_free_port)"
    local input

    while true; do
        echo -ne "${C}  ${label} [直接回车随机 ${suggested}]: ${NC}"
        read -r input
        [[ -z "$input" ]] && input="$suggested"

        # 验证数字范围
        if ! [[ "$input" =~ ^[0-9]+$ ]] || (( input < 1024 || input > 65535 )); then
            echo -e "${R}  端口须在 1024-65535 之间${NC}"
            continue
        fi

        if is_port_in_use "$input"; then
            echo -e "${R}  端口 ${input} 已被占用，请换一个${NC}"
            suggested="$(random_free_port)"
            continue
        fi

        eval "$port_var=$input"
        return 0
    done
}

# ================================================================
#  § 4  配置文件读写
# ================================================================

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

save_config() {
    local socks_port="$1"
    local http_port="$2"
    cat > "$CONFIG_FILE" <<EOF
SOCKS_PORT=${socks_port}
HTTP_PORT=${http_port}
EOF
}

# ================================================================
#  § 5  进程守护：启动 / 停止 / 状态
# ================================================================

start_proxy() {
    load_config

    # 若无配置，引导用户设置端口
    if [[ -z "$SOCKS_PORT" || -z "$HTTP_PORT" ]]; then
        echo -e "\n${W}  首次启动，请配置监听端口${NC}"
        prompt_port "SOCKS5 端口" SOCKS_PORT
        prompt_port "HTTP  端口" HTTP_PORT
        save_config "$SOCKS_PORT" "$HTTP_PORT"
    else
        # 检查已保存端口是否仍可用（防止重启后端口被占）
        if is_port_in_use "$SOCKS_PORT"; then
            echo -e "${Y}  原 SOCKS 端口 ${SOCKS_PORT} 已被占用，重新分配...${NC}"
            prompt_port "SOCKS5 端口" SOCKS_PORT
        fi
        if is_port_in_use "$HTTP_PORT"; then
            echo -e "${Y}  原 HTTP 端口 ${HTTP_PORT} 已被占用，重新分配...${NC}"
            prompt_port "HTTP  端口" HTTP_PORT
        fi
        save_config "$SOCKS_PORT" "$HTTP_PORT"
    fi

    # 确保 gost 已安装
    if ! check_gost; then
        install_gost || { echo -e "${R}  无法启动：gost 不可用${NC}"; return 1; }
    fi

    # 停止已有进程
    stop_proxy_silent

    # 启动 gost（socks5 + http 双协议）
    local gost_cmd
    gost_cmd="$(command -v gost 2>/dev/null || echo "$GOST_BIN")"

    nohup "$gost_cmd" \
        -L "socks5://:${SOCKS_PORT}" \
        -L "http://:${HTTP_PORT}" \
        > "$LOG_FILE" 2>&1 &

    local pid=$!
    echo "$pid" > "$PID_FILE"
    sleep 1

    if kill -0 "$pid" 2>/dev/null; then
        echo -e "${G}  [✓] 代理已启动 (PID: ${pid})${NC}"
        echo -e "${G}  SOCKS5: ${SOCKS_PORT}  |  HTTP: ${HTTP_PORT}${NC}"
    else
        echo -e "${R}  [✗] 启动失败，请查看日志${NC}"
        rm -f "$PID_FILE" 2>/dev/null
        return 1
    fi
}

stop_proxy_silent() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 0.5
            kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$PID_FILE" 2>/dev/null
    fi
    # 兜底：杀掉同名进程
    pkill -f "gost.*socks5\|gost.*http" 2>/dev/null || true
}

is_proxy_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null)"
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
    else
        return 1
    fi
}

get_proxy_pid() {
    [[ -f "$PID_FILE" ]] && cat "$PID_FILE" 2>/dev/null || echo "-"
}

# ================================================================
#  § 6  菜单动作函数
# ================================================================

action_start_restart() {
    if is_proxy_running; then
        echo -e "\n${Y}  检测到代理正在运行，将执行重启...${NC}"
        stop_proxy_silent
        sleep 0.5
    fi
    start_proxy
    echo -ne "\n${DIM}  按回车返回菜单...${NC}"; read -r
}

action_uninstall() {
    echo -ne "\n${R}  确认停止代理并清除所有配置/日志? [y/N]: ${NC}"
    read -r confirm
    if [[ "${confirm,,}" == "y" ]]; then
        stop_proxy_silent
        rm -f "$CONFIG_FILE" "$LOG_FILE" "$PID_FILE" 2>/dev/null
        echo -e "${G}  [✓] 已卸载，所有配置和日志已清除${NC}"
    else
        echo -e "${DIM}  已取消${NC}"
    fi
    echo -ne "\n${DIM}  按回车返回菜单...${NC}"; read -r
}

action_show_config() {
    load_config
    echo -e "\n${W}  ── 当前配置 ────────────────────────────${NC}"
    echo -e "  配置文件  : ${DIM}${CONFIG_FILE}${NC}"
    echo -e "  SOCKS5 端口: ${C}${SOCKS_PORT:-未设置}${NC}"
    echo -e "  HTTP  端口 : ${C}${HTTP_PORT:-未设置}${NC}"
    echo -e "  PID 文件  : ${DIM}${PID_FILE}${NC}"
    echo -e "  日志文件  : ${DIM}${LOG_FILE}${NC}"
    echo -e "  gost 路径  : ${DIM}$(command -v gost 2>/dev/null || echo "$GOST_BIN")${NC}"
    echo ""
    echo -e "${W}  ── 可用局域网 IP ────────────────────────${NC}"
    local ips
    ips="$(get_lan_ips)"
    if [[ -z "$ips" ]]; then
        echo -e "  ${R}暂无可用局域网 IP（请检查网络连接）${NC}"
    else
        while IFS= read -r ip; do
            echo -e "  ${G}●${NC} ${ip}"
            [[ -n "$SOCKS_PORT" ]] && echo -e "    ${DIM}socks5://${ip}:${SOCKS_PORT}${NC}"
            [[ -n "$HTTP_PORT"  ]] && echo -e "    ${DIM}http://${ip}:${HTTP_PORT}${NC}"
        done <<< "$ips"
    fi
    echo -ne "\n${DIM}  按回车返回菜单...${NC}"; read -r
}

action_view_log() {
    if [[ ! -f "$LOG_FILE" ]]; then
        echo -e "\n${Y}  日志文件不存在（代理尚未运行过）${NC}"
        echo -ne "\n${DIM}  按回车返回菜单...${NC}"; read -r
        return
    fi
    echo -e "\n${DIM}  实时日志（Ctrl+C 退出查看，不影响代理运行）${NC}\n"
    tail -f "$LOG_FILE"
}

action_change_port() {
    load_config
    echo -e "\n${W}  修改端口配置${NC}"
    echo -e "  当前 SOCKS5: ${C}${SOCKS_PORT:-未设置}${NC}  HTTP: ${C}${HTTP_PORT:-未设置}${NC}\n"

    local new_socks new_http
    prompt_port "新 SOCKS5 端口" new_socks
    prompt_port "新 HTTP  端口" new_http
    save_config "$new_socks" "$new_http"
    SOCKS_PORT="$new_socks"
    HTTP_PORT="$new_http"

    echo -e "${G}  [✓] 端口已更新${NC}"

    if is_proxy_running; then
        echo -ne "  ${Y}代理正在运行，是否立即重启以生效? [Y/n]: ${NC}"
        read -r yn
        if [[ "${yn,,}" != "n" ]]; then
            stop_proxy_silent
            sleep 0.3
            start_proxy
        fi
    fi
    echo -ne "\n${DIM}  按回车返回菜单...${NC}"; read -r
}

# ================================================================
#  § 7  主菜单 UI
# ================================================================

draw_header() {
    load_config
    local status_str pid_str ip_list socks_str http_str

    if is_proxy_running; then
        status_str="${G}● 运行中${NC}"
        pid_str="$(get_proxy_pid)"
    else
        status_str="${R}○ 已停止${NC}"
        pid_str="-"
    fi

    ip_list="$(get_lan_ips)"
    socks_str="${SOCKS_PORT:-未配置}"
    http_str="${HTTP_PORT:-未配置}"

    clear
    echo -e "${C}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${C}║${W}       LAN Proxy Panel  ·  powered by gost            ${C}║${NC}"
    echo -e "${C}╠══════════════════════════════════════════════════════╣${NC}"
    printf "${C}║${NC}  状态   : %-43b${C}║${NC}\n" "${status_str}"
    printf "${C}║${NC}  PID    : %-44s${C}║${NC}\n" "${pid_str}"
    printf "${C}║${NC}  SOCKS5 : %-44s${C}║${NC}\n" "${socks_str}"
    printf "${C}║${NC}  HTTP   : %-44s${C}║${NC}\n" "${http_str}"
    echo -e "${C}╠══════════════════════════════════════════════════════╣${NC}"

    if [[ -z "$ip_list" ]]; then
        printf "${C}║${NC}  ${R}局域网 IP : 暂无（请检查 Wi-Fi 连接）${NC}%-16s${C}║${NC}\n" ""
    else
        while IFS= read -r ip; do
            printf "${C}║${NC}  ${G}▶${NC} %-51s${C}║${NC}\n" "${ip}"
        done <<< "$ip_list"
    fi

    echo -e "${C}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${C}║${NC}  ${W}1${NC}. 启动 / 重启代理                                   ${C}║${NC}"
    echo -e "${C}║${NC}  ${W}2${NC}. 卸载代理（停止并清除配置）                         ${C}║${NC}"
    echo -e "${C}║${NC}  ${W}3${NC}. 查看当前配置与连接地址                             ${C}║${NC}"
    echo -e "${C}║${NC}  ${W}4${NC}. 实时查看日志                                       ${C}║${NC}"
    echo -e "${C}║${NC}  ${W}5${NC}. 修改端口号                                         ${C}║${NC}"
    echo -e "${C}║${NC}  ${W}0${NC}. 退出面板                                           ${C}║${NC}"
    echo -e "${C}╚══════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${DIM}提示: 面板退出不影响后台代理，随时敲 ${W}start${DIM} 唤出${NC}\n"
}

main_menu() {
    while true; do
        draw_header
        echo -ne "${W}  请输入选项 [0-5]: ${NC}"
        read -r choice

        case "$choice" in
            1) action_start_restart ;;
            2) action_uninstall     ;;
            3) action_show_config   ;;
            4) action_view_log      ;;
            5) action_change_port   ;;
            0)
                echo -e "\n${DIM}  代理仍在后台运行（若已启动），再见！${NC}\n"
                exit 0
                ;;
            *)
                echo -e "${R}  无效选项，请重新输入${NC}"
                sleep 0.8
                ;;
        esac
    done
}

# ================================================================
#  § 8  入口
# ================================================================

main() {
    self_solidify
    main_menu
}

main "$@"
