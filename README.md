
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
 - 反代远程网址时，Caddy 会把请求的 Host 头改写为上游主机名（Caddy 2.11 起对 HTTPS 上游默认如此；
   脚本显式设置以兼容旧版，对 HTTP 上游则改变了原始 Host）；若上游依赖原始域名来路由或做校验，需要自行调整 Caddyfile。

通过以下命令一键安装和启动 Caddy 服务：

```bash
curl -o easyCaddy.sh https://raw.githubusercontent.com/duya07/easy_Caddy/refs/heads/main/easyCaddy.sh && chmod +x easyCaddy.sh && ./easyCaddy.sh
```


nginx 一键部署 & 管理脚本（easy_nginx.sh）  ==================
 1) 安装 Nginx
 2) 添加反向代理（本地端口 / 远程网址）
 3) 删除反向代理
 4) 查看所有反向代理配置
 5) 修改反向代理配置
 6) 重启 Nginx
 7) 一键删除并卸载 Nginx
 8) 退出

菜单 2 与 Caddy 版对等，同样为二级菜单：
  1) 反代本地端口：域名 + 本地端口，生成 proxy_pass http://127.0.0.1:端口;
  2) 反代远程网址：域名 + 远程网址，生成 proxy_pass https://目标网址;（同时写入 proxy_ssl_server_name on;）
     （同样必须带 http:// 或 https:// 前缀，不支持带路径 / 查询串 / 锚点）
  0) 返回

nginx 版额外的限制（如实说明）：
 - proxy_pass 里的域名在 nginx 启动 / reload 时解析一次并缓存，上游 IP 变化后需要 reload nginx 才会生效。
 - 反代 HTTPS 上游要靠脚本生成的 proxy_ssl_server_name on; 来发 SNI；缺少该指令时多站点上游会返回默认站点或拒绝连接。
 - nginx 默认不验证 HTTPS 上游证书（proxy_ssl_verify 默认为 off）。需要校验证书的部署应自行配置 proxy_ssl_verify on 和 proxy_ssl_trusted_certificate；修改上游时保留这些手工设置。Caddy 的 HTTPS 上游默认会验证证书。

上面 Caddy 一节列出的三条限制（页面里写死的绝对链接 / JS 域名不会被改写；目标站点可能有 WAF / Cloudflare 反爬 / 地域限制；
反代远程网址时 Host 头会被改写为上游主机名——nginx 版生成的配置同样把 Host 设为上游主机名）对 nginx 版同样适用。

通过以下命令一键安装并启动 nginx 服务：

```bash
curl -o easy_nginx.sh https://raw.githubusercontent.com/duya07/easy_Caddy/refs/heads/main/easy_nginx.sh && chmod +x easy_nginx.sh && ./easy_nginx.sh
```

配置管理说明：
 - 域名输入为单个主机名或 IP；远程上游格式为 http(s)://host[:port]，IPv6 地址用方括号，不支持路径、查询串、认证信息或配置指令。
 - 添加、修改和删除先验证候选配置，再保存配置并重载服务；失败会返回错误并恢复原文件。若恢复本身失败，脚本会保留恢复材料并提示其位置。
 - Caddy 删除保留目标站点外的内容；共享多个地址或无法确定边界的站点需要手动处理。nginx 修改保留手工设置；无法确定目标代理位置时会拒绝修改。

开发回归测试：运行方式和证据说明见 [tests/README.md](tests/README.md)。测试需要 Linux、Python 3 和对应的 Caddy/nginx 二进制；使用这两个部署脚本不需要 Python。

