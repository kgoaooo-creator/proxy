#!/bin/bash

# // 修改开始：[双端架构解耦与动态环境参数注入]
# 1. 检查输入参数与环境标识
if [ -z "$1" ]; then
    echo -e "[\033[31mERROR\033[0m] 缺少输入文件！\n用法: ./patch_config.sh <v2rayN导出的config.json> [openwrt]"
    exit 1
fi

INPUT_FILE="$1"
# 统一转换为小写，提升参数输入容错率
ENV_MODE=""
if [ "${2,,}" = "openwrt" ] || [ "$2" = "openwrt" ] || [ "$2" = "OPENWRT" ]; then
    ENV_MODE="openwrt"
fi

# 2. 检测并安装底层依赖 jq
if ! command -v jq &> /dev/null; then
    echo -e "[\033[33mWARN\033[0m] 未检测到 jq，正在自动安装..."
    if command -v apt-get &> /dev/null; then apt-get update && apt-get install -y jq > /dev/null
    elif command -v yum &> /dev/null; then yum install -y epel-release && yum install -y jq > /dev/null
    fi
fi


NODE_IP=$(jq -r '.outbounds[]? | select(.tag == "proxy") | (.settings.vnext[0].address // .settings.servers[0].address // .settings.address) // empty' "$INPUT_FILE" | head -n 1)



# 3. 创建系统级安全临时文件
TEMP_FILE=$(mktemp)

# 修改原因：
#   1. 彻底解决 OpenWrt 缺失 kmod-tun 与 TProxy 架构撕裂的问题。
#   2. 实现公有逻辑（路由增强）与私有逻辑（入站网卡劫持方式）的底层解耦。
# 逻辑说明：
#   - 公共层：处理出站防环路（mark:255）与 AsIs 规则原位扩容。此段逻辑严格保持字节级一致。
#   - OpenWrt 层：清洗残留 TUN 节点，强制注入 TProxy(12345) 监听与 DNS(5353) 劫持。
#   - Linux 层：维持默认注入 TUN(xray-tun0) 虚拟网卡的逻辑。
# 使用方法与调用示例：
#   通用桌面端: ./patch_config.sh config.json
#   OpenWrt 路由端: ./patch_config.sh config.json openwrt
# 日志输出日志是否包含：是。根据实际运行环境精确输出结果。
jq --arg env_mode "$ENV_MODE" --arg node_ip "$NODE_IP" '
  # [公共逻辑区]：防环路标记（字节级一致）
  .outbounds |= map(
    if .tag == "proxy" or .tag == "direct" then
      .streamSettings = (.streamSettings // {}) |
      .streamSettings.sockopt = (.streamSettings.sockopt // {}) |
      .streamSettings.sockopt.mark = 255
    else
      .
    end
  ) |

  # [公共逻辑区]：路由增强扩容（字节级一致）
  (if .routing != null and .routing.rules != null then
    .routing.rules |= (
      map(
        if (.outboundTag == "proxy" and .domain != null and (.domain | index("geosite:google") != null)) then
          .domain = (.domain + ["geosite:geolocation-!cn", "geosite:gfw"] | unique)
        elif (.outboundTag == "direct" and .domain != null and (.domain | index("geosite:cn") != null)) then
          .domain = (.domain + ["geosite:apple-cn", "geosite:category-games@cn"] | unique)
        else
          .
        end
      ) |
      if (any(.domain != null and (.domain | index("geosite:category-ads-all") != null))) then . else
        reduce .[] as $item ([];
          . + [$item] +
          if ($item.port == "443" and $item.network == "udp" and $item.outboundTag == "block") then
            [{"type": "field", "outboundTag": "block", "domain": ["geosite:category-ads-all"]}]
          else [] end
        )
      end |
      if (any(.network == "tcp,udp" and .outboundTag == "proxy")) then . else
        . + [{"type": "field", "outboundTag": "proxy", "network": "tcp,udp"}]
      end |
      

      if ($node_ip != "" and $node_ip != "null" and (any(.outboundTag == "direct" and .ip != null and (.ip | index($node_ip) != null)) | not)) then
        [{"type": "field", "outboundTag": "direct", "ip": [$node_ip]}] + .
      else
        .
      end
      
    )
  else
    .
  end) |

  # [环境特异性逻辑区]：依据指令按需注入
  if $env_mode == "openwrt" then
    # === OpenWrt 路由器特供：TProxy + 5353 DNS 劫持 ===
    .inbounds |= (
      map(select(.protocol != "tun")) |
      (if map(.port == 12345) | any then . else
        . + [{
          "tag": "tproxy-in",
          "port": 12345,
          "listen": "0.0.0.0",
          "protocol": "dokodemo-door",
          "settings": {
            "network": "tcp,udp",
            "followRedirect": true
          },
          "streamSettings": {
            "sockopt": {
              "tproxy": "tproxy"
            }
          },
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"],
            "routeOnly": false
          }
        }]
      end) |
      (if map(.port == 5353) | any then . else
        . + [{
          "tag": "dns-in",
          "port": 5353,
          "listen": "127.0.0.1",
          "protocol": "dokodemo-door",
          "settings": {
            "address": "1.1.1.1",
            "port": 53,
            "network": "tcp,udp"
          }
        }]
      end)
    ) |
    .outbounds |= (
      if map(.protocol == "dns") | any then . else
        . + [{
          "tag": "dns-out",
          "protocol": "dns"
        }]
      end
    ) |
    if .routing != null and .routing.rules != null then
      .routing.rules |= (
        if (any(.inboundTag != null and (.inboundTag | index("dns-in") != null))) then . else
          [{"type": "field", "inboundTag": ["dns-in"], "outboundTag": "dns-out"}] + .
        end
      )
    else . end
  else
    # === Linux 桌面/服务器端特供：TUN 虚拟网卡 ===
    .inbounds |= (
      if map(.protocol == "tun") | any then
        map(if .protocol == "tun" then
          .settings = {
            "name": "xray-tun0",
            "mtu": 1500,
            "address": ["198.18.0.1/16"]
          } |
          .sniffing = {
            "enabled": true,
            "destOverride": ["http", "tls"],
            "routeOnly": false
          }
        else . end)
      else
        . + [{
          "tag": "tun-in",
          "protocol": "tun",
          "settings": {
            "name": "xray-tun0",
            "mtu": 1500,
            "address": ["198.18.0.1/16"]
          },
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"],
            "routeOnly": false
          }
        }]
      end
    )
  end
' "$INPUT_FILE" > "$TEMP_FILE"

# 5. 校验临时文件并执行安全的就地覆盖
if [ $? -eq 0 ] && [ -s "$TEMP_FILE" ]; then
    mv -f "$TEMP_FILE" "$INPUT_FILE"
    echo -e "[\033[36mACTION\033[0m] ====== 动作: 配置自适应合并与转换 ======"
    echo "  - 输入: 接收到了源文件 [$INPUT_FILE] | 运行模式: [${ENV_MODE:-linux-tun}] | 自动识别提取节点 IP: [${NODE_IP:-未识别到标网IP或使用的是域名}]"
    if [ "$ENV_MODE" = "openwrt" ]; then
        echo "  - 过程: 执行了 jq 幂等合并。清除不兼容的 TUN 节点，注入了 TProxy(12345) 监听与 DNS(5353) 防污染链路。"
        echo "  - 结果: 源文件已被成功替换为【OpenWrt TProxy 纯透明网关】架构。"
    else
        echo "  - 过程: 执行了 jq 幂等合并。注入并校准了 TUN 虚拟网卡所需的底层挂载参数。"
        echo "  - 结果: 源文件已被成功替换为【标准 Linux TUN 客户端】架构。"
    fi
    echo "  - 目的: 实现跨系统的网络栈自适应隔离，消除底层实现冲突。"
    echo "=========================================================="
    echo -e "[\033[32mSUCCESS\033[0m] JSON 动态部署替换完成！"
else
    rm -f "$TEMP_FILE"
    echo -e "[\033[31mERROR\033[0m] JSON 解析失败，语法损毁，原文件未做任何更改。"
    exit 1
fi
# // 修改结束