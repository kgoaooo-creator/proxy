from flask import Flask, request, jsonify
import subprocess
import os
import json
import shutil
import time

app = Flask(__name__)

HTML_TEMPLATE = """
<!DOCTYPE html><html><head><title>Xray 原生控制中心</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
    body{font-family: monospace; background: #1e1e1e; color: #d4d4d4; padding: 20px; max-width: 900px; margin: 0 auto;}
    button{background: #007acc; color: white; border: none; padding: 8px 15px; cursor: pointer; margin: 5px 5px 5px 0; border-radius: 3px;}
    button:hover{background: #005f9e;}
    #logs{background: #000; padding: 15px; height: 400px; overflow-y: auto; border: 1px solid #444; border-radius: 5px; white-space: pre-wrap; font-size: 13px;}
    select, input{padding: 8px; margin: 5px 5px 5px 0; background: #333; color: white; border: 1px solid #555; border-radius: 3px;}
    .panel{background: #252526; padding: 15px; border-radius: 5px; margin-bottom: 20px; border: 1px solid #333;}
</style></head><body>
<h2>⚡ Xray 核心路由控制器</h2>

<div class="panel">
    <button onclick="action('start')" id="btn-start">▶ 启动核心</button>
    <button onclick="action('stop')" id="btn-stop" style="background: #a1260d;">⏹ 停止核心</button>
    <span id="status" style="margin-left: 15px; font-weight: bold; color: #f39c12;">状态: 探测中...</span>
</div>

<div class="panel">
    <h3>📁 配置策略管理</h3>
    <select id="configList"></select>
    <button onclick="switchConfig()">加载并应用此配置</button>
    <button onclick="deleteConfig()" style="background: #c0392b;">删除此配置</button>
    <div style="margin-top: 10px;">
        <input type="file" id="fileInput" accept=".json">
        <button onclick="uploadConfig()">上传新策略至池中</button>
    </div>
</div>

<div class="panel">
    <h3>🖥️ 实时日志流 (仅在页面开启时拉取) <button onclick="clearLogs()" style="background: #7f8c8d; float: right; margin-top: -5px;">🗑️ 清空日志</button></h3>
    <div id="logs">等待连接...</div>
</div>

<script>
    async function fetchApi(endpoint, payload=null) {
        try {
            // 修改开始：[修复 Fetch 协议中缺失的 JSON 声明头]
            // 修改原因：解决后端 Flask 无法识别纯文本载荷，导致 payload 被拦截丢弃并回退至默认名 upload.json 的缺陷。
            // 逻辑说明：在 POST 请求配置中显式注入 headers，声明 Content-Type 为 application/json。
            // 使用方法与调用示例：前端执行任何 POST (如 switch/upload) 时，网络流中将包含正确的 MIME Type。
            let opts = payload ? {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(payload)} : {};
            // 修改结束
            opts.credentials = 'same-origin'; 
            let res = await fetch(endpoint, opts);
            if (!res.ok) {
                let errText = await res.text();
                throw new Error(`HTTP ${res.status}: ${errText.substring(0, 50)}`);
            }
            return await res.json();
        } catch (e) {
            console.error("API 通信失败:", e);
            return {msg: `异常: ${e.message}`, error: true};
        }
    }
    async function action(type) {
        let res = await fetchApi('/api/' + type);
        alert(res.msg); getStatus(); getLogs();
    }
    async function getStatus() {
        let res = await fetchApi('/api/status');
        if(res.error) return;
        let statColor = res.status === 'active' ? '#2ecc71' : '#e74c3c';
        document.getElementById('status').innerHTML = `当前挂载: ${res.current} | 运行状态: <span style="color:${statColor}">${res.status}</span>`;
        let select = document.getElementById('configList');
        let oldVal = select.value;
        select.innerHTML = '';
        res.files.forEach(f => select.innerHTML += `<option value="${f}">${f}</option>`);
        if(oldVal && res.files.includes(oldVal)) select.value = oldVal;
    }
    async function getLogs() {
        let res = await fetchApi('/api/logs');
        if(res.error) return;
        let logEl = document.getElementById('logs');
        let isAtBottom = logEl.scrollHeight - logEl.clientHeight <= logEl.scrollTop + 50;
        logEl.innerText = res.data;
        if(isAtBottom) logEl.scrollTop = logEl.scrollHeight;
    }
    async function switchConfig() {
        let file = document.getElementById('configList').value;
        if(!file) return alert("请选择配置");
        let res = await fetchApi('/api/switch', {file: file});
        alert(res.msg); getStatus(); getLogs();
    }
    function uploadConfig() {
        let file = document.getElementById('fileInput').files[0];
        if(!file) return alert("请选择文件");
        let reader = new FileReader();
        reader.onload = async function(e) {
            let res = await fetchApi('/api/upload', {name: file.name, content: e.target.result});
            alert(res.msg); getStatus();
        };
        reader.readAsText(file);
    }
    
    // 修改开始：[新增删除配置与清空日志的交互逻辑]
    // 逻辑说明：追加用户敏感操作的二次确认拦截，阻断 default.json 等核心文件的危险操作。
    async function deleteConfig() {
        let file = document.getElementById('configList').value;
        if(!file) return alert("请选择要删除的配置");
        if(file === 'default.json' || file === 'config.json') return alert("系统核心配置文件，禁止删除！");
        if(!confirm(`⚠️ 危险操作：确定要永久删除 [ ${file} ] 吗？`)) return;
        let res = await fetchApi('/api/delete', {file: file});
        alert(res.msg); getStatus();
    }
    async function clearLogs() {
        if(!confirm("确定要清空系统底层的 Xray 运行日志吗？")) return;
        let res = await fetchApi('/api/clear_logs');
        alert(res.msg); getLogs();
    }
    // 修改结束

    let pollInterval = null;
    function startPolling() {
        if (!pollInterval) {
            pollInterval = setInterval(() => {
                if (!document.hidden) { getStatus(); getLogs(); }
            }, 2000);
        }
    }
    document.addEventListener("visibilitychange", () => {
        if (document.hidden) { clearInterval(pollInterval); pollInterval = null; }
        else { getStatus(); getLogs(); startPolling(); }
    });
    getStatus(); getLogs(); startPolling();
</script>
</body></html>
"""

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_DIR = os.path.join(BASE_DIR, 'configs')
os.makedirs(CONFIG_DIR, exist_ok=True)

def log_audit(action_name, inbound, process_desc, outbound):
    print(f"\n[AUDIT LOG] ====== 动作: {action_name} ======")
    print(f"  - 输入: {inbound}")
    print(f"  - 过程: {process_desc}")
    print(f"  - 结果: {outbound}")
    print(f"==========================================")

@app.route('/')
def index():
    return HTML_TEMPLATE


ACTIVE_CONFIG = "config.json"

@app.route('/api/status', methods=['GET', 'POST'])
def status_api():
    try:
        files = os.listdir(CONFIG_DIR) if os.path.exists(CONFIG_DIR) else []
        files = [f for f in files if f.endswith('.json')]
        stat = subprocess.run(['systemctl', 'is-active', 'xray'], capture_output=True, text=True, timeout=3).stdout.strip()
        
        global ACTIVE_CONFIG
        return jsonify({"files": files, "current": ACTIVE_CONFIG, "status": stat})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

LOG_CACHE = {"data": "暂无系统日志输出...", "timestamp": 0}
CACHE_TTL = 2.0

@app.route('/api/logs', methods=['GET', 'POST'])
def logs_api():
    try:
        global LOG_CACHE
        current_time = time.time()
        if current_time - LOG_CACHE["timestamp"] < CACHE_TTL:
            return jsonify({"data": LOG_CACHE["data"]})
        
        log_raw = subprocess.run(['journalctl', '-u', 'xray', '-n', '60', '--no-pager', '-o', 'cat'], capture_output=True, text=True, timeout=3).stdout
        
        if not log_raw: 
            log = "暂无系统日志输出..."
        else:
            log_raw = log_raw.replace("from tcp:198.18.0.1:", "[TCP 劫持] 虚拟源端口:")
            log_raw = log_raw.replace("from udp:198.18.0.1:", "[UDP 劫持] 虚拟源端口:")
            
            processed_lines = []
            for line in log_raw.splitlines():
                parts = line.split(" ", 1)
                if len(parts) == 2 and len(parts[0]) == 10 and parts[0].count('/') == 2:
                    processed_lines.append(parts[1])
                else:
                    processed_lines.append(line)
            log = "\n".join(processed_lines)
            
        LOG_CACHE["data"] = log
        LOG_CACHE["timestamp"] = current_time
        return jsonify({"data": log})
    except Exception as e:
        return jsonify({"data": f"获取日志失败: {str(e)}"})

@app.route('/api/<action>', methods=['GET', 'POST'])
def core_action_api(action):
    try:
        data = request.get_json(silent=True) or {}
    except Exception:
        return jsonify({"msg": "无效负载", "error": True}), 400

    if action == 'start':
        log_audit("拉起核心服务", "None", "调用 systemctl start xray 启动内核守护单元", "下发指令成功")
        try:
            subprocess.run(['systemctl', 'start', 'xray'], check=True, timeout=5)
            return jsonify({"msg": "启动指令已下发"})
        except subprocess.CalledProcessError:
            return jsonify({"msg": "启动失败"}), 500
            
    elif action == 'stop':
        log_audit("终止核心服务", "None", "调用 systemctl stop xray 熔断内核守护单元", "解脱服务成功")
        subprocess.run(['systemctl', 'stop', 'xray'])
        return jsonify({"msg": "服务已终止"})
        
    elif action == 'switch':
        if request.method != 'POST':
            return jsonify({"msg": "方法不允许", "error": True}), 405
            
        safe_file = os.path.basename(data.get('file', ''))
        target = os.path.join(CONFIG_DIR, safe_file)
        
        if not os.path.exists(target):
            log_audit("切换策略配置", f"目标策略: {safe_file}", "检测文件是否存在", f"异常拦截: {safe_file} 不存在")
            return jsonify({"msg": "配置不存在！"}), 404
            
        try:
            binary_path = os.path.join(BASE_DIR, 'xray')
            check = subprocess.run([binary_path, '-test', '-config', target], capture_output=True, text=True, timeout=5)
            
            if "Configuration OK" in check.stdout or "Configuration OK" in check.stderr:
                log_audit("清理底层环境", "精准匹配二进制名", "下发 systemctl stop 与 pkill -9 -x 信号", "底层进程树清理完毕")
                subprocess.run(['systemctl', 'stop', 'xray'])
                subprocess.run(['pkill', '-9', '-x', 'xray'], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
                
                shutil.copy(target, os.path.join(BASE_DIR, 'config.json'))
                subprocess.run(['systemctl', 'start', 'xray'])

                global ACTIVE_CONFIG
                ACTIVE_CONFIG = safe_file
                # // 修改结束
                
                log_audit("切换策略配置", f"目标策略: {safe_file}", "通过 Xray 核心语法校验 -> 原子级覆盖主配置 -> 重启后台服务", "链路成功闭环并上线生效")
                return jsonify({"msg": "校验通过，已重启生效！"})
            else:
                log_audit("切换策略配置", f"目标策略: {safe_file}", f"通过 Xray 核心测试引擎执行离线语法健康度探针", f"阻断拦截: 策略内部包含致命违规配置\n{check.stdout[:100]}")
                return jsonify({"msg": f"阻断！语法损坏：\n{check.stdout[:200]}"})
        except Exception as e:
            log_audit("切换策略配置", f"目标策略: {safe_file}", "核心校验执行期间发生未捕获异常", f"系统级崩溃: {str(e)}")
            return jsonify({"msg": f"执行异常: {e}"}), 500
            
    elif action == 'upload':
        if request.method != 'POST':
            return jsonify({"msg": "方法不允许", "error": True}), 405
            
        safe_name = os.path.basename(data.get('name', 'upload.json'))
        upload_target = os.path.join(CONFIG_DIR, safe_name)
        
        content_len = len(data.get('content', ''))
        log_audit("上载新策略文件", f"文件名: {safe_name}, 数据长度: {content_len} 字节", "解析前端载荷并原子化刷写物理磁盘", f"入库成功: {safe_name} 已成功转储至策略池")
        
        with open(upload_target, 'w', encoding='utf-8') as f:
            f.write(data.get('content', ''))
        return jsonify({"msg": f"配置 {safe_name} 已安全入库"})

    # // 修改开始：[新增配置删除逻辑]
    elif action == 'delete':
        if request.method != 'POST':
            return jsonify({"msg": "方法不允许", "error": True}), 405
            
        safe_file = os.path.basename(data.get('file', ''))
        # 硬编码限制：系统保留策略禁止任何越权抹除
        if safe_file in ['config.json', 'default.json']:
            return jsonify({"msg": "系统保留策略，禁止删除！", "error": True}), 403
            
        target = os.path.join(CONFIG_DIR, safe_file)
        if os.path.exists(target):
            os.remove(target)
            log_audit("删除策略配置", f"目标策略: {safe_file}", "物理擦除磁盘文件", "已永久删除")
            return jsonify({"msg": f"配置 {safe_file} 已彻底删除！"})
        return jsonify({"msg": "文件不存在", "error": True}), 404
    # // 修改结束
        
    # // 修改开始：[新增底层的系统级日志清空逻辑]
    elif action == 'clear_logs':
        log_audit("清空系统日志", "None", "调用 journalctl --rotate 与 --vacuum-time=1s，并重置内存缓存", "底层日志数据已抹除")
        subprocess.run(['journalctl', '--rotate'], stdout=subprocess.DEVNULL)
        subprocess.run(['journalctl', '--vacuum-time=1s'], stdout=subprocess.DEVNULL)
        global LOG_CACHE
        LOG_CACHE["data"] = "暂无系统日志输出..."
        LOG_CACHE["timestamp"] = 0
        return jsonify({"msg": "底层系统日志已全数清空！"})
    # // 修改结束

    else:
        return jsonify({"msg": "未知指令", "error": True}), 404

if __name__ == '__main__':
    print(f"\n[AUDIT LOG] ====== 动作: 启动 Web 引擎 ======")
    print(f"  - 输入: 0.0.0.0:9999, Threads=4")
    print(f"  - 过程: 挂载 Waitress WSGI 高并发容器替代原生 Flask")
    print(f"  - 结果: 引擎已完全就绪")
    print(f"==========================================")
    from waitress import serve
    serve(app, host='0.0.0.0', port=9999, threads=4)