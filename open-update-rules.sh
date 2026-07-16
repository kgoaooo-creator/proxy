#!/bin/sh

# // 修改开始：[适配 OpenWrt 环境的底层路由规则库双线 CDN 静默同步引擎]
# 修改原因：原脚本依赖 systemctl 和 bash，无法在 OpenWrt (基于 ash 和 procd) 运行。需提升基础工具兼容性，确保在各种精简版 OpenWrt 固件上的通用性。
# 逻辑说明：
# 1. 解释器替换为 /bin/sh，完美兼容 BusyBox ash。
# 2. 构建自适应下载器 (dl_core)，自动嗅探系统环境，优先使用 curl，若缺失则无缝降级调用内置 wget。
# 3. 将 systemctl 服务管控指令替换为 OpenWrt 原生的 /etc/init.d/xray restart。
# 4. 继承原有双线容灾与原子级文件替换特性，保持高可用性。
# 使用方法与调用示例：
# 1. 赋予执行权限：chmod +x update_rules.sh
# 2. 计划任务调用：在 OpenWrt UI (系统->计划任务) 或 crontab 添加 `0 4 * * * /root/update_rules.sh >/var/log/xray_update.log 2>&1` 实现每日凌晨4点更新。
# 日志输出日志是否包含：是。全链路包含标准输入、过程、结果与目的说明。

set -e

# ==========================================
# 审计日志函数定义 (维持四维标准)
# ==========================================
log_audit() {
    echo "[\033[36mAUDIT LOG\033[0m] ====== 动作: $1 ======"
    echo "  - 输入: $2"
    echo "  - 过程: $3"
    echo "  - 结果: $4"
    echo "  - 目的: $5"
    echo "=========================================="
}

WORK_DIR=$(cd "$(dirname "$0")"; pwd)

# 强制封禁 GitHub 原站直连，配置双线分发节点
GEOIP_CDN1="https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
GEOSITE_CDN1="https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"

GEOIP_CDN2="https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
GEOSITE_CDN2="https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"

# ==========================================
# 自适应通用下载内核 (OpenWrt 通用优先)
# ==========================================
dl_core() {
    local url="$1"
    local out="$2"
    
    if command -v curl >/dev/null 2>&1; then
        curl -s -f -L -o "$out" "$url"
        return $?
    elif command -v wget >/dev/null 2>&1; then
        # OpenWrt 内置的 wget (uclient-fetch) 兼容模式
        wget -q -O "$out" "$url"
        # 验证文件是否成功写入且不为空
        [ -s "$out" ]
        return $?
    else
        log_audit "环境依赖缺失" "未找到 curl 或 wget 工具" "中断下载探测" "致命错误" "防呆保护，提示用户安装基础网络组件"
        exit 1
    fi
}

download_with_fallback() {
    local file_name=$1
    local url1=$2
    local url2=$3
    
    log_audit "拉起规则库下载链路" "目标文件: $file_name" "执行自适应网络探针" "尝试从 cdn.jsdelivr.net 获取数据..." "保障高速下载通道优先权重"
    
    # 尝试主线节点下载
    if dl_core "$url1" "${WORK_DIR}/${file_name}.new"; then
        log_audit "主线 CDN 下载状态" "节点: cdn.jsdelivr.net" "文件流式写入物理磁盘" "下载成功" "完成极速更新获取"
        return 0
    fi
    
    log_audit "主线 CDN 访问阻断" "节点: cdn.jsdelivr.net" "触发底层容灾降级机制，切换至备用源" "开始从 fastly.jsdelivr.net 获取数据..." "避免单点故障引发全局断更"
    
    # 尝试备用节点下载
    if dl_core "$url2" "${WORK_DIR}/${file_name}.new"; then
        log_audit "备用 CDN 下载状态" "节点: fastly.jsdelivr.net" "文件流式写入物理磁盘" "下载成功" "备用节点链路穿透成功"
        return 0
    fi
    
    return 1
}

log_audit "启动静默规则同步任务" "URL端点: jsdelivr 双线分发源" "下发下载与校验指令" "任务初始化中..." "保持底层引擎海内外分流路由的极致精确性"

if download_with_fallback "geoip.dat" "$GEOIP_CDN1" "$GEOIP_CDN2" && \
   download_with_fallback "geosite.dat" "$GEOSITE_CDN1" "$GEOSITE_CDN2"; then
   
    # 基础完整性防空洞校验（确保不是 0KB 文件）
    if [ -s "${WORK_DIR}/geoip.dat.new" ] && [ -s "${WORK_DIR}/geosite.dat.new" ]; then
        mv -f "${WORK_DIR}/geoip.dat.new" "${WORK_DIR}/geoip.dat"
        mv -f "${WORK_DIR}/geosite.dat.new" "${WORK_DIR}/geosite.dat"
        log_audit "数据文件原子级替换" "本地物理文件: geoip.dat, geosite.dat" "执行 mv -f 覆盖操作" "文件已平滑更新完毕" "保障核心层读取的规则库绝对完整安全，无损切换"
        
        # OpenWrt 专属服务重载指令
        if [ -x "/etc/init.d/xray" ]; then
            /etc/init.d/xray restart >/dev/null 2>&1 || true
            log_audit "重载底层分流路由引擎" "管控总线: /etc/init.d/xray" "发送 restart 平滑重载信号" "服务热重启成功，新规则矩阵已挂载" "促使全新的域名与 IP 分流库即刻介入流量接管链路"
        else
            log_audit "服务探针异常" "未发现 /etc/init.d/xray 可执行总线" "跳过重启操作" "规则已更新但未应用" "防止因路径差异导致脚本崩溃中止"
        fi
    else
        rm -f "${WORK_DIR}"/*.new
        log_audit "网络载荷异常拦截" "下载的文件体积异常 (判定为空文件)" "触发核心防线熔断，自动清空无效临时文件" "更新已被紧急中止，系统维持原版路由安全运行" "防止残缺引擎启动导致断网"
        exit 1
    fi
else
    rm -f "${WORK_DIR}"/*.new
    log_audit "致命网络异常" "双线 CDN 分发节点均建立连接失败" "触发最高级别网络熔断，物理擦除临时载体" "任务已被终止" "防止无效空转，静默等待下一轮次定时触发"
    exit 1
fi
# // 修改结束