# easy_Caddy

单文件 Bash 脚本：交互式安装、管理 Caddy 反向代理，附带证书复制同步、日志轮转、依赖账本与事务式配置编辑。仓库另附菜单风格相近的 nginx 版本（`easy_nginx.sh`，见文末）。

- **系统**：Debian / Ubuntu（APT + systemd）
- **权限**：证书与配置编辑操作需 root 执行
- **形态**：只需下载这一个 `.sh` 文件；**使用脚本不需要 Python**（Python 仅用于开发回归测试）

## 快速运行

```bash
curl -o easyCaddy.sh https://raw.githubusercontent.com/duya07/easy_Caddy/refs/heads/main/easyCaddy.sh && chmod +x easyCaddy.sh && sudo bash ./easyCaddy.sh
```

源码仓库：[duya07/easy_Caddy](https://github.com/duya07/easy_Caddy)

## 主菜单

菜单按用途分组，输入编号执行。交互终端会翻页清屏，结果保留到按回车返回；非交互输入/输出不清屏、不暂停，`source` 与 `--sync-certificates` 保持非交互，`TERM=dumb` 不输出清屏控制码。

| 分组 | 编号 | 功能 |
| --- | --- | --- |
| 部署与代理 | `1` | 安装 Caddy（已安装则跳过） |
| | `2` | 依赖检测与安装（仅安装缺失项） |
| | `3` | 配置反向代理（二级菜单，见下） |
| 服务运维 | `4` | 查看 Caddy 服务状态 |
| | `5` | 查看当前反代配置（含上游状态） |
| | `6` | 删除指定的反向代理 |
| | `7` | 重启 Caddy 服务 |
| | `8` | 日志查看（Caddy、证书同步、按域名） |
| | `9` | 日志轮转设置 |
| 维护 | `10` | 卸载 Caddy（删除配置） |
| | `11` | 依赖卸载（默认仅本功能新增项） |
| | `12` | 证书管理（查看 / 复制目录 / 登记 / 同步 / 日志） |
| | `13` | 手动编辑 Caddy 配置（校验后事务应用） |
| | `0` | 退出 |

## 反向代理（菜单 3）

二级菜单提供两种上游：

1. **反代本地端口**：域名 + 本地端口，上游为 `http://127.0.0.1:端口`
2. **反代远程网址**：域名 + 远程网址，上游为 `http(s)://目标网址`（必须带 `http://` / `https://` 前缀，不支持路径、查询串、锚点）

域名为单个主机名或 IP；IPv6 地址用方括号。添加与删除都先校验候选配置，再保存并 reload，失败报错并恢复原文件；删除保留目标站点外的内容，共享地址或边界不清的站点需手动处理。

**已知限制**

- 目标页面里写死的绝对链接、JS 里写死的域名不会被改写（Caddy 没有 nginx `sub_filter` 那类响应体改写能力），站内跳转或静态资源可能仍指向原站，页面不一定完全可用。
- 目标站点可能有 WAF / Cloudflare 反爬 / 地域限制，可能出现 403 或验证码。
- 反代远程网址时，Caddy 会把请求的 Host 头改写为上游主机名（Caddy 2.11 起对 HTTPS 上游默认如此；脚本显式设置以兼容旧版，对 HTTP 上游则改变了原始 Host）。上游依赖原始域名路由或校验时需自行调整 Caddyfile。

## 证书复制与同步（菜单 12）

**这是把 Caddy 已签发的 storage 证书复制到你指定的目录，不是替 Caddy 强制签发。** 签发仍由 Caddy / ACME CA 决定；本功能只导出已经存在的证书，并在你选择开启后用 systemd timer 做一分钟一次的外部轮询同步（不需要 exec 事件插件）。

菜单 12 提供：查看证书与登记状态、设置/修改目的目录、立即同步、查看域名日志、登记域名开启复制、取消复制。

- 每个操作页先展示与当前操作相关的目录、登记/复制状态、已有证书或可查询域名，空数据明确提示；域名操作支持从已有列表选编号或直接输入域名。
- 查看页显示实际存储中的证书、issuer、起止有效期与证书/key 完整路径。
- 修改目录影响随后的同步，旧目录中的副本保留；仅设置目录不会复制所有证书，也不会安装任务。
- 外部手工 `tls` 指令加载的证书文件不属于本功能保证发现的自动 storage 证书。

### 开启方式

添加本地或远程反代时，在域名和上游之后询问是否复制该域名证书：`y`/`yes` 开启，`n`/`no` 或空行不开启；也可在菜单 12 登记已有域名。

- 选择「是」时复用已保存的全局目的目录；尚未设置则当场输入绝对目录（如 `/srv/caddy-certificates`，支持空格）。选择或目录输入遇到 EOF 会取消整个新增流程。
- 只有反代校验、提交并 reload 成功后才保存目录和登记；反代失败不会提前开启复制。
- 已登记域名重新选择「否」会在反代成功后取消该域名登记，其他域名继续同步；取消最后一个域名时 timer 可闲置保留（空登记 worker 直接返回 0，不扫描也不创建文件）。

### 轮询机制

首次成功开启后安装 root 拥有的 `/usr/local/lib/easy-caddy/easyCaddy.sh` 快照与 `easy-caddy-cert-sync.service`/`.timer`（`OnBootSec=1min`、`OnUnitActiveSec=1min`），退出管理脚本或重启机器仍继续检查签发/续期。

实际签发时间由 Caddy/CA 决定；新证书可用后通常在下一次轮询同步，受调度、锁和写入影响。反代成功后导出或安装任务失败会单独报错，反代与登记保留，可手动重试。

### 证书选择规则

- 每次只复制已登记域名中有效、SAN 匹配且公私钥匹配的 leaf/fullchain pair。
- 多 issuer 先过滤坏候选，再按 notAfter → notBefore → 路径字节序选取（这不等于 Caddy 当前连接选中的证书）。
- 内部 CA / staging 证书会显示 issuer，存在不代表公网信任。
- 未签发显示「待签发/未发现」，不等待 ACME。

### 导出与覆盖保护

- 导出保留原 PEM 链顺序，目标为 `<目的目录>/<域名>/fullchain.pem` 与 `privkey.pem`；新目录 `0700`、文件 `0600`，既有目录属性保留、不放宽私钥权限。
- 同步先在同一文件系统暂存并重新验证整对证书/key，再替换域名目录（替换瞬间可能有极短的路径缺口）。
- 坏证书、key 不匹配、过期、源轮换或写入失败时保留旧的正确副本并报错；旧目标损坏、半对、symlink、危险硬链接或不受 root 控制时拒绝覆盖。
- 目的目录须为受控绝对路径，不得与 Caddy storage、配置、登记、worker 或系统单元重叠；路径中的 shell 符号按普通数据处理。
- 原 storage、ACME 账户/CA 私钥不会被移动、删除、改权限或导出。

### storage 目录定位

运行中的 Caddy 按进程环境解析（Linux 默认 `$XDG_DATA_HOME/caddy`，未设置时 `$HOME/.local/share/caddy`；官方 systemd 服务通常是 `/var/lib/caddy/.local/share/caddy`）。global `storage file_system` 的 root 用 `caddy adapt` 的 JSON 解析，支持绝对路径和空格；运行中使用服务进程环境解析 Caddyfile 的 `{$VAR}` / `import`，也可解析 JSON root 里的 `{env.VAR}`。

<details>
<summary>服务停止时的解析规则与明确拒绝的情况</summary>

- 服务**停止**时：主配置含 `{$VAR}` 或 `import` 会因缺少可靠的服务环境而拒绝解析；其余配置可只读查找字面量绝对 root，或依据可信 unit `User`/环境推断默认目录。相对 root 需要运行进程的 cwd，停止态无法解析；推断默认目录时若存在 `EnvironmentFile`，也会明确拒绝猜测。
- **明确拒绝**的情况：未解析的占位符、未知 storage module、TLS automation policy 的 storage 覆盖，以及无法可靠确定服务环境。解析失败会报错退出，不扫描猜测的目录。

</details>

### 手动同步与排障

CLI 单次执行后退出，不进入菜单；指定域名须事先登记：

```bash
sudo bash ./easyCaddy.sh --sync-certificates
sudo bash ./easyCaddy.sh --sync-certificates example.com
sudo systemctl status easy-caddy-cert-sync.timer
sudo journalctl -u easy-caddy-cert-sync.service -n 100 --no-pager
```

登记与目录设置分别在 `/etc/easy-caddy/certificates/export-domains`（每行一个域名）与 `export-directory`（一行目录）：状态目录 `0700`、文件 `0600`，修改经 flock 串行化；同步记录写入 `sync.log`，菜单按域名最多显示最近 200 行，不含私钥正文。旧版 `/root/caddy_reverse_proxies.txt` 的 `domain -> upstream` 注册格式保持兼容。

## 手动编辑配置（菜单 13）

先在 Caddyfile 同目录创建唯一 `.manual-backup.<时间>.<随机后缀>` 备份，再在 `0700` 工作目录编辑候选；保存后先真实 `caddy validate`，再持配置锁核对原文件未被外部改动，通过后保持原 owner/mode 提交并 reload。

- 编辑器取 `VISUAL` → `EDITOR` → 已安装的 nano/vi；允许 `vim -f` 一类简单 argv，拒绝需要 shell 引号、展开或拼接的值。未改内容/取消时不 validate/reload。
- reload 失败会恢复原件并重新加载，恢复失败单独报告，坏草稿与日志保留并打印位置。
- 手工站点不进入自动反代注册表，注册表保持原字节。

**回滚手动编辑**：在脚本所在目录执行（路径替换为实际打印的备份绝对路径；该操作复用同一验证与冲突保护事务，不是直接覆盖）：

```bash
sudo bash -s -- '/etc/caddy/Caddyfile.manual-backup.实际时间.实际后缀' <<'BASH'
source ./easyCaddy.sh
apply_manual_caddyfile "$1"
BASH
```

## 依赖账本与卸载（菜单 2 / 11）

证书与日志功能需要 `jq`、OpenSSL、`flock`（util-linux）、GNU coreutils/findutils、logrotate 等。菜单 2 显示已安装/缺失状态，仅安装缺失项；直接使用证书菜单缺依赖时明确报错，不在后台安装软件。

**账本规则**（`/var/lib/easy-caddy/dependencies/installed-packages`）：

- 只记录安装计划内、安装前不存在而安装后实际存在的包（含必要传递依赖）。
- 重复执行不会把已有包重新认领；部分失败仍记录成功的新包。
- 异常中断留下 pending 快照时拒绝自动认领，并提示先核对。

**菜单 11 卸载**：

- 默认只移除这些新增记录，可主动选择全部相关可卸载依赖。
- 执行前先展示 APT 模拟的具体移除清单并确认，遇到清单外的连带移除则拒绝。
- 不运行 `autoremove`，不默认移除 Caddy 或系统基础/Essential/Protected 包；已有包保留原归属。

## 日志与轮转（菜单 8 / 9）

菜单 8 查看 Caddy 与证书同步任务的 journal，以及同步文件日志和按域名日志，单次最多最近 200 行，空数据明确提示。

菜单 9 为 `/etc/easy-caddy/certificates/sync.log` 设置 **daily / weekly / monthly** 轮转：

| 项 | 值 |
| --- | --- |
| 配置与状态目录 | `/var/lib/easy-caddy/logs/` |
| 保留份数 | 14 份 |
| 提前轮转 | 超过 10 MiB |
| 旧文件 | 压缩保存 |
| 触发 | `easy-caddy-logrotate.timer` 每小时检查 |

配置先经 `logrotate --debug` 校验，写入或启用失败恢复原设置；使用 `copytruncate`，复制与截断之间存在 logrotate 文档所述的短暂并发写窗口。**轮转只覆盖 sync.log**；Caddy 与任务服务的 journal 继续沿用系统现有保留策略，不改全系统 journald。

## 回退与停止

- **停止证书自动同步**：`sudo systemctl disable --now easy-caddy-cert-sync.timer`；若同时卸载辅助文件，停止后删除 `/etc/systemd/system/easy-caddy-cert-sync.{service,timer}` 与 `/usr/local/lib/easy-caddy/easyCaddy.sh`，再 `sudo systemctl daemon-reload`。这些操作不删除已导出副本、不改 Caddy storage；登记与目录设置保留时可重新安装任务。
- **代码回滚**：先停 timer，再恢复事前备份的 `easyCaddy.sh`；回滚不会从旧注册表重建手工配置。
- **卸载 Caddy** 用菜单 10（删除配置），**删除反代**用菜单 6。

## 开发与测试

回归测试是开发工具，运行方式与证据说明见 [tests/README.md](tests/README.md)。测试需要 Linux、Bash、Python 3 和对应的 Caddy/nginx 二进制（使用部署脚本本身不需要 Python）。`systemctl`/`journalctl` 等使用隔离模拟，配置解析执行真实 `caddy validate` / `nginx -t`；**模拟结果不代表生产服务已部署**，实际 HTTPS 请求与系统服务部署需在专门环境验证。

## 附带：nginx 版（easy_nginx.sh）

同仓库附带的 nginx 一键管理脚本，菜单为：1 安装 Nginx、2 添加反代（本地端口 / 远程网址二级菜单）、3 删除反代、4 查看所有配置、5 修改配置、6 重启、7 卸载、8 退出。

```bash
curl -o easy_nginx.sh https://raw.githubusercontent.com/duya07/easy_Caddy/refs/heads/main/easy_nginx.sh && chmod +x easy_nginx.sh && ./easy_nginx.sh
```

nginx 版额外限制（远程上游为 `http(s)://host[:port]`，IPv6 上游用方括号；必须带协议前缀，不支持路径、查询串、锚点或认证信息）：

- `proxy_pass` 域名在启动 / reload 时解析一次并缓存，上游 IP 变化后需 reload 才生效。
- HTTPS 上游靠脚本生成的 `proxy_ssl_server_name on;` 发 SNI；缺该指令时多站点上游会返回默认站点或拒绝连接。
- nginx 默认不验证 HTTPS 上游证书（`proxy_ssl_verify` 默认 off）；需要校验的部署自行配置 `proxy_ssl_verify on` 与 `proxy_ssl_trusted_certificate`。Caddy 的 HTTPS 上游默认验证证书。
- 「反向代理（菜单 3）」下「已知限制」列出的三条（写死的绝对链接 / JS 域名不改写、WAF / 反爬 / 地域限制、Host 头改写为上游主机名）对 nginx 版同样适用——nginx 版生成的配置同样把 Host 设为上游主机名。
- nginx 修改配置保留手工设置；无法确定目标代理位置时拒绝修改。
