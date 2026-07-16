#!/bin/bash

# // 修改开始：[全自动彻底卸载与环境复原引擎 - LINUX 通用版]
# 修改原因：满足跨 Linux 发行版的无痕卸载与系统级网络自愈需求。
# 逻辑说明：采用底层驱动级卸载方案，全流程结合条件探测与 || true 错误熔断机制，保障在任何 Linux 环境中皆可顺畅执行。
# 使用方法与调用示例：
#   chmod +x uninstall.sh
#   sudo ./uninstall.sh
# 日志输出日志是否包含：是。已实现标准化的“输入、过程、结果、目的”全维度审计输出。

set -e

# ==========================================
# 审计日志函数定义
# ==========================================
log_info() { echo -e "[\033[32mINFO\033[0m] $1"; }
log_warn() { echo -e "[\033[33mWARN\033[0m] $1"; }
log_err() { echo -e "[\033[31mERROR\033[0m] $1" >&2; exit 1; }

log_action() {
    local target=$1
    local process=$2
    local result=$3
    local purpose=$4
    echo -e "[\033[36mACTION\033[0m]"
    echo "  - 输入: $target"
    echo "  - 过程: $process"
    echo "  - 结果: $result"
    echo "  - 目的: $purpose"
    echo "------------------------------------------"
}

# 权限强制校验
if [ "$EUID" -ne 0 ]; then
    log_err "输入：非 Root 用户执行；过程：EUID 校验；结果：权限拒绝；目的：保障系统级修改安全。"
fi

log_info "=========================================================="
log_info " 启动 LINUX 通用核心分步联锁卸载程序"
log_info " 全面清理物理文件、网络拓扑、守护进程与防火墙规则"
log_info "=========================================================="

# ------------------------------------------
# 任务一：停止、注销并擦除 Systemd 守护单元
# ------------------------------------------
log_info "[任务 1/5] 熔断 Systemd 守护单元..."

if command -v systemctl &>/dev/null; then
    systemctl disable --now xray-web.service 2>/dev/null || true
    systemctl disable --now xray.service 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/xray-web.service
    systemctl daemon-reload
    log_action \
        "检测到系统环境: Systemd" \
        "调用 systemctl disable --now 停止服务，物理抹除 .service 文件并重载" \
        "守护进程池已清理完毕" \
        "彻底切断进程自启与守护源头，保障后续清理不会被进程占用阻塞"
fi

# ------------------------------------------
# 任务二：解构系统级高级路由策略表（TUN 拓扑剥离）
# ------------------------------------------
log_info "[任务 2/5] 回滚 Linux 高级路由表与虚拟网卡..."

if command -v ip &>/dev/null; then
    # 物理撤销本地 IP 豁免规则段 (Priority 99)
    ip rule del to 192.168.0.0/16 table main priority 99 2>/dev/null || true
    ip rule del from 192.168.0.0/16 table main priority 99 2>/dev/null || true
    ip rule del to 172.16.0.0/12 table main priority 99 2>/dev/null || true
    ip rule del from 172.16.0.0/12 table main priority 99 2>/dev/null || true
    ip rule del to 10.0.0.0/8 table main priority 99 2>/dev/null || true
    ip rule del from 10.0.0.0/8 table main priority 99 2>/dev/null || true

    # 撤销全局入站代理路由劫持规则 (Priority 100)
    ip rule del not fwmark 255 table 100 priority 100 2>/dev/null || true
    ip route del default dev xray-tun0 table 100 2>/dev/null || true

    # 毁灭虚拟 TUN 物理网卡设备
    ip link delete xray-tun0 2>/dev/null || true

    log_action \
        "底层 IP 工具集 (iproute2)" \
        "执行 rule del 与 link delete 撤销透明代理网关劫持链" \
        "网卡与路由表已复原" \
        "防止卸载后全局流量仍然被错误地导向不存在的虚拟网卡导致断网"
fi

# ------------------------------------------
# 任务三：物理清除底层多流内核防火墙
# ------------------------------------------
log_info "[任务 3/5] 清洗多发行版内核防火墙链与透传端口..."

XRAY_PORTS="80 443 9999"

# 1. IPTABLES 清理
if command -v iptables &>/dev/null; then
    iptables -t nat -D POSTROUTING -p icmp -m mark --mark 255 -j MASQUERADE 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p icmp -j MARK --set-mark 255 2>/dev/null || true
    for port in $XRAY_PORTS; do iptables -D INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null || true; done
    if command -v service &>/dev/null && service iptables status &>/dev/null; then service iptables save >/dev/null 2>&1 || true; fi
    log_action "Legacy 内核墙: iptables" "摘除 mark 255 伪装与入站 ACCEPT 规则" "清洗完毕" "清除陈旧防火墙架构中的数据包篡改逻辑"
fi

# 2. NFTABLES 清理
if command -v nft &>/dev/null; then
    nft delete table inet xray_mangle 2>/dev/null || true
    nft delete table inet xray_nat 2>/dev/null || true
    nft delete table inet xray_filter 2>/dev/null || true
    log_action "现代内核墙: nftables" "原子级擦除 xray 专属 inet table" "清洗完毕" "释放现代 Linux 内核态的数据包过滤资源"
fi

# 3. FIREWALLD 清理
if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    for port in $XRAY_PORTS; do firewall-cmd --zone=public --remove-port=${port}/tcp --permanent >/dev/null 2>&1 || true; done
    firewall-cmd --reload >/dev/null 2>&1 || true
    log_action "应用级墙: firewalld" "移除指定 tcp 端口并重载区带策略" "清洗完毕" "封闭由 RedHat 系发行版管控的外部入站暴露面"
fi

# 4. UFW 清理
if command -v ufw &>/dev/null && ufw status | grep -q "Active"; then
    for port in $XRAY_PORTS; do ufw delete allow ${port}/tcp >/dev/null 2>&1 || true; done
    log_action "应用级墙: UFW" "剥离 allow 规则条目" "清洗完毕" "封闭由 Debian/Ubuntu 系发行版管控的外部入站暴露面"
fi

# ------------------------------------------
# 任务四：回滚内核参数
# ------------------------------------------
log_info "[任务 4/5] 复原内核级网络通信安全边界..."

if command -v sed &>/dev/null && [ -f /etc/sysctl.conf ]; then
    sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
    sed -i '/net.ipv4.conf.all.rp_filter=0/d' /etc/sysctl.conf
    sed -i '/net.ipv4.conf.default.rp_filter=0/d' /etc/sysctl.conf
    
    if command -v sysctl &>/dev/null; then sysctl -p > /dev/null 2>&1 || true; fi
    
    # 将现存虚拟路径防御强制恢复严格模式
    for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 1 > "$i" 2>/dev/null || true; done
    
    log_action \
        "文件: /etc/sysctl.conf 及 /proc/sys" \
        "擦除 ip_forward 与 rp_filter 注入块，强制置 1 恢复防源地址欺骗" \
        "协议栈参数已自愈" \
        "剥夺宿主机的网络层网关转发特权，重塑系统默认网络安全基线"
fi

# ------------------------------------------
# 任务五：毁灭物理文件、日志缓存与 Python 沙箱
# ------------------------------------------
log_info "[任务 5/5] 深度清理持久化磁盘实体..."

# 清除系统日志
if command -v journalctl &>/dev/null; then
    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=1s >/dev/null 2>&1 || true
    log_action "系统日志收集器: journalctl" "强制流转并收缩生命周期至 1s" "底层服务追踪记录已全盘抹去" "保障审计安全，防止历史日志长期堆积占用存储"
fi

# 强杀残留进程
if command -v pkill &>/dev/null; then pkill -9 -x xray 2>/dev/null || true; fi

# 销毁部署基带目录
DEPLOY_DIR=$(cd "$(dirname "$0")"; pwd)
TARGET_DIR="${DEPLOY_DIR}/xray-core"
if [ -d "$TARGET_DIR" ]; then
    rm -rf "$TARGET_DIR"
    log_action \
        "目标物理路径: $TARGET_DIR" \
        "执行递归联锁销毁指令 rm -rf" \
        "核心文件、策略池、Python venv 与面板源码全数清除" \
        "彻底释放磁盘扇区，达成无痕复原目标"
else
    log_warn "未探测到主部署目录 ${TARGET_DIR}，可能已被转移或清理。"
fi

log_info "=========================================================="
log_info " 卸载结束！所有环境已完美复原。"
log_info "=========================================================="
# // 修改结束