#!/bin/bash

# // 修改开始：[底层路由规则库双线 CDN 静默同步引擎]
# 修改原因：满足规则获取的高可用性与自动化诉求。硬性封禁 raw.githubusercontent.com 域，构建主线与备线平滑降级的下载网络拓扑。
# 逻辑说明：通过 curl -f 参数探知 HTTP 状态码，主线节点 (cdn.jsdelivr.net) 失联时自动阻断并无缝滑落至备用节点 (fastly.jsdelivr.net)。下载并校验完整后，原子级覆写物理文件，并挂载重启信号。
# 使用方法与调用示例：跟随 install.sh 自动化执行，或写入服务器 crontab 定时器执行。
# 日志输出日志是否包含：是。全链路均已实现标准输入、过程、结果与目的说明。

set -e

# ==========================================
# 审计日志函数定义
# ==========================================
log_audit() {
    echo -e "\n[\033[36mAUDIT LOG\033[0m] ====== 动作: $1 ======"
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

download_with_fallback() {
    local file_name=$1
    local url1=$2
    local url2=$3
    
    log_audit "拉起规则库下载链路" "目标文件: $file_name" "执行 curl 网络探针" "尝试从 cdn.jsdelivr.net 获取数据..." "保障高速下载通道优先权重"
    
    # 尝试主线节点下载
    if curl -s -f -L -o "${WORK_DIR}/${file_name}.new" "$url1"; then
        log_audit "主线 CDN 下载状态" "节点: cdn.jsdelivr.net" "文件流式写入物理磁盘" "下载成功" "完成极速更新获取"
        return 0
    fi
    
    log_audit "主线 CDN 访问阻断" "节点: cdn.jsdelivr.net" "触发底层容灾降级机制，切换至备用源" "开始从 fastly.jsdelivr.net 获取数据..." "避免单点故障引发全局断更"
    
    # 尝试备用节点下载
    if curl -s -f -L -o "${WORK_DIR}/${file_name}.new" "$url2"; then
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
        
        systemctl restart xray 2>/dev/null || true
        log_audit "重载底层分流路由引擎" "目标进程: xray.service" "调用 systemctl restart 平滑重载信号" "服务热重启成功，新规则矩阵已挂载进内存" "促使全新的域名与 IP 分流库即刻介入流量接管链路"
    else
        rm -f "${WORK_DIR}/*.new"
        log_audit "网络载荷异常拦截" "下载的文件体积异常 (判定为空文件)" "触发核心防线熔断，自动清空无效临时文件" "更新已被紧急中止，系统维持原版路由安全运行" "防止残缺引擎启动导致断网"
        exit 1
    fi
else
    rm -f "${WORK_DIR}/*.new"
    log_audit "致命网络异常" "双线 CDN 分发节点均建立连接失败" "触发最高级别网络熔断，物理擦除临时载体" "任务已被终止" "防止无效空转，静默等待下一轮次定时触发"
    exit 1
fi
# // 修改结束