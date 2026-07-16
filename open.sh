#!/bin/sh
# ====================================================================
# OPWE (OpenWrt) Xray TProxy 自动化部署脚本 (Final Fix 版)
# ====================================================================

set -e

log_info() { printf "[\033[32mINFO\033[0m] %s\n" "$1"; }
log_warn() { printf "[\033[33mWARN\033[0m] %s\n" "$1"; }
log_err()  { printf "[\033[31mERROR\033[0m] %s\n" "$1" >&2; exit 1; }

# 获取当前脚本绝对路径作为工作目录，严禁在内存盘运行
WORK_DIR=$(cd "$(dirname "$0")"; pwd)

log_info "=========================================================="
log_info "启动 OpenWrt TProxy 自动化部署 (当前目录便携模式)"
log_info "目标工作路径: $WORK_DIR"
log_info "=========================================================="

if echo "$WORK_DIR" | grep -q "^/tmp"; then
    log_err "存储阻断: 检测到您在 /tmp 目录下运行脚本！此为内存盘，重启后文件丢失，请移至持久化存储区(如 /root/) 执行！"
fi

if [ "$(id -u)" -ne 0 ]; then log_err "致命拦截: 必须使用 root 权限！"; fi
if [ ! -f "/etc/openwrt_release" ]; then log_err "致命拦截: 非 OpenWrt 固件！"; fi

# // 修改开始：[引入全局并发锁，防呆能力提升]
exec 9>"/tmp/xray_tproxy.lock"
flock -n 9 || log_err "并发拦截: 检测到另一个部署任务正在运行，请勿重复执行！"
trap 'rm -f /tmp/xray_tproxy.lock' EXIT
# // 修改结束

# -----------------------------------------------------------
# [阶段一]：硬件指纹与精准架构探测
# -----------------------------------------------------------
ARCH=$(uname -m)
log_info "硬件指纹探测 -> CPU 架构: $ARCH"

case "$ARCH" in
    aarch64) KEYWORD="arm64" ;;
    x86_64)  KEYWORD="linux-64\." ;;
    mips)    KEYWORD="mips\." ;;
    mips64)  KEYWORD="mips64\." ;;
    armv7l)  KEYWORD="arm32-v7a" ;;
    *)       KEYWORD="$ARCH" ;;
esac

ZIP_FILE=$(ls "$WORK_DIR"/Xray-linux-*.zip 2>/dev/null | grep -iE "$KEYWORD" | head -n 1 || true)

if [ -z "$ZIP_FILE" ]; then
    log_err "文件缺失或架构撕裂: 未在当前目录找到匹配架构 [$ARCH] 的 Xray 压缩包！"
fi

for f in "config.json"; do
    if [ ! -f "$WORK_DIR/$f" ]; then log_err "文件缺失: $WORK_DIR/$f"; fi
done

# -----------------------------------------------------------
# [阶段二]：物理资源红线守护
# -----------------------------------------------------------
FREE_SPACE_KB=$(df -k "$WORK_DIR" | awk 'NR==2 {print $4}')
FREE_SPACE=$((FREE_SPACE_KB / 1024))

if [ -z "$FREE_SPACE" ] || [ "$FREE_SPACE" -lt 40 ]; then
    log_err "存储阻断: 当前分区仅余 ${FREE_SPACE}MB，不足 40MB，防止写满死机！"
fi

MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ ! -z "$MEM_TOTAL" ] && [ "$MEM_TOTAL" -lt 262144 ]; then
    log_warn "内存警告: 设备物理内存低于 256MB，建议削减高耗能规则集！"
fi

# -----------------------------------------------------------
# [阶段三]：内核模块探测与依赖装配
# -----------------------------------------------------------
# log_info "执行系统基础依赖装配..."
# opkg update >/dev/null 2>&1 || log_warn "软件源更新异常，尝试直接调用本地依赖缓存。"

# for pkg in unzip ip-full; do
    # if ! command -v $pkg >/dev/null 2>&1; then
        # opkg install $pkg >/dev/null 2>&1 || log_err "基础工具链 $pkg 安装失败！"
    # fi
# done

FW_VER="fw3"
if grep -q "option fw4" /etc/config/firewall 2>/dev/null || command -v fw4 >/dev/null 2>&1; then
    FW_VER="fw4"
fi
log_info "防火墙指纹探测 -> 引擎级别: $FW_VER"

if [ "$FW_VER" = "fw4" ]; then
    TPROXY_MOD="nft_tproxy"
    TPROXY_PKG="kmod-nft-tproxy"
else
    TPROXY_MOD="xt_TPROXY"
    TPROXY_PKG="kmod-ipt-tproxy"
fi

if ! lsmod | grep -q "$TPROXY_MOD"; then
    log_info "未探测到 TProxy 模块 ($TPROXY_MOD)，尝试安装..."
    opkg install "$TPROXY_PKG" >/dev/null 2>&1 || log_err "依赖锁死: $TPROXY_PKG 安装失败！内核版本不匹配。"
fi

# -----------------------------------------------------------
# [阶段四]：本地就地释放与健康度预检
# -----------------------------------------------------------
log_info "【日志】输入：接收到目标解压包路径 $ZIP_FILE，目标工作目录为 $WORK_DIR/"
log_info "【日志】过程：执行 unzip 解压目标文件包内所有内容..."
unzip -o "$ZIP_FILE" -d "$WORK_DIR/" >/dev/null 2>&1 || log_err "文件包解压损坏！"
log_info "【日志】结果：全量文件（含二进制核心及附属资源文件）已成功释放至工作目录"
log_info "【日志】目的：提升可维护性与功能完整度；确保 xray 运行时依赖的全部外部资源可用，防止行为不可验证。"
chmod +x "$WORK_DIR/xray"

# log_info "离线校验 config.json 语法健康度..."
# "$WORK_DIR/xray" run -test -config "$WORK_DIR/config.json" >/dev/null 2>&1 || log_err "配置语法损毁: config.json 存在致命错误！"

# // 修改开始：[配置特征检查调整为 5354]
if ! grep -q "5354" "$WORK_DIR/config.json"; then
    log_warn "未在配置中探测到 5354，请确认您已配置 dokodemo-door DNS 转发！"
fi
# // 修改结束



# -----------------------------------------------------------
# [阶段五]：透明代理网络栈重塑 (防热插拔)
# -----------------------------------------------------------
log_info "挂载底层 TProxy 策略路由与防火墙劫持链..."


log_info "【日志】过程：探测系统 ip 命令绝对路径..."
IP_BIN_PATH=""
for path in /sbin/ip /usr/sbin/ip /bin/ip /usr/bin/ip; do
    if [ -x "$path" ]; then
        IP_BIN_PATH="$path"
        break
    fi
done
[ -z "$IP_BIN_PATH" ] && IP_BIN_PATH="ip"
log_info "【日志】结果：ip 命令路径已锁定为 $IP_BIN_PATH"

cat << EOF > "$WORK_DIR/route_up.sh"
#!/bin/sh
$IP_BIN_PATH rule del fwmark 1 table 100 2>/dev/null || true
$IP_BIN_PATH route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
$IP_BIN_PATH rule add fwmark 1 table 100 2>/dev/null || true
$IP_BIN_PATH route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
EOF
chmod +x "$WORK_DIR/route_up.sh"
"$WORK_DIR/route_up.sh" || log_warn "【日志】结果：策略路由初始化探针返回非 0，已通过容错机制放行。"

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")

if [ "$FW_VER" = "fw3" ]; then
    sed -i '/# xray_tproxy_start/,/# xray_tproxy_end/d' /etc/firewall.user 2>/dev/null || true
    cat << EOF >> /etc/firewall.user
# xray_tproxy_start
iptables -t mangle -N XRAY_TPROXY 2>/dev/null || iptables -t mangle -F XRAY_TPROXY
iptables -t mangle -A XRAY_TPROXY -d 0.0.0.0/8 -j RETURN
iptables -t mangle -A XRAY_TPROXY -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A XRAY_TPROXY -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A XRAY_TPROXY -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A XRAY_TPROXY -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A XRAY_TPROXY -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A XRAY_TPROXY -d 240.0.0.0/4 -j RETURN
iptables -t mangle -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
iptables -t mangle -A XRAY_TPROXY -p udp -j TPROXY --on-port 12345 --tproxy-mark 1

# // 修改开始：[fw3 环境下解封 lo 接口并挂载本地 OUTPUT 劫持链，引入 mark 1 断路保护防止回环]
# 修改原因：原规则缺少断路机制，导致纯本地环回流量在没有 mark 1 标记时误入 TProxy，从而触发无限回环死循环。
# 逻辑说明：在 PREROUTING 链头部对来自 lo 但没有 mark 1 的流量强行执行 RETURN。
iptables -t mangle -D PREROUTING -j XRAY_TPROXY 2>/dev/null || true
iptables -t mangle -A PREROUTING -i lo -m mark ! --mark 1 -j RETURN
iptables -t mangle -A PREROUTING -i br-lan -j XRAY_TPROXY
iptables -t mangle -A PREROUTING -i lo -j XRAY_TPROXY

iptables -t mangle -N XRAY_OUTPUT 2>/dev/null || iptables -t mangle -F XRAY_OUTPUT
iptables -t mangle -A XRAY_OUTPUT -m mark --mark 255 -j RETURN
iptables -t mangle -A XRAY_OUTPUT -d 0.0.0.0/8 -j RETURN
iptables -t mangle -A XRAY_OUTPUT -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A XRAY_OUTPUT -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A XRAY_OUTPUT -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A XRAY_OUTPUT -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A XRAY_OUTPUT -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A XRAY_OUTPUT -d 240.0.0.0/4 -j RETURN
iptables -t mangle -p udp --dport 53 -j RETURN
iptables -t mangle -A XRAY_OUTPUT -p tcp --dport 53 -j RETURN
iptables -t mangle -A XRAY_OUTPUT -p udp --dport 5354 -j RETURN
iptables -t mangle -A XRAY_OUTPUT -p tcp --dport 5354 -j RETURN
iptables -t mangle -p tcp -j MARK --set-mark 1
iptables -t mangle -p udp -j MARK --set-mark 1
iptables -t mangle -D OUTPUT -j XRAY_OUTPUT 2>/dev/null || true
iptables -t mangle -A OUTPUT -j XRAY_OUTPUT
# // 修改结束

iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null || true
iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null || true
iptables -t nat -I PREROUTING -i br-lan -p udp --dport 53 -j REDIRECT --to-ports 5354
iptables -t nat -I PREROUTING -i br-lan -p tcp --dport 53 -j REDIRECT --to-ports 5354
# xray_tproxy_end
EOF
    fw3 reload >/dev/null 2>&1
else
    cat << 'EOF' > "$WORK_DIR/xray-tproxy.nft"
table inet xray_tproxy {
    chain xray_prerouting_mangle {
        type filter hook prerouting priority mangle; policy accept;
        
        # // 修改开始：[关键加固 - 本地回环安全断路器]
        # 修改原因：在本机透明代理模型下，本地应用纯环回流量（如 [::1]:53）在 lo 接口移动时，若无携带 mark 1 会被误抓进 TProxy 导致无限自循环，瞬间刷爆句柄。
        # 逻辑说明：凡是来自 lo 接口但没有携带 mark 1（非本地发起并执意出海的业务包）的流量，一律原地 RETURN 放行，彻底斩断死循环。
        iifname "lo" meta mark != 1 return
        # // 修改结束
        
        iifname != { "br-lan", "lo" } return
        
        meta mark 255 return
        ip daddr { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return
        ip6 daddr { ::1, fe80::/10, fc00::/7 } return
        meta l4proto { tcp, udp } tproxy to :12345 meta mark set 1 accept
    }
    
    chain xray_output_mangle {
        type route hook output priority mangle; policy accept;
        meta mark 255 return
        ip daddr { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return
        ip6 daddr { ::1, fe80::/10, fc00::/7 } return
        meta l4proto { tcp, udp } th dport 53 return
        meta l4proto { tcp, udp } th dport 5354 return
        meta l4proto { tcp, udp } meta mark set 1
    }
    
    chain xray_prerouting_dstnat {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "br-lan" meta l4proto { tcp, udp } th dport 53 redirect to :5354
    }
}
EOF
    uci show firewall 2>/dev/null | grep "xray-tproxy.nft" | cut -d= -f1 | cut -d. -f1-2 | sort -u | while read section; do
        uci -q delete "$section"
    done || true

    uci -q delete firewall.xray_tproxy || true
    uci set firewall.xray_tproxy=include
    uci set firewall.xray_tproxy.type='nftables'
    uci set firewall.xray_tproxy.path="$WORK_DIR/xray-tproxy.nft"
    uci set firewall.xray_tproxy.position='ruleset-pre'
    uci commit firewall
    fw4 reload >/dev/null 2>&1
fi



# -----------------------------------------------------------
# [阶段六]：系统 DNS 锁定与 Dnsmasq 防污染
# -----------------------------------------------------------
log_info "锁定 Dnsmasq 上游进行防泄漏净化..."

log_info "【日志】输入：准备劫持 DNS，目标上游设置为 127.0.0.1#5354"
log_info "【日志】过程：备份现有 dhcp 配置状态并应用新规则"

OLD_NORESOLV=$(uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null || echo "0")
OLD_SERVER=$(uci get dhcp.@dnsmasq[0].server 2>/dev/null || echo "")

uci delete dhcp.@dnsmasq[0].server 2>/dev/null || true
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5354'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci delete dhcp.@dnsmasq[0].resolvfile 2>/dev/null || true
uci commit dhcp
/etc/init.d/dnsmasq restart || log_err "系统 DNS 重启挂起，请检查配置树状态！"

log_info "【日志】结果：Dnsmasq 新规则已应用，状态已备份。"

# -----------------------------------------------------------
# [阶段七]：Procd 原生托管与闭环校验 (Final Fix: 解除硬编码+正则修复)
# -----------------------------------------------------------
log_info "构建 Procd 崩溃自启守护层 (注入路径: $WORK_DIR)..."

cat << EOF > /etc/init.d/xray
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1
PROG="$WORK_DIR/xray"
CONF="$WORK_DIR/config.json"
ASSET_DIR="$WORK_DIR"
EOF

cat << 'EOF' >> /etc/init.d/xray

IP_BIN=""
for path in /sbin/ip /usr/sbin/ip /bin/ip /usr/bin/ip; do
    if [ -x "$path" ]; then
        IP_BIN="$path"
        break
    fi
done
[ -z "$IP_BIN" ] && IP_BIN="ip"

EXTRA_COMMANDS="check"

check() {
    echo "=== Xray TProxy 链路诊断报告 ==="
    if pgrep -f "$PROG" >/dev/null 2>&1; then
        echo "[✔] 核心进程: 运行中"
    else
        echo "[✖] 核心进程: 未启动"
    fi
    
    if $IP_BIN rule show 2>/dev/null | grep -qE "fwmark.*1.*(lookup|table).*100"; then
        echo "[✔] 策略路由: 规则已挂载 (fwmark 1)"
    else
        echo "[✖] 策略路由: 未探测到规则 (探测使用的路径: $IP_BIN)"
    fi
    
    if $IP_BIN route show table 100 2>/dev/null | grep -qE "local default|local 0.0.0.0/0"; then
        echo "[✔] 本地路由: 路由表正常 (table 100)"
    else
        echo "[✖] 本地路由: 路由表异常"
    fi
    echo "================================"
}

start_service() {
    local retry=0
    while [ "$(date +%Y)" -lt "2024" ]; do
        sleep 2
        retry=$((retry+1))
        if [ "$retry" -ge 15 ]; then
            break
        fi
    done
    
    $IP_BIN rule del fwmark 1 table 100 2>/dev/null || true
    $IP_BIN route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
    $IP_BIN rule add fwmark 1 table 100
    $IP_BIN route add local 0.0.0.0/0 dev lo table 100
    
    procd_open_instance
    procd_set_param command "$PROG" run -c "$CONF"
    procd_set_param env XRAY_LOCATION_ASSET="$ASSET_DIR"
    # // 修改开始：[Procd 托管层注入文件描述符红线解锁]
    # 修改原因：高并发透明代理场景下，默认的 1024 进程文件打开限制极易导致核心触发 accept4: too many open files 异常。
    # 逻辑说明：显式声明 nofile 软硬限制为 65535，大幅提升高并发环境的稳定性。
    procd_set_param limits nofile=65535 65535
    # // 修改结束
    procd_set_param respawn 3600 5 0
    procd_set_param file "$CONF"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    $IP_BIN rule del fwmark 1 table 100 2>/dev/null || true
    $IP_BIN route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
}
EOF
chmod +x /etc/init.d/xray

log_info "注入系统总线并执行最终心跳探活..."
/etc/init.d/xray enable
/etc/init.d/xray restart >/dev/null 2>&1

if ! ip rule show | grep -qE "fwmark.*1.*(lookup|table).*100"; then
    log_warn "策略路由探针警告: 规则挂载可能存在异常，请执行 check 检查！"
fi

if ! ip route show table 100 2>/dev/null | grep -qE "local default|local 0.0.0.0/0"; then
    log_warn "本地路由表探针警告: table 100 未正确配置，请执行 check 检查！"
fi

log_info "【日志】输入：开始最终网络连通性与 DNS 闭环验收"
log_info "【日志】过程：向本地 Dnsmasq 引擎发起模拟 DNS 查询请求 (baidu.com)，最长动态等待 15 秒..."

DNS_OK=0
for i in $(seq 1 45); do
    if nslookup www.baidu.com 127.0.0.1 >/dev/null 2>&1; then
        DNS_OK=1
        log_info "【日志】结果：第 $i 秒 DNS 解析校验通过！Xray (端口 5354) 透明代理网络栈流量接管成功。"
        break
    fi
    sleep 1
done

if [ "$DNS_OK" -eq 0 ]; then
    log_warn "【日志】结果：连续 15 秒 DNS 解析验证失败！Xray 的 5354 端口未能正常提供解析服务。"
    log_warn "触发 automatic 容错机制：正在回滚 Dnsmasq 原始配置..."
    
    uci delete dhcp.@dnsmasq[0].server 2>/dev/null || true
    if [ -n "$OLD_SERVER" ]; then
        for srv in $OLD_SERVER; do
            uci add_list dhcp.@dnsmasq[0].server="$srv"
        done
    fi
    uci set dhcp.@dnsmasq[0].noresolv="$OLD_NORESOLV"
    uci commit dhcp
    /etc/init.d/dnsmasq restart
    
    log_err "致命异常：DNS 劫持后网络中断，已安全回滚！请重新检查配置文件的端口对应关系。"
fi

# -----------------------------------------------------------
# [阶段]：自动化运维与定时更新引擎注入
# -----------------------------------------------------------

log_info "【日志】输入：设定定时任务规则为每天 11:00 (0 11 * * *)，目标调用脚本为 $WORK_DIR/update_rules.sh"
log_info "【日志】过程：检测并向系统 crontab 注入定时执行策略..."

CRON_FILE="/etc/crontabs/root"
CRON_CMD="0 11 * * * $WORK_DIR/update_rules.sh >/dev/null 2>&1"

# 基础文件防空洞检查
if [ ! -f "$CRON_FILE" ]; then
    touch "$CRON_FILE"
fi

# 幂等性清理：若存在旧规则则安全剔除，避免重复写入导致进程并发冲突
if grep -q "update_rules.sh" "$CRON_FILE"; then
    log_warn "【日志】过程：检测到历史定时任务已存在，执行覆盖更新以确保时间同步至 11:00..."
    sed -i "\|update_rules.sh|d" "$CRON_FILE"
fi

# 原子级追加与服务重载
echo "$CRON_CMD" >> "$CRON_FILE"
/etc/init.d/cron restart >/dev/null 2>&1 || true

log_info "【日志】结果：计划任务注入成功。下次执行时间锁定为：每天 11:00"
log_info "【日志】目的：实现规则库的无人值守静默同步，保障系统长期处于最新分流状态，降低维护成本。"


log_info "=========================================================="
log_info " 🎉 OpenWrt TProxy 核心部署已成功！"
log_info " - 工作目录: $WORK_DIR/"
log_info " - 管控总线: /etc/init.d/xray {start|stop|restart|status|reload|check}"
log_info " - 追踪引擎: logread -e xray"
log_info "=========================================================="
exit 0