
实现功能

Caddy 一键部署 & 管理脚本  ==================
 1) 安装 Caddy（如已安装则跳过）
 2) 配置 & 启用反向代理（反代本地端口 / 远程网址）
 3) 查看 Caddy 服务状态
 4) 查看当前反向代理配置
 5) 删除指定的反向代理
 6) 重启 Caddy 服务
 7) 卸载 Caddy（删除配置）
 0) 退出

菜单 2 为二级菜单，可选：
  1) 反代本地端口：域名 + 本地端口，上游为 http://127.0.0.1:端口
  2) 反代远程网址：域名 + 远程网址，上游为 http(s)://目标网址
     （必须带 http:// 或 https:// 前缀，不支持带路径 / 查询串 / 锚点）
  0) 返回


支持 Debian/Ubuntu系统

反代远程网址的限制（如实说明）：
 - 目标页面里写死的绝对链接、或 JS 里写死的域名不会被改写（Caddy 没有 nginx sub_filter 那类响应体改写能力），
   所以站内跳转或静态资源可能仍指向原站，页面不一定完全可用。
 - 目标站点可能有 WAF / Cloudflare 反爬 / 地域限制，可能出现 403 或验证码。
 - 反代远程网址时，Caddy 会把请求的 Host 头改写为上游主机名（对 HTTPS 上游这等价于 Caddy 自身的默认行为，
   对 HTTP 上游则改变了原始 Host）；若上游依赖原始域名来路由或做校验，需要自行调整 Caddyfile。

通过以下命令一键安装和启动 Caddy 服务：

```bash
curl -o easyCaddy.sh https://raw.githubusercontent.com/duya07/easy_Caddy/refs/heads/main/easyCaddy.sh && chmod +x easyCaddy.sh && ./easyCaddy.sh

