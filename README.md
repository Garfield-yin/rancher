### rancher 自动安装并初始化
为了简化 rancher 初始化操作，不使用 Web UI 一键安装后进行自动进行业务配置，写了此脚本。

### features
* 使用docker 安装
* 初始化并重置密码
* 设置 rancher server 地址
* 生成 api token
* 导入现有集群
* 移动命名空间
* 添加catalog
* 打开监控
