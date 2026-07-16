手动下载合适的架构的xray-core,并放在以下文件同一个目录中 patch_config.sh 生成配置文件 安装
linux运行以下文件

install.sh  安装

patch_config.sh  修改配置文件 ，从v2rayN导出的配置文件  不加参数是生成LINUX   加openwrt是生成OPEN配置

uninstall.sh     LINUX删除

update_rules.sh   linux 路由规则库更新

web_manager.py   LINUX 网页控制台



OPEN 安装

配置文件要在LINUX下便用 patch_config.sh 生成，加参数 openwrt

open.sh                安装

open-uninstall.sh      OPEN 删除

open-update-rules.sh     OPEN 路由规则库更新
