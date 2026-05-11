#!/bin/bash

# 智能获取局域网真实 IP 的函数
get_lan_ip() {
    local ip=$(ip -4 addr show 2>/dev/null | grep inet | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -n 1)
    if [ -z "$ip" ]; then
        echo "未检测到有效IP"
    else
        echo "$ip"
    fi
}

gvinstall(){
    # 增加 iproute2 依赖以获取内网IP
    pkg install -y screen iproute2
    
    if [ ! -e gost ]; then
        echo "下载中……"
        curl -L -o gost_3.0.0_linux_arm64.tar.gz -# --retry 2 --insecure https://gh-proxy.com/https://raw.githubusercontent.com/yonggekkk/google_vpn_proxy/main/gost_3.0.0_linux_arm64.tar.gz
        tar zxvf gost_3.0.0_linux_arm64.tar.gz
    fi
    if [ ! -e gost ]; then
        echo "下载失败，请在代理环境下运行脚本" && exit
    fi
    rm -f gost_3.0.0_linux_arm64.tar.gz README* LICENSE* config.yaml
    
    read -p "设置 Socks5 端口（回车跳过为10000-65535之间的随机端口）：" socks_port
    if [ -z "$socks_port" ]; then
        socks_port=$(shuf -i 10000-65535 -n 1)
    fi
    read -p "设置 Http 端口（回车跳过为10000-65535之间的随机端口）：" http_port
    if [ -z "$http_port" ]; then
        http_port=$(shuf -i 10000-65535 -n 1)
    fi
    echo "你设置的 Socks5 端口：$socks_port 和 Http 端口：$http_port" && sleep 2

    # 创建挂载订阅文件的文件夹
    mkdir -p sub_server
    
    # 按照原版逻辑写入 config.yaml（保留 addr: ":端口" 语法，并加入文件服务器）
    cat <<EOF > config.yaml
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
    addr: ":8080"
    handler:
      type: file
      metadata:
        dir: "$PWD/sub_server"
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

    # === 重写 Termux 自启动文件 (profile.d/gost.sh) ===
    cd /data/data/com.termux/files/usr/etc/profile.d
    echo '#!/data/data/com.termux/files/usr/bin/bash' > gost.sh
    echo 'screen -wipe > /dev/null 2>&1' >> gost.sh
    echo "screen -ls | grep Detached | cut -d. -f1 | awk '{print \$1}' | xargs kill > /dev/null 2>&1" >> gost.sh
    
    # 精妙之处：把获取 IP 和生成 Base64 订阅文件的逻辑，直接写进自启脚本里！
    # 这样每次打开 Termux，都会自动用最新的手机内网 IP 刷新订阅文件。
    echo "lan_ip=\$(ip -4 addr show 2>/dev/null | grep inet | grep -v '127.0.0.1' | awk '{print \$2}' | cut -d/ -f1 | head -n 1)" >> gost.sh
    echo "[ -z \"\$lan_ip\" ] && lan_ip=\"127.0.0.1\"" >> gost.sh
    echo "echo -e \"socks5://\$lan_ip:$socks_port#LAN-Socks5\nhttp://\$lan_ip:$http_port#LAN-HTTP\" | base64 > $PWD/sub_server/sub.txt" >> gost.sh
    
    echo "screen -dmS myscreen bash -c 'cd $PWD && ./gost -C config.yaml'" >> gost.sh
    chmod +x gost.sh
    
    # 立即执行一次自启脚本，把服务跑起来
    bash gost.sh

    local lan_ip=$(get_lan_ip)
    
    # 输出客户端所需的信息
    echo "================================================"
    echo "安装完毕！Gost 代理已在后台运行。"
    echo "当前设备内网 IP : $lan_ip"
    echo "================================================"
    echo "【方案A】订阅链接 (适用于 Hiddify / V2ray)："
    if [[ "$lan_ip" == *"未检测"* ]]; then
        echo "提示: 请先连上 WiFi 后重新打开 Termux 获取订阅链接"
    else
        echo "http://$lan_ip:8080/sub.txt"
    fi
    echo "------------------------------------------------"
    echo "【方案B】Loon / Surge 节点配置语法 (手动复制)："
    echo "LAN_Socks5 = socks5, $lan_ip, $socks_port, fast-open=false, udp=true"
    echo "LAN_HTTP = http, $lan_ip, $http_port, fast-open=false, udp=true"
    echo "================================================"
    echo 
    echo "快捷方式：bash gv.sh  可重新查看信息或重置"
    echo "退出脚本运行：exit"
    sleep 2
    exit
}

uninstall(){
    screen -ls | grep Detached | cut -d. -f1 | awk '{print $1}' | xargs kill 2>/dev/null
    rm -rf gost config.yaml gv.sh sub_server /data/data/com.termux/files/usr/etc/profile.d/gost.sh
    echo "卸载完毕"
}

show_menu(){
    # 下载更新的逻辑保留
    curl -sSL https://raw.githubusercontent.com/yonggekkk/google_vpn_proxy/main/gv.sh -o gv.sh && chmod +x gv.sh
    clear
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
    echo "甬哥Github项目  ：github.com/yonggekkk"
    echo "甬哥Blogger博客 ：ygkkk.blogspot.com"
    echo "甬哥YouTube频道 ：www.youtube.com/@ygkkk"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
    echo "Google_VPN局域网共享代理：Socks5+Http双代理一键脚本"
    echo "快捷方式：bash gv.sh"
    echo "退出脚本运行：exit"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
    echo " 1. 重置安装 (并生成一键订阅配置)"
    echo " 2. 删除卸载"
    echo " 0. 退出"
    echo "------------------------------------------------"
    
    if [[ -e config.yaml ]]; then
        socks_port=$(grep -A 1 'name: service-socks5' config.yaml | grep 'addr' | awk -F':' '{print $3}' | tr -d '"')
        http_port=$(grep -A 1 'name: service-http' config.yaml | grep 'addr' | awk -F':' '{print $3}' | tr -d '"')
        lan_ip=$(get_lan_ip)
        echo "当前运行状态："
        echo "设备局域网 IP : $lan_ip"
        echo "Socks5 端口 : $socks_port"
        echo "Http 端口   : $http_port"
        if [[ "$lan_ip" != *"未检测"* ]]; then
            echo "当前订阅链接: http://$lan_ip:8080/sub.txt"
        fi
    else
        echo "未安装，请选择 1 进行安装"
    fi
    echo "------------------------------------------------"
    read -p "请输入数字:" Input
    case "$Input" in     
     1 ) gvinstall;;
     2 ) uninstall;;
     * ) exit 
    esac
}
show_menu
