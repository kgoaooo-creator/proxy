#!/bin/sh
# ====================================================================
# OPWE (OpenWrt) Xray TProxy 通用自动化卸载/清理脚本
# ====================================================================

set -e

log_info() { printf "[\033[32mINFO\033[0m] %s\n" "$1"; }
log_warn() { printf "[\033[33mWARN\033[0m] %s\n" "$1"; }

# -----------------------------------------------------------
# [初始化] 工作目录智能探测
# -----------------------------------------------------------
log_info "【日志】输入：无外部参数输入"
log_info "【日志】过程：尝试从 Procd 守护脚本中提取原始安装路径..."

WORK_DIR=""
if [ -f "/etc/init.d/xray" ]; then
    WORK_DIR=$(grep 'ASSET_DIR=' /etc/init.d/xray | cut -d'"' -f2 || true)
fi
if [ -z "$WORK_DIR" ]; then
    WORK_DIR=$(cd "$(dirname "$0")"; pwd)
fi

log_info "【日志】结果：已锁定目标清理路径为 $WORK_DIR"
log_info "【日志】目的：确保精准定位并清理安装时释放的文件，提升通用性。"

# -----------------------------------------------------------
# [步骤一] 停止核心进程
# -----------------------------------------------------------
log_info "【日志】输入：目标服务 xray"
log_info "【日志】过程：解除自启动并终止后台常驻进程..."
if [ -f "/etc/init.d/xray" ]; then
    /etc/init.d/xray disable 2>/dev/null || true
    /etc/init.d/xray stop 2>/dev/null || true
fi
killall xray 2>/dev/null || true
log_info "【日志】结果：核心进程已完全停止。"
log_info "【日志】目的：防止运行中的进程占用文件描述符或产生网路环路死锁。"






# -----------------------------------------------------------
# [步骤二] 恢复系统 DNS 解析
# -----------------------------------------------------------
log_info "【日志】过程：清理 Dnsmasq 中的 5354 端口劫持记录，恢复默认解析..."
uci del_list dhcp.@dnsmasq[0].server='127.0.0.1#5354' 2>/dev/null || true
uci set dhcp.@dnsmasq[0].noresolv='0' 2>/dev/null || true
uci commit dhcp
/etc/init.d/dnsmasq restart || true
log_info "【日志】结果：Dnsmasq 配置已复原并热重启。"
log_info "【日志】目的：避免因代理层拆除后导致局域网设备发生 DNS 闪断或永久解析失败。"

# -----------------------------------------------------------
# [步骤三] 清理底层策略路由
# -----------------------------------------------------------
log_info "【日志】过程：探查并移除 iproute2 策略路由表 (table 100)..."
IP_BIN_PATH=""
for path in /sbin/ip /usr/sbin/ip /bin/ip /usr/bin/ip; do
    if [ -x "$path" ]; then IP_BIN_PATH="$path"; break; fi
done
[ -z "$IP_BIN_PATH" ] && IP_BIN_PATH="ip"

$IP_BIN_PATH rule del fwmark 1 table 100 2>/dev/null || true
$IP_BIN_PATH route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
log_info "【日志】结果：底层 fwmark 1 流量劫持路由已切断。"
log_info "【日志】目的：释放底层网络栈，恢复物理网口的标准路由直通状态。"

# -----------------------------------------------------------
# [步骤四] 防火墙劫持链差异化清理 (fw3/fw4)
# -----------------------------------------------------------
FW_VER="fw3"
if grep -q "option fw4" /etc/config/firewall 2>/dev/null || command -v fw4 >/dev/null 2>&1; then
    FW_VER="fw4"
fi

log_info "【日志】输入：探测到当前防火墙版本为 $FW_VER"
log_info "【日志】过程：根据防火墙版本执行相应的规则链擦除操作..."

if [ "$FW_VER" = "fw4" ]; then
    # 清理 fw4 (nftables) 配置
    uci show firewall 2>/dev/null | grep "xray_tproxy" | cut -d= -f1 | cut -d. -f1-2 | sort -u | while read section; do
        uci -q delete "$section"
    done || true
    uci commit firewall
    fw4 reload >/dev/null 2>&1 || true
else
    # 清理 fw3 (iptables) 配置与运行时内存规则
    iptables -t mangle -D PREROUTING -i lo -m mark ! --mark 1 -j RETURN 2>/dev/null || true
    iptables -t mangle -D PREROUTING -i br-lan -j XRAY_TPROXY 2>/dev/null || true
    iptables -t mangle -D PREROUTING -i lo -j XRAY_TPROXY 2>/dev/null || true
    iptables -t mangle -D OUTPUT -j XRAY_OUTPUT 2>/dev/null || true
    
    iptables -t nat -D PREROUTING -i br-lan -p udp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null || true
    iptables -t nat -D PREROUTING -i br-lan -p tcp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null || true
    
    iptables -t mangle -F XRAY_TPROXY 2>/dev/null || true
    iptables -t mangle -X XRAY_TPROXY 2>/dev/null || true
    iptables -t mangle -F XRAY_OUTPUT 2>/dev/null || true
    iptables -t mangle -X XRAY_OUTPUT 2>/dev/null || true
    
    sed -i '/# xray_tproxy_start/,/# xray_tproxy_end/d' /etc/firewall.user 2>/dev/null || true
    fw3 reload >/dev/null 2>&1 || true
fi
log_info "【日志】结果：TProxy 透明代理防火墙规则链 ($FW_VER) 已完全擦除并生效。"
log_info "【日志】目的：消除 iptables/nftables 中的冗余过滤负担，恢复原生防火墙形态。"

# -----------------------------------------------------------
# [步骤五] 物理残留文件销毁
# -----------------------------------------------------------
log_info "【日志】过程：执行最终磁盘文件清扫作业..."
rm -f /etc/init.d/xray
rm -f "$WORK_DIR/xray"
rm -f "$WORK_DIR/route_up.sh"
rm -f "$WORK_DIR/xray-tproxy.nft"
# 注：特意保留了 config.json, geoip.dat, geosite.dat 防止误删用户重要配置资产

log_info "【日志】结果：执行文件、脚本环境与守护进程注入文件均已销毁（已保留用户数据文件 config.json/dat）。"
log_info "【日志】目的：实现绿色卸载，同时保护用户资产。"

log_info "=========================================================="
log_info " 🎉 OpenWrt TProxy 核心环境已完全卸载！网络已恢复直连直通。"
log_info "=========================================================="


/etc/init.d/cron restart
sed -i '/open-update-rules.sh/d' /etc/crontabs/root
log_info "自动定位并删除包含 open-update-rules.sh 的那一行任务"


/etc/init.d/cron restart
log_info "重启 cron 服务，使剔除操作即刻在内存中生效"
log_info "输出定时任何"
cat /etc/crontabs/root

exit 0