
实现功能

Caddy 一键部署 & 管理脚本  ==================
 1) 安装 Caddy（如已安装则跳过）
 2) 配置 & 启用反向代理（反代本地端口 / 远程网址）
 3) 查看 Caddy 服务状态
 4) 查看当前反向代理配置
 5) 删除指定的反向代理
 6) 重启 Caddy 服务
 7) 卸载 Caddy（删除配置）
 8) 证书管理（查看、复制目录、按域名登记、立即同步、日志）
 9) 手动编辑 Caddy 配置（候选校验和事务应用）
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
curl -o easyCaddy.sh https://raw.githubusercontent.com/duya07/easy_Caddy/refs/heads/main/easyCaddy.sh && chmod +x easyCaddy.sh && sudo bash ./easyCaddy.sh
```

证书与编辑操作请以 root 执行。部署仍然只需下载这个 Bash 文件；使用脚本不需要 Python。证书管理需要 Caddy、jq、OpenSSL、flock（util-linux）和 GNU coreutils/findutils。菜单 1 的安装步骤会安装 jq、openssl、util-linux；直接使用证书菜单缺依赖时会明确报错，不在后台安装软件。

添加本地或远程反代时，在域名和上游之后询问是否复制该域名证书。`y`/`yes` 开启复制，`n`/`no` 或空行表示否。选择是会使用已保存的全局目的目录；尚未设置时当场输入绝对目录，如 `/srv/caddy-certificates` 或 `/srv/caddy certificates`。选择或目录输入遇到 EOF 取消整个新增流程。只有反代配置校验、提交并 reload 成功后才保存目录和登记；反代失败不会提前开启复制。已登记域名重新选择否会在反代成功后取消该域名登记，其他域名继续同步。

菜单 8 可查看实际存储中的证书、issuer、起止有效期、证书及 key 完整路径、复制目的目录与域名登记；也可修改目录、立即同步、登记/取消已有域名、查看有界的域名日志。修改目录影响随后同步，旧目录的副本保留；仅设置目录不会复制所有证书或安装任务。外部手工 `tls` 加载的文件不属于本功能保证发现的自动 storage 证书。

存储发现使用运行 Caddy 的 HOME/XDG_DATA_HOME。Linux 默认数据目录为 `$XDG_DATA_HOME/caddy`，未设置时为 `$HOME/.local/share/caddy`；官方 systemd 服务通常是 `/var/lib/caddy/.local/share/caddy`。global `storage file_system` 的 root 使用 `caddy adapt` 的 JSON 解析，支持绝对路径和空格，以及能从运行进程解析的 `{env.VAR}`。Caddyfile `{$VAR}`、无法解析的占位符、未知 storage module、TLS policy storage 覆盖和无法确定的服务环境会明确拒绝导出。服务停止时可只读查找 literal root 或可信 unit/User 推断的默认目录，并标明未运行；相对 root 需运行进程 cwd。

每次只复制已登记域名的有效、SAN 匹配且公私钥匹配的 leaf/fullchain pair。多 issuer 时先过滤坏候选，再按 notAfter 最新、notBefore 最新、路径字节序选取；这不表示该候选就是 Caddy 当前连接选中的证书。内部 CA 或 staging 证书会显示 issuer，存在证书不代表公网信任。导出保留原 PEM 链顺序，目标为 `<目的目录>/<域名>/fullchain.pem` 和 `privkey.pem`。新目录 0700，两个文件默认 0600；既有目录属性保留，不放宽私钥权限。原 storage、ACME 账户/CA 私钥不会被移动、删除、改权限或导出。

同步先在同一文件系统暂存并重新验证整对证书/key，再替换域名目录；替换可有极短的路径缺口。未发现证书显示「待签发/未发现」，不会等待 ACME 或宣称已签发。坏证书、key 不匹配、过期、源轮换或写入失败会保留旧的正确副本并返回错误；旧目标本身损坏、半对、symlink、危险硬链接或不受 root 控制时拒绝覆盖。目的目录须为受控绝对路径，不能与 Caddy storage、配置、登记、worker 或系统单元重叠。路径中的 shell 符号按普通数据处理。

首次成功开启域名复制后安装 root 拥有的 `/usr/local/lib/easy-caddy/easyCaddy.sh` 快照以及 `easy-caddy-cert-sync.service`/`.timer`。这是 stock Caddy 的外部一分钟轮询，无需 exec 事件插件。timer 使用 `OnBootSec=1min`、`OnUnitActiveSec=1min`，`enable --now` 后退出管理脚本和重启机器仍会继续检查签发/续期。实际签发时间由 Caddy/CA 决定；新证书可用后通常在下一次轮询同步，受调度、锁和写入情况影响。反代成功后导出或安装任务失败会单独报错，并保留反代与登记；可手动重试：

```bash
sudo bash ./easyCaddy.sh --sync-certificates
sudo bash ./easyCaddy.sh --sync-certificates example.com
sudo systemctl status easy-caddy-cert-sync.timer
sudo journalctl -u easy-caddy-cert-sync.service -n 100 --no-pager
```

CLI 单次执行后退出、不进入菜单；指定域名仍须事先登记。取消最后一个域名时允许 timer 保留闲置，空登记 worker 直接返回 0、不扫描或创建文件。独立设置在 `/etc/easy-caddy/certificates/export-directory`（一行目录）与 `export-domains`（每行一个域名），新状态目录 0700、文件 0600。状态修改和 worker 共享 flock 锁。同步记录在 `sync.log`，菜单按域名显示最多最近 200 行，并过滤 Caddy/worker journal；记录不包含私钥正文。旧 `/root/caddy_reverse_proxies.txt` 的 `domain -> upstream` 格式保持。

菜单 9 先在 Caddyfile 同目录创建唯一 `.manual-backup.<时间>.<随机后缀>` 备份，再在 0700 工作目录编辑候选。优先 `VISUAL`、其次 `EDITOR`，未设置时选择已安装的 nano/vi；允许 `vim -f` 一类简单 argv，拒绝需要 shell 引号、展开或命令拼接的值。编辑器未改内容/取消时不 validate/reload；编辑器失败或候选异常不写 live。保存后先用真实 `caddy validate`，再拿与自动反代共同的配置锁并检查原文件内容/身份。外部变动拒绝覆盖，坏草稿及日志保留并打印位置。通过后保持原 owner/mode 安全提交并 reload；reload 失败会恢复原件并尝试重新加载，恢复失败单独报告。手工站点不进入自动反代注册表，注册表保持原字节。

需要回滚手动编辑时，在下载的脚本所在目录执行下面命令，替换为脚本实际打印的备份绝对路径。它复用同一验证、备份、冲突保护和 reload/恢复事务，而不是直接覆盖 live：

```bash
sudo bash -s -- '/etc/caddy/Caddyfile.manual-backup.实际时间.实际后缀' <<'BASH'
source ./easyCaddy.sh
apply_manual_caddyfile "$1"
BASH
```

停止证书自动同步可执行 `sudo systemctl disable --now easy-caddy-cert-sync.timer`；若同时卸载辅助文件，停止后删除 `/etc/systemd/system/easy-caddy-cert-sync.{service,timer}` 与 `/usr/local/lib/easy-caddy/easyCaddy.sh`，再执行 `sudo systemctl daemon-reload`。这些操作不删除已导出的副本、不修改 Caddy storage；登记和目录设置保留时以后可重新安装任务。代码回滚时先停 timer，再恢复事前备份的 `easyCaddy.sh`；回滚不会从旧注册表重建手工配置。


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

