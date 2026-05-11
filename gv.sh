#!/usr/bin/env bash
# ============================================================
#  局域网共享代理管理面板
#  依赖: gost  （选 1 启动时若未安装会自动通过包管理器或镜像站安装）
#  用法: gv            ← 任意目录直接敲这三个字母
#        bash ~/gv.sh  ← 或完整路径
# ============================================================

# ---------- 颜色定义 ----------
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_WHITE='\033[1;37m'
C_DIM='\033[2m'

# ---------- 路径 / 文件 ----------
CONFIG_FILE="$HOME/.gv_config"
PID_FILE="$HOME/.gv_proxy.pid"
LOG_FILE="$HOME/.gv_proxy.log"
SELF_PATH="$HOME/gv.sh"
# 自动适配 Termux 或 标准 Linux 路径
PREFIX_PATH="${PREFIX:-/usr}"
LAUNCHER_BIN="$PREFIX_PATH/bin/gv"
GOST_BIN="$(which gost 2>/dev/null)"

# ---------- 工具函数 ----------

# 将脚本固化到 ~/gv.sh，并在 PATH 或环境配置文件中注入全局入口
# 确保无论从哪里、用任何方式调用，`gv` 都能稳定生效
_write_launcher() {
    # 1. 获取本脚本的真实磁盘路径
    local real_path
    real_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)"

    # 2. 同步到 ~/gv.sh 并赋予执行权限
    if [[ -f "$real_path" && "$real_path" != "$SELF_PATH" ]]; then
        cp -f "$real_path" "$SELF_PATH"
        chmod +x "$SELF_PATH"
    fi

    # 3. 尝试在 PREFIX/bin 写一个极简启动器
    local write_success=false
    if touch "$LAUNCHER_BIN" 2>/dev/null; then
        cat > "$LAUNCHER_BIN" << 'LAUNCHER_EOF'
#!/usr/bin/env bash
exec bash "$HOME/gv.sh" "$@"
LAUNCHER_EOF
        chmod +x "$LAUNCHER_BIN" 2>/dev/null && write_success=true
    fi

    # 4. 双重保险：如果写入系统 PATH 失败，或者为了适配多终端，注入 alias 到 bash/zsh 配置文件
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rc" ]] && ! grep -q "alias gv=" "$rc"; then
            echo -e "\n# gv proxy panel shortcut\nalias gv='bash \"$HOME/gv.sh\"'" >> "$rc"
        fi
    done

    # 重新加载当前 shell 的 alias (对正在运行的当前终端生效)
    alias gv='bash "$HOME/gv.sh"' 2>/dev/null || true
}

# 从 ifconfig/ip 暴力扫描局域网 IP
_get_lan_ips() {
    local raw
    raw=$(ifconfig 2>/dev/null || ip addr 2>/dev/null)
    echo "$raw" \
        | grep -Eo '(192\.168\.[0-9]{1,3}\.[0-9]{1,3}|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})' \
        | sort -u
}

# 读取配置（socks_port http_port）
_load_config() {
    SOCKS_PORT=""
    HTTP_PORT=""
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

# 保存配置
_save_config() {
    cat > "$CONFIG_FILE" <<EOF
SOCKS_PORT=$SOCKS_PORT
HTTP_PORT=$HTTP_PORT
EOF
}

# 检查端口是否被占用
_port_free() {
    local port=$1
    ! ss -lntu 2>/dev/null | grep -q ":${port} " && \
    ! netstat -lntu 2>/dev/null | grep -q ":${port} "
}

# 在 10000-60000 内随机挑一个空闲端口
_random_port() {
    local p
    while true; do
        p=$(( RANDOM % 50001 + 10000 ))
        _port_free "$p" && echo "$p" && return
    done
}

# 验证端口合法性 (1024-65535)
_valid_port() {
    local p=$1
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1024 && p <= 65535 ))
}

# ---------- 检查 / 镜像自动安装 gost ----------
_check_gost() {
    GOST_BIN="$(which gost 2>/dev/null)"
    # 如果用户目录有自行下载的备用二进制文件，也认领
    if [[ -z "$GOST_BIN" && -x "$HOME/.local/bin/gost" ]]; then
        GOST_BIN="$HOME/.local/bin/gost"
    fi

    if [[ -n "$GOST_BIN" ]]; then
        return 0
    fi

    echo -e "${C_YELLOW}未检测到 gost，正在尝试自动安装...${C_RESET}"
    
    # 1. 尝试使用常规包管理器安装
    echo -e "${C_DIM}>> 尝试包管理器安装 (pkg/apt)...${C_RESET}"
    if command -v pkg >/dev/null 2>&1; then
        pkg install gost -y 2>/dev/null
    elif command -v apt >/dev/null 2>&1; then
        apt update 2>/dev/null && apt install gost -y 2>/dev/null
    fi

    GOST_BIN="$(which gost 2>/dev/null)"
    if [[ -n "$GOST_BIN" ]]; then
        echo -e "\n${C_GREEN}[✓] gost 包管理器安装成功！${C_RESET}"
        sleep 0.5
        return 0
    fi

    # 2. 包管理器失败，采用镜像网站下载二进制文件
    echo -e "${C_YELLOW}包管理器无可用版本，正在通过 Github 镜像站下载...${C_RESET}"
    
    # 识别系统架构
    local arch
    arch=$(uname -m)
    local gost_arch="amd64"
    case "$arch" in
        aarch64)      gost_arch="armv8" ;;
        armv7*|armv8l) gost_arch="armv7" ;;
        x86_64)       gost_arch="amd64" ;;
        i*86)         gost_arch="386" ;;
    esac

    local version="2.11.5"
    local filename="gost-linux-${gost_arch}-${version}.gz"
    local mirror_url="https://mirror.ghproxy.com/https://github.com/ginuerzh/gost/releases/download/v${version}/${filename}"

    echo -e "${C_DIM}>> 识别架构: ${gost_arch} | 下载版本: v${version}${C_RESET}"
    echo -e "${C_DIM}>> 请求镜像源: mirror.ghproxy.com ...${C_RESET}"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    cd "$tmp_dir" || return 1

    if curl -L -k -# "$mirror_url" -o gost.gz; then
        gzip -d gost.gz
        chmod +x gost
        
        # 尝试安装到环境变量目录，失败则存放到用户目录
        local bin_target="$PREFIX_PATH/bin/gost"
        if mv gost "$bin_target" 2>/dev/null; then
            GOST_BIN="$bin_target"
        else
            mkdir -p "$HOME/.local/bin"
            mv gost "$HOME/.local/bin/gost"
            GOST_BIN="$HOME/.local/bin/gost"
        fi
    fi
    cd - >/dev/null || true
    rm -rf "$tmp_dir"

    # 验证镜像下载的程序能否运行
    if [[ -n "$GOST_BIN" ]] && "$GOST_BIN" -V >/dev/null 2>&1; then
        echo -e "\n${C_GREEN}[✓] gost 镜像版下载并安装成功！${C_RESET}"
        sleep 0.5
        return 0
    fi

    # 安装失败兜底提示
    echo -e "\n${C_RED}[✗] 自动安装失败，请检查网络或手动安装。${C_RESET}"
    echo -e "    手动命令: pkg install gost"
    echo -e "    ${C_DIM}（或从 https://github.com/go-gost/gost/releases 自行下载）${C_RESET}"
    return 1
}

# ---------- 进程状态 ----------
_is_running() {
    [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

_status_line() {
    if _is_running; then
        echo -e "${C_GREEN}● 运行中${C_RESET}  (PID: $(cat "$PID_FILE"))"
    else
        echo -e "${C_RED}○ 未运行${C_RESET}"
    fi
}

# ---------- 启动代理 ----------
_start_proxy() {
    _check_gost || return

    _load_config

    # 若无配置，引导设置端口
    if [[ -z "$SOCKS_PORT" || -z "$HTTP_PORT" ]]; then
        echo -e "\n${C_YELLOW}首次运行，请配置端口：${C_RESET}"
        _set_ports_interactive
        _load_config
    fi

    # 先停掉旧进程
    _stop_proxy_silent

    echo -e "\n${C_CYAN}正在启动代理...${C_RESET}"

    # Gost 同时开 socks5 + http，全网卡监听
    nohup "$GOST_BIN" \
        -L "socks5://0.0.0.0:${SOCKS_PORT}" \
        -L "http://0.0.0.0:${HTTP_PORT}" \
        > "$LOG_FILE" 2>&1 &

    echo $! > "$PID_FILE"
    sleep 0.8

    if _is_running; then
        echo -e "${C_GREEN}[✓] 代理启动成功！${C_RESET}"
    else
        echo -e "${C_RED}[✗] 启动失败，查看日志：cat $LOG_FILE${C_RESET}"
    fi
}

# 静默停止（内部调用）
_stop_proxy_silent() {
    if [[ -f "$PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$PID_FILE")
        kill "$old_pid" 2>/dev/null
        rm -f "$PID_FILE"
        sleep 0.3
    fi
    # 兜底：杀掉残留 gost 进程
    pkill -f "gost.*0.0.0.0" 2>/dev/null || true
}

# ---------- 卸载代理 ----------
_uninstall_proxy() {
    _stop_proxy_silent
    rm -f "$CONFIG_FILE" "$PID_FILE" "$LOG_FILE"
    echo -e "${C_YELLOW}[✓] 代理已停止，配置已清除。${C_RESET}"
    echo -e "${C_DIM}    如需完全卸载 gost 本体：pkg remove gost${C_RESET}"
}

# ---------- 修改端口（交互） ----------
_set_ports_interactive() {
    echo ""
    echo -e "${C_WHITE}╔══ 端口配置 ═════════════════════════════════╗${C_RESET}"
    echo -e "${C_WHITE}║${C_RESET}  可用范围：${C_CYAN}1024 - 65535${C_RESET}"
    echo -e "${C_WHITE}║${C_RESET}  直接回车 → 在 ${C_CYAN}10000-60000${C_RESET} 内随机分配"
    echo -e "${C_WHITE}╚══════════════════════════════════════════════╝${C_RESET}"

    # Socks 端口
    while true; do
        read -rp "  Socks 端口 [回车随机]: " input_socks
        if [[ -z "$input_socks" ]]; then
            SOCKS_PORT=$(_random_port)
            echo -e "  ${C_DIM}→ 随机分配 Socks 端口：${SOCKS_PORT}${C_RESET}"
            break
        elif _valid_port "$input_socks"; then
            SOCKS_PORT=$input_socks
            break
        else
            echo -e "  ${C_RED}端口无效，请输入 1024-65535 之间的整数。${C_RESET}"
        fi
    done

    # HTTP 端口
    while true; do
        read -rp "  HTTP  端口 [回车随机]: " input_http
        if [[ -z "$input_http" ]]; then
            HTTP_PORT=$(_random_port)
            echo -e "  ${C_DIM}→ 随机分配 HTTP  端口：${HTTP_PORT}${C_RESET}"
            break
        elif _valid_port "$input_http"; then
            if [[ "$input_http" == "$SOCKS_PORT" ]]; then
                echo -e "  ${C_RED}HTTP 端口不能与 Socks 端口相同，请重新输入。${C_RESET}"
            else
                HTTP_PORT=$input_http
                break
            fi
        else
            echo -e "  ${C_RED}端口无效，请输入 1024-65535 之间的整数。${C_RESET}"
        fi
    done

    _save_config
    echo -e "\n  ${C_GREEN}[✓] 端口已保存：Socks=${SOCKS_PORT}  HTTP=${HTTP_PORT}${C_RESET}"
}

# ---------- 实时日志 ----------
_view_log() {
    if [[ ! -f "$LOG_FILE" ]]; then
        echo -e "${C_YELLOW}暂无日志文件，请先启动代理。${C_RESET}"
        return
    fi
    echo -e "${C_DIM}按 Ctrl+C 退出日志查看${C_RESET}\n"
    tail -f "$LOG_FILE"
}

# ---------- 绘制主面板 ----------
_draw_panel() {
    clear
    _load_config

    # --- IP 列表 ---
    local lan_ips
    lan_ips=$(_get_lan_ips)

    echo ""
    echo -e "${C_BOLD}${C_WHITE}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_WHITE}║        局域网共享代理  管理面板              ║${C_RESET}"
    echo -e "${C_BOLD}${C_WHITE}╠══════════════════════════════════════════════╣${C_RESET}"

    # 状态行
    printf "${C_BOLD}${C_WHITE}║${C_RESET}  状态  %-38s${C_BOLD}${C_WHITE}║${C_RESET}\n" "$(_status_line)"

    echo -e "${C_BOLD}${C_WHITE}╠══════════════════════════════════════════════╣${C_RESET}"

    # 当前配置
    if [[ -n "$SOCKS_PORT" && -n "$HTTP_PORT" ]]; then
        echo -e "${C_WHITE}║${C_RESET}  Socks 端口 : ${C_CYAN}${SOCKS_PORT}${C_RESET}"
        echo -e "${C_WHITE}║${C_RESET}  HTTP  端口 : ${C_CYAN}${HTTP_PORT}${C_RESET}"
    else
        echo -e "${C_WHITE}║${C_RESET}  ${C_DIM}端口未配置（启动时将引导设置）${C_RESET}"
    fi

    echo -e "${C_BOLD}${C_WHITE}╠══════════════════════════════════════════════╣${C_RESET}"

    # 局域网 IP（暴力扫描结果）
    echo -e "${C_WHITE}║${C_RESET}  ${C_BOLD}本机局域网 IP：${C_RESET}"
    if [[ -z "$lan_ips" ]]; then
        echo -e "${C_WHITE}║${C_RESET}    ${C_YELLOW}（未检测到局域网 IP，请检查 WiFi 连接）${C_RESET}"
    else
        while IFS= read -r ip; do
            echo -e "${C_WHITE}║${C_RESET}    ${C_GREEN}${ip}${C_RESET}"
        done <<< "$lan_ips"
    fi

    echo -e "${C_BOLD}${C_WHITE}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_WHITE}║${C_RESET}  ${C_BOLD}客户端填写示例（以第一个 IP 为准）：${C_RESET}"

    local first_ip
    first_ip=$(echo "$lan_ips" | head -n1)
    if [[ -n "$first_ip" && -n "$SOCKS_PORT" ]]; then
        echo -e "${C_WHITE}║${C_RESET}    Socks : ${C_CYAN}${first_ip}${C_RESET} : ${C_CYAN}${SOCKS_PORT}${C_RESET}"
        echo -e "${C_WHITE}║${C_RESET}    HTTP  : ${C_CYAN}${first_ip}${C_RESET} : ${C_CYAN}${HTTP_PORT}${C_RESET}"
    else
        echo -e "${C_WHITE}║${C_RESET}    ${C_DIM}（启动代理并连接 WiFi 后显示）${C_RESET}"
    fi

    echo -e "${C_BOLD}${C_WHITE}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_WHITE}║${C_RESET}  ${C_BOLD}快捷启动：${C_RESET}直接输入 ${C_CYAN}gv${C_RESET} 或 ${C_CYAN}bash ~/gv.sh${C_RESET}"
    echo -e "${C_BOLD}${C_WHITE}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_WHITE}║${C_RESET}  ${C_GREEN}1${C_RESET}. 启动 / 重新启动代理"
    echo -e "${C_WHITE}║${C_RESET}  ${C_YELLOW}2${C_RESET}. 卸载代理（停止并清除配置）"
    echo -e "${C_WHITE}║${C_RESET}  ${C_CYAN}3${C_RESET}. 查看当前配置"
    echo -e "${C_WHITE}║${C_RESET}  ${C_CYAN}4${C_RESET}. 实时查看日志"
    echo -e "${C_WHITE}║${C_RESET}  ${C_CYAN}5${C_RESET}. 修改端口号  ${C_DIM}（范围：1024 - 65535）${C_RESET}"
    echo -e "${C_WHITE}║${C_RESET}  ${C_RED}0${C_RESET}. 退出"
    echo -e "${C_BOLD}${C_WHITE}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
}

# ---------- 查看当前配置 ----------
_show_config() {
    _load_config
    local lan_ips
    lan_ips=$(_get_lan_ips)

    echo ""
    echo -e "${C_BOLD}===== 当前配置 =====${C_RESET}"
    echo -e "  Socks 端口  : ${C_CYAN}${SOCKS_PORT:-（未设置）}${C_RESET}"
    echo -e "  HTTP  端口  : ${C_CYAN}${HTTP_PORT:-（未设置）}${C_RESET}"
    echo -e "  监听地址    : ${C_CYAN}0.0.0.0（全网卡）${C_RESET}"
    echo -e "  日志文件    : ${C_DIM}${LOG_FILE}${C_RESET}"
    echo -e "  配置文件    : ${C_DIM}${CONFIG_FILE}${C_RESET}"
    echo ""
    echo -e "${C_BOLD}===== 局域网 IP =====${C_RESET}"
    if [[ -z "$lan_ips" ]]; then
        echo -e "  ${C_YELLOW}未检测到局域网 IP${C_RESET}"
    else
        echo "$lan_ips" | while IFS= read -r ip; do
            echo -e "  ${C_GREEN}${ip}${C_RESET}"
        done
    fi
    echo ""
}

# ---------- 主循环 ----------
main() {
    # 将自身写到 ~/gv.sh 并注入环境，保证快捷启动
    _write_launcher

    while true; do
        _draw_panel
        read -rp "  请输入选项 [0-5]: " choice
        echo ""
        case "$choice" in
            1)
                _start_proxy
                read -rp "  按回车返回面板..." _dummy
                ;;
            2)
                read -rp "  确认卸载？(y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    _uninstall_proxy
                fi
                read -rp "  按回车返回面板..." _dummy
                ;;
            3)
                _show_config
                read -rp "  按回车返回面板..." _dummy
                ;;
            4)
                _view_log
                ;;
            5)
                _set_ports_interactive
                # 如果代理正在运行，询问是否立即重启生效
                if _is_running; then
                    echo ""
                    read -rp "  代理正在运行，是否立即重启以应用新端口？(Y/n): " restart
                    if [[ ! "$restart" =~ ^[Nn]$ ]]; then
                        _start_proxy
                    fi
                fi
                read -rp "  按回车返回面板..." _dummy
                ;;
            0)
                echo -e "${C_DIM}已退出面板。代理进程继续在后台运行。${C_RESET}"
                echo -e "${C_DIM}随时输入 ${C_RESET}${C_CYAN}gv${C_DIM} 重新打开面板。${C_RESET}"
                echo ""
                exit 0
                ;;
            *)
                echo -e "${C_RED}无效选项，请输入 0-5。${C_RESET}"
                sleep 0.8
                ;;
        esac
    done
}

main "$@"
