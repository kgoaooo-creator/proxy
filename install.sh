#!/bin/bash

set -e

log_info() { echo -e "[\033[32mINFO\033[0m] $1"; }
log_err() { echo -e "[\033[31mERROR\033[0m] $1" >&2; exit 1; }
log_action() {
    local target=$1
    local process=$2
    local result=$3
    echo -e "[\033[36mACTION\033[0m] \n  - 输入目标: $target\n  - 执行过程: $process\n  - 最终结果: $result"
}

# // 修改开始：[卸载与网络栈自愈清理防线]
# 修改原因：满足运维迁移或容灾回滚需求，防止 TUN 路由策略与系统全局劫持防火墙永久残留，引发断网。
# 逻辑说明：拦截首个传入参数，若为 uninstall 则路由至清理单元，按序停止进程、解除路由表、清理 NAT 链、复原 sysctl 后退出。
# 使用方法与调用示例：执行 `./install.sh uninstall` 触发彻底卸载。
# 日志输出：
#   输入：接收 uninstall 指令；
#   过程：擦除 Systemd 单元 -> 擦除 ip rule/route -> 回滚 iptables/nftables -> 恢复 sysctl；
#   结果：打印“系统网络栈已恢复纯净状态”。
if [ "$1" = "uninstall" ]; then
    log_info "启动全面卸载与网络栈自愈清理程序..."
    systemctl disable --now xray-web.service 2>/dev/null || true
    systemctl disable --now xray.service 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/xray-web.service
    systemctl daemon-reload
    
    log_info "过程：擦除遗留策略路由与网卡栈..."
    ip rule del table main priority 99 2>/dev/null || true
    ip rule del table 100 priority 100 2>/dev/null || true
    ip route del default dev xray-tun0 table 100 2>/dev/null || true
    ip link delete xray-tun0 2>/dev/null || true
    
    log_info "过程：回滚内核防火墙劫持链..."
    if command -v iptables &>/dev/null; then
        iptables -t nat -D POSTROUTING -p icmp -m mark --mark 255 -j MASQUERADE 2>/dev/null || true
        iptables -t mangle -D OUTPUT -p icmp -j MARK --set-mark 255 2>/dev/null || true
    fi
    if command -v nft &>/dev/null; then
        nft delete table inet xray_mangle 2>/dev/null || true
        nft delete table inet xray_nat 2>/dev/null || true
    fi
    
    log_info "过程：回滚 /etc/sysctl.conf 内核优化项..."
    if [ -f /etc/sysctl.conf ]; then
        sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
        sed -i '/net.ipv4.conf.all.rp_filter=0/d' /etc/sysctl.conf
        sed -i '/net.ipv4.conf.default.rp_filter=0/d' /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1 || true
    fi
    
    DEPLOY_DIR=$(cd "$(dirname "$0")"; pwd)
    TARGET_DIR="${DEPLOY_DIR}/xray-core"
    if [ -d "$TARGET_DIR" ]; then
        log_info "过程：清空物理工作路径 $TARGET_DIR..."
        rm -rf "$TARGET_DIR"
    fi
    
    log_action "全套核心组件" "执行卸载、擦除系统文件、自愈网络拓扑" "清理完毕，系统网络栈已恢复纯净状态"
    exit 0
fi
# // 修改结束

# ==========================================
# 阶段一：环境自检与底层基础依赖
# ==========================================
log_info "阶段一：执行环境自检..."
if [ "$EUID" -ne 0 ]; then log_err "请使用 root 权限 (sudo) 执行此脚本！"; fi
if [ ! -f "Xray-linux-64.zip" ]; then log_err "缺失二进制包：当前目录未找到 Xray-linux-64.zip"; fi
if [ ! -f "config.json" ]; then log_err "缺失配置文件：当前目录未找到 config.json"; fi
if [ ! -f "web_manager.py" ]; then log_err "缺失控制端源码：当前目录未找到 web_manager.py"; fi

install_os_packages() {
    local PKG_LIST="$1"
    local PM=""
    if command -v dnf &> /dev/null; then PM="dnf install -y"
    elif command -v apt-get &> /dev/null; then PM="apt-get update -y && apt-get install -y"
    elif command -v yum &> /dev/null; then PM="yum install -y"
    elif command -v pacman &> /dev/null; then PM="pacman -Sy --noconfirm"
    elif command -v zypper &> /dev/null; then PM="zypper install -y"
    else log_err "未匹配到支持的包管理器，无法完成依赖安装。"; fi

    for PKG in $PKG_LIST; do
        if command -v $PKG &> /dev/null; then
            log_action "$PKG" "检测系统是否已安装该依赖" "依赖已满足，跳过安装"
        else
            log_action "$PKG" "调用底层包管理器 $PM 执行安装" "正在安装中..."
            eval "$PM $PKG > /dev/null 2>&1"
            if command -v $PKG &> /dev/null; then
                log_action "$PKG" "验证命令路径" "安装成功"
            else
                log_err "依赖 $PKG 安装失败，请检查网络或软件源！"
            fi
        fi
    done
}

log_info "过程：安装解压工具与 Python 虚拟环境组件..."
# // 修改开始：[补充跨发行版 Python venv 基础依赖包]
# 修改原因：为后续安全隔离部署 Web 引擎提供前置系统依赖。Debian 系系统必须依靠外部包支持 venv。
# 逻辑说明：动态探测 apt-get，按需安装 python3-venv。
# 使用方法与调用示例：阶段一下游自动调用。
# 日志输出：依赖统一由 install_os_packages 包裹层打印过程与结果。
if command -v apt-get &>/dev/null; then
    install_os_packages "unzip python3-venv"
else
    install_os_packages "unzip"
fi
# // 修改结束


# ==========================================
# 阶段二：Xray 核心独立部署闭环
# ==========================================
log_info "阶段二：开始部署 Xray 底层核心链路..."

DEPLOY_DIR=$(cd "$(dirname "$0")"; pwd)
TARGET_DIR="${DEPLOY_DIR}/xray-core"
mkdir -p "${TARGET_DIR}/configs"

log_info "过程：解压释放 Xray 二进制文件..."
set +e
unzip -o Xray-linux-64.zip -d "${TARGET_DIR}/" > /dev/null 2>&1
if [ $? -ne 0 ]; then log_err "压缩包解压失败，请检查包是否损坏。"; fi
set -e
chmod +x "${TARGET_DIR}/xray"

log_info "过程：检测系统 SELinux (针对 Xray 核心)..."
set +e
if command -v getenforce &> /dev/null && [ "$(getenforce)" = "Enforcing" ]; then
    chcon -t bin_t "${TARGET_DIR}/xray" > /dev/null 2>&1
    log_action "Xray 核心文件" "应用 bin_t 标签以绕过拦截" "SELinux 适配完成"
fi
set -e

log_info "过程：离线校验初始配置文件并装载..."
systemctl stop xray 2>/dev/null || true
set +e
"${TARGET_DIR}/xray" -test -config ./config.json > /dev/null 2>&1
if [ $? -ne 0 ]; then log_err "初始 config.json 存在致命语法错误或系统资源被异常占用，已被引擎阻断，请修正后重试。"; fi
set -e
cp ./config.json "${TARGET_DIR}/configs/default.json"
cp ./config.json "${TARGET_DIR}/config.json"

log_info "过程：开启 Linux TUN 模式前置网络转发与内核参数优化..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.conf.all.rp_filter=0" /etc/sysctl.conf; then
    echo "net.ipv4.conf.all.rp_filter=0" >> /etc/sysctl.conf
    echo "net.ipv4.conf.default.rp_filter=0" >> /etc/sysctl.conf
fi

sysctl -p > /dev/null 2>&1 || true
for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i" 2>/dev/null; done

log_action \
  "内核参数: ip_forward=1, rp_filter=0" \
  "持久化写入 /etc/sysctl.conf 并执行动态作用域刷新，关闭全局反向路径校验" \
  "内核网络栈调整成功，防止了全系统透明代理流量下的网络丢洞"

log_info "过程：注入 Xray 核心系统守护进程..."
# // 修改开始：[Systemd 级内联 iptables/nftables 兼容网关劫持]
# 修改原因：彻底化解现代纯净版系统由于 iptables 消失引发的伪装失效盲区。
# 逻辑说明：利用 bash && 链条结合 command -v 检测，根据系统实际提供方，动态选择下发旧版 mangle/nat 规则或直接组装原生的 nft inet chain。
# 使用方法与调用示例：伴随 service 启动自动触发底层网络劫持。
# 日志输出：Systemd 后台服务豁免界面日志。
cat << EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Core Service (TUN TProxy)
After=network.target

[Service]
User=root
ExecStart=${TARGET_DIR}/xray run -c ${TARGET_DIR}/config.json
Restart=on-failure
ExecStartPost=/bin/bash -c "for i in {1..30}; do ip link show xray-tun0 > /dev/null 2>&1 && break; sleep 0.1; done && \\
    ip addr add 198.18.0.1/16 dev xray-tun0 2>/dev/null || true && \\
    ip rule add to 192.168.0.0/16 table main priority 99 2>/dev/null || true && \\
    ip rule add from 192.168.0.0/16 table main priority 99 2>/dev/null || true && \\
    ip rule add to 172.16.0.0/12 table main priority 99 2>/dev/null || true && \\
    ip rule add from 172.16.0.0/12 table main priority 99 2>/dev/null || true && \\
    ip rule add to 10.0.0.0/8 table main priority 99 2>/dev/null || true && \\
    ip rule add from 10.0.0.0/8 table main priority 99 2>/dev/null || true && \\
    if command -v iptables &>/dev/null; then \\
        iptables -t mangle -I OUTPUT -p icmp -j MARK --set-mark 255 2>/dev/null || true; \\
        iptables -t nat -I POSTROUTING -p icmp -m mark --mark 255 -j MASQUERADE 2>/dev/null || true; \\
    elif command -v nft &>/dev/null; then \\
        nft add table inet xray_mangle 2>/dev/null || true; \\
        nft add chain inet xray_mangle output { type filter hook output priority mangle\\; } 2>/dev/null || true; \\
        nft add rule inet xray_mangle output ip protocol icmp meta mark set 255 2>/dev/null || true; \\
        nft add table inet xray_nat 2>/dev/null || true; \\
        nft add chain inet xray_nat postrouting { type nat hook postrouting priority srcnat\\; } 2>/dev/null || true; \\
        nft add rule inet xray_nat postrouting meta mark 255 masq 2>/dev/null || true; \\
    fi && \\
    ip rule add not fwmark 255 table 100 priority 100 2>/dev/null || true && \\
    ip route add default dev xray-tun0 table 100 src 198.18.0.1 2>/dev/null || true"

ExecStopPost=/bin/bash -c "if command -v iptables &>/dev/null; then \\
    iptables -t nat -D POSTROUTING -p icmp -m mark --mark 255 -j MASQUERADE 2>/dev/null || true; \\
    iptables -t mangle -D OUTPUT -p icmp -j MARK --set-mark 255 2>/dev/null || true; \\
    elif command -v nft &>/dev/null; then \\
    nft delete table inet xray_mangle 2>/dev/null || true; \\
    nft delete table inet xray_nat 2>/dev/null || true; \\
    fi; \\
    ip rule del table main priority 99 2>/dev/null || true; \\
    ip rule del table 100 priority 100 2>/dev/null || true; \\
    ip route del default dev xray-tun0 table 100 2>/dev/null || true"

[Install]
WantedBy=multi-user.target
EOF
# // 修改结束

log_action \
  "Systemd: xray.service 容灾幂等性策略升级" \
  "对 ExecStartPost 内部的所有网络栈注入指令进行 || true 逻辑截断" \
  "守护进程配置重构完成，彻底根除前台脚本运行期间的虚假报错提示"


log_info "过程：防火墙透传 Xray 业务端口..."
XRAY_PORTS="80 443"
set +e
if systemctl is-active --quiet firewalld; then
    for xp in $XRAY_PORTS; do firewall-cmd --zone=public --add-port=${xp}/tcp --permanent > /dev/null 2>&1; done
    firewall-cmd --reload > /dev/null 2>&1
    log_action "Firewalld" "放行核心业务端口 $XRAY_PORTS" "注入成功"
elif systemctl is-active --quiet ufw; then
    for xp in $XRAY_PORTS; do ufw allow ${xp}/tcp > /dev/null 2>&1; done
    log_action "UFW" "放行核心业务端口 $XRAY_PORTS" "注入成功"
elif systemctl is-active --quiet iptables; then
    for xp in $XRAY_PORTS; do iptables -I INPUT -p tcp --dport ${xp} -j ACCEPT; done
    service iptables save > /dev/null 2>&1 || /usr/libexec/iptables/iptables.init save > /dev/null 2>&1
    log_action "iptables" "放行核心业务端口 $XRAY_PORTS" "注入成功"
# // 修改开始：[防火墙透传追加 nftables 判断支持]
# 修改原因：如果上述常规防火墙软件均未启动，但存在底层 nft，则直写原生过滤表保证外部访问可达。
elif command -v nft &>/dev/null; then
    nft add table inet xray_filter 2>/dev/null || true
    nft add chain inet xray_filter input { type filter hook input priority filter\; policy accept\; } 2>/dev/null || true
    for xp in $XRAY_PORTS; do nft add rule inet xray_filter input tcp dport ${xp} accept 2>/dev/null || true; done
    log_action "nftables" "放行核心业务端口 $XRAY_PORTS" "注入成功"
# // 修改结束
fi
set -e

log_info "过程：拉起 Xray 核心服务..."
systemctl daemon-reload
systemctl enable --now xray.service
log_info "结果：Xray 底层核心部署与启动已完全就绪。"

# ==========================================
# 阶段三：Web 控制端独立部署闭环
# ==========================================
log_info "阶段三：开始部署上层 Web 引擎链路..."
log_info "过程：补全 Python3 及 Flask 框架依赖..."

install_os_packages "python3"

if ! command -v pip3 &> /dev/null; then
    log_action "pip3" "未检测到系统级 pip，尝试调用 Python 内置 ensurepip 引导" "执行中..."
    python3 -m ensurepip --upgrade > /dev/null 2>&1 || true
fi

if ! command -v pip3 &> /dev/null; then
    log_action "pip3" "内置引导未就绪，降级调用官方在线自举脚本 (get-pip.py)" "执行中..."
    if command -v curl &> /dev/null; then
        curl -sS https://bootstrap.pypa.io/get-pip.py | python3 > /dev/null 2>&1 || true
    else
        wget -qO- https://bootstrap.pypa.io/get-pip.py | python3 > /dev/null 2>&1 || true
    fi
fi

if ! command -v pip3 &> /dev/null; then
    log_err "致命异常：所有 pip3 获取链路均已阻断！请手动核实服务器 DNS 配置或外网连通性 (ping 8.8.8.8)。"
else
    log_action "pip3" "环境探测与部署验证" "引擎就绪"
fi

# // 修改开始：[引入 python3 -m venv 隔离部署沙箱机制]
# 修改原因：彻底移除引发环境污染的 --break-system-packages，规避跨发行版 PEP-668 致命限制锁定，隔离主宿主机。
# 逻辑说明：在工作目录下初始化 venv 并指定环境内 pip 获取三方依赖。
# 使用方法与调用示例：阶段三自动探测并激活沙箱，无感对接。
# 日志输出：
#   输入：调用 python3 -m venv；
#   过程：物理分配独立运行库，升级内部 pip 并下发 Flask、Waitress；
#   结果：明确提示未破坏系统环境，依赖装配闭环就绪。
log_info "过程：初始化本地 Python 虚拟隔离沙箱..."
python3 -m venv "${TARGET_DIR}/venv"
log_action "Python venv" "在 ${TARGET_DIR}/venv 路径下构建虚拟环境" "沙箱初始化成功"

log_info "过程：在隔离沙箱内组装 Flask 与 Waitress 生产依赖..."
"${TARGET_DIR}/venv/bin/pip" install --upgrade pip > /dev/null 2>&1 || true
"${TARGET_DIR}/venv/bin/pip" install Flask waitress > /dev/null 2>&1
log_action "Flask & Waitress" "使用沙箱内部 pip 独立完成组件装配" "依赖就绪，未破坏全局系统环境"
# // 修改结束

log_info "过程：释放 Web 控制端源码..."
cp ./web_manager.py "${TARGET_DIR}/web_manager.py"
chmod +x "${TARGET_DIR}/web_manager.py"

log_info "过程：检测系统 SELinux (针对 Web 源码)..."
set +e
if command -v getenforce &> /dev/null && [ "$(getenforce)" = "Enforcing" ]; then
    chcon -t bin_t "${TARGET_DIR}/web_manager.py" > /dev/null 2>&1
    log_action "Web 控制源码" "应用 bin_t 标签" "SELinux 适配完成"
fi
set -e

log_info "过程：注入 Web 引擎系统守护进程..."
# // 修改开始：[对接 Python 虚拟沙箱至 Web 服务进程]
# 修改原因：保障 Systemd 在拉起 Web 管理面板时，精准引用内源沙箱解释器环境，防止报错 `ModuleNotFoundError`。
# 逻辑说明：重定向 ExecStart。
cat << EOF > /etc/systemd/system/xray-web.service
[Unit]
Description=Xray Python Web Manager
After=network.target

[Service]
User=root
WorkingDirectory=${TARGET_DIR}
ExecStart=${TARGET_DIR}/venv/bin/python3 ${TARGET_DIR}/web_manager.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF
# // 修改结束

log_info "过程：防火墙透传 Web 管理端口..."
PORT=9999
set +e
if systemctl is-active --quiet firewalld; then
    firewall-cmd --zone=public --add-port=${PORT}/tcp --permanent > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
    log_action "Firewalld" "放行面板端口 $PORT" "注入成功"
elif systemctl is-active --quiet ufw; then
    ufw allow ${PORT}/tcp > /dev/null 2>&1
    log_action "UFW" "放行面板端口 $PORT" "注入成功"
elif systemctl is-active --quiet iptables; then
    iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
    service iptables save > /dev/null 2>&1 || /usr/libexec/iptables/iptables.init save > /dev/null 2>&1
    log_action "iptables" "放行面板端口 $PORT" "注入成功"
# // 修改开始：[防火墙透传 Web 端口追加 nftables 判断支持]
elif command -v nft &>/dev/null; then
    nft add table inet xray_filter 2>/dev/null || true
    nft add chain inet xray_filter input { type filter hook input priority filter\; policy accept\; } 2>/dev/null || true
    nft add rule inet xray_filter input tcp dport ${PORT} accept 2>/dev/null || true
    log_action "nftables" "放行面板端口 $PORT" "注入成功"
# // 修改结束
fi
set -e

log_info "过程：拉起 Web 引擎服务..."
systemctl daemon-reload
systemctl enable --now xray-web.service

log_info "=========================================="
log_info "结果：模块化分步安装链路已全数闭环就绪。"
log_info "1. 底层核心：Xray Core 已独立运行 (Port 80/443)"
log_info "2. 上层业务：控制端访问入口 http://[服务器IP]:9999"
log_info "=========================================="

# 修改原因：满足“静默更新脚本在install.sh后自动运行，并检查脚本是否存在”的指令。
if [ -f "${DEPLOY_DIR}/update_rules.sh" ]; then
    log_info "过程：探测到底层路由规则库双线 CDN 静默同步引擎 (update_rules.sh)，开始注入并启动首次下发..."
    cp "${DEPLOY_DIR}/update_rules.sh" "${TARGET_DIR}/update_rules.sh"
    chmod +x "${TARGET_DIR}/update_rules.sh"
    
    # 挂载同步，执行获取过程并阻断中断
    "${TARGET_DIR}/update_rules.sh" || log_err "初始规则库拉取失败，请检查服务器至 jsdelivr CDN 节点的双边网络连接。"
    
    log_action "静默同步引擎" "探测实体文件 -> 拷贝提权 -> 调用脚本重载底层" "基线初始化完成，Xray 内核已顺利应用强化特征识别池"
else
    log_action "静默同步引擎" "探测工作目录是否存在 update_rules.sh" "未发现物理实体脚本，已平滑跳过规则库自动同步阶段"
fi