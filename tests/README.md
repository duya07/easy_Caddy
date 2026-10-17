# 配置管理回归测试

这些测试是开发工具，运行需要 Linux、Bash、Python 3 和对应的 Caddy/nginx 二进制。部署 easyCaddy.sh 或 easy_nginx.sh 不需要 Python。

在已准备好引擎的开发环境运行：

```bash
python3 tests/regression.py --component all \
  --caddy-bin /usr/bin/caddy \
  --nginx-bin /usr/sbin/nginx \
  --evidence-dir /tmp/easy-caddy-regression
```

也可以用 `--component caddy` 或 `--component nginx` 只检查一个脚本，或指向已解包的 nginx 二进制，不需要通过本测试安装软件。

测试把脚本中的配置路径映射到各自的临时目录，保留修改前后的文件、驱动程序、引擎校验和服务调用记录。`systemctl` 使用模拟结果；配置解析仍执行真实 `caddy validate` 和 `nginx -t`。测试不启动或重载系统服务，外部下载和包管理命令会被拒绝。

测试覆盖删除边界、目标外内容保持、合法头部或复杂配置的明确拒绝、重复域名、格式错误输入、写入/链接/服务应用失败的一致性，以及 nginx 上游协议和手工设置保持。成功操作须校验实际产物；被明确拒绝的复杂配置须保持原文件和管理记录不变，不能仅凭错误提示判定通过。

退出码非零表示失败或测试环境不完整。缺失引擎、超时和未执行项目不能算作通过。`--evidence-dir` 内生成唯一子目录，运行后可查看 `summary.json` 与各用例材料，再删除整次测试目录。

这套回归验证配置管理结果。实际 HTTPS/IPv6 请求和系统服务部署仍需在专门的测试环境验证，不能根据模拟服务返回值声称生产服务已部署。

## 证书导出与事务式编辑验收

新增 `certificates_editor.py` 是独立验收套件，旧 `regression.py` 保持原样。需要 Linux、Python 3.9+、Bash、OpenSSL、jq、flock 和 Caddy；所有者拒绝案例需要 root（仅在隔离 `/tmp` 中改变 fixture 所有者）。套件不安装软件。Python 仅用于开发测试，部署的 shell 脚本仍无 Python 依赖。

在仓库根目录执行：

```bash
python3 tests/certificates_editor.py \
  --caddy-bin /usr/bin/caddy \
  --evidence-dir /tmp/easy-caddy-certificates-editor-tests
```

用不可变旧产品证明新验收确实会红：

```bash
python3 tests/certificates_editor.py \
  --script /tmp/your-private-copy/backup/easy_Caddy__easyCaddy.sh \
  --caddy-bin /usr/bin/caddy \
  --evidence-dir /tmp/your-private-copy/baseline-evidence
```

`--script` 默认指向测试文件上级仓库的 `easyCaddy.sh`。产品以原始字节复制到各案例并 source，不删函数、不重写产品内容。驱动程序 source 后只重定向旧配置变量，并使用冻结的 `EASY_CADDY_TEST_MODE`、`CADDYFILE`、`PROXY_CONFIG_FILE`、`CERT_STATE_DIR`、`CERT_STORAGE_DIR_OVERRIDE`、`CADDY_SERVICE_HOME_OVERRIDE`、`CADDY_SERVICE_XDG_DATA_HOME_OVERRIDE`、`CERT_WORKER_INSTALL_DIR` 和 `CERT_SYSTEMD_UNIT_DIR` 测试入口。真正的 storage 发现用例会取消固定 storage override。

所有写入位于 `--evidence-dir` 下新建的唯一 `verifier-*` 目录；只允许 `/tmp` 下的证据路径。每个案例保留实际产品副本、shell 驱动、每一步 `.command.json`、原始 `.stdout.txt` / `.stderr.txt` / `.exit.txt`、工具调用 `trace.jsonl`、前后文件哈希/权限/所有者和 `result.json`。整次运行生成 `versions.json`、fixture 生成/校验原始记录及 `summary.json`。私钥 fixture 本身保留在受限测试树，JSON 只记录其哈希与元数据；请把整棵证据目录当作含私钥的材料妥善管理。

状态有三类：`passed` 是行为断言通过；`failed` 是接口缺失、产品行为不符或产品超时；`error` 是 fixture/依赖/框架异常。退出码 0 表示所有案例通过，1 表示至少一例 failed/error，2 表示前置环境或 fixture 构造失败。基线红必须检查 `error=0` 和原始失败原因，不能把依赖缺失或框架异常当作新功能缺失证据。

修正版 v2 在同一固定旧版 `easy_Caddy__easyCaddy.sh`（SHA256 `19b2990d3e39a2cccdb65cccd31cfff11d16537b6d14e06c57b2c6bb16c2389e`）和隔离 Linux 测试主机的成员独占 `/tmp` 重跑 124 例：14 passed、110 failed、0 error，退出码 1。真实红包括菜单缺 8、source 运行菜单、未知/同步 CLI 不满足行为要求、两反代入口 yes 不登记同步、选择/目录阶段 EOF 仍提交。14 个通过案例是旧版两入口各自已有的 no/空行、最早输入 EOF、重复域名、validate/reload 失败回退行为；不表示新证书与编辑功能通过。完整报告和 v1/v2 归档索引见 [verifier/BASELINE.md](../../easy_Caddy-certificates-editor/verifier/BASELINE.md)。本轮最终测试源码冻结 SHA256 为 `d7c61aaeee1441edb2e8844022160beae77d9ab7c9ee3ead7f1e79dacb7c137d`。

v2 的透明工具包装保持 Bash 动态锁描述符；每次运行先执行直接 flock、wrapper flock 和 sudo wrapper flock 的正对照，失败按前置框架错误停止。存储发现的配置 fixture 在调用产品前先执行独立真实 Caddy adapt，正确 fixture 若解析失败按 `error` 报告。v1 原始红证据完整保留；两处框架修复来自不依赖产品的 Linux 最小对照，未降低验收要求。

覆盖范围：

- 主菜单 12/13 的真实进程派发（原历史编号 8/9）、source 安全、非交互同步 CLI / 未知 CLI；本地/远程反代的 yes、现有目录、新目录、no、空行、各阶段 EOF、重复域名、validate/reload/timer 安装失败。
- 真实 RSA/EC 公钥配对与 PEM 链字节保持、多 issuer 到期时间/签发时间/字典序选择、未签发 pending、过期/未来/错 SAN/错 key、续期更新和 unchanged 不重写。
- 服务 HOME/XDG、含空格的定制 file_system root、服务停止、引用服务环境模板、adapt 失败、未知模块/策略 storage、不确定 HOME。未知模块与策略分支使用明确标注的 synthetic adapt JSON；其他发现案例执行真实 Caddy adapt。
- 独立设置与登记、规范化/幂等、命令与控制字符注入、symlink/hardlink/所有者/不安全既有对象、源文件字节和权限保护、写入失败保持旧有效 pair、目录变更、不登记不导出、只关闭指定域名、同步与目录/登记变更的锁串行化。
- 仅成功 opt-in 建立一分钟 service/timer 与单文件快照；前台进程退出且原脚本删除后，由快照在新进程同步，再由独立新进程同步续期证书。
- 手动编辑和非交互 apply：真实 validate、唯一备份、owner/mode 保持、no-change、editor 非零、坏/消失/链接/非普通草稿、VISUAL 优先与安全 argv、外部改动冲突、reload 失败恢复及恢复 reload 再失败、reload 期间外部改动保护、坏草稿留存与旧注册表字节保持。

`systemctl`、`journalctl` 和外部探测使用隔离模拟，定时器安装只检查受限目录内的单位文件和模拟 enable 调用，未实际安装系统 timer。写入/rename/reload 故障在工具边界注入；用例要求故障实际命中，未命中不能通过。同步并发使用 OpenSSL 调用屏障，读证书/导出文件/权限与 Caddy validate 都是真实 Linux 行为。此套件中的“退出后同步”证明快照与非交互 CLI 可独立运行，不声称模拟 systemctl 实际启动了后台任务。

最终验收还必须运行真实内部 CA、高端口 TLS/延迟签发整合和以下旧回归；这些不能用新套件中的模拟服务结果替代：

```bash
python3 tests/regression.py --component caddy \
  --caddy-bin /usr/bin/caddy \
  --evidence-dir /tmp/easy-caddy-certificates-editor-legacy
```

修复前 `a26645bf9bac4b98ecf1ce035a14d359f5badae3640c10c9ecc29dc800941424` 的 t5 独立 Linux 实跑：原 124/124、旧 Caddy 30/30、补充重复安装/空登记 2/2；三个真实内部 CA 存储布局的签发、原生短周期续期和安装快照导出通过。另用全私有 transient 用户 timer 证明原始副本删除后，首次导出由真实调度的独立进程完成；生产 root 系统 unit 的安装仍为模拟，不能将该证明扩大为生产部署/重启保证。

**这不是最终批准。** 正式 t6 已证实原 124 未覆盖的相对 import 编辑校验基址错误（T6-R1）和 imported `{$VAR}` 使用管理环境导致错误 storage 根（T6-R2），所以 t5 整体 `needs_revision`。历史报告/原始证据索引见 [verifier/FINAL.md](../../easy_Caddy-certificates-editor/verifier/FINAL.md) 和 `verifier/final/t5.verdict.json`。修复版须新增 import/env 回归并绑定新的冻结 SHA 做独立最终验收，不能用本次旧版绿色结果替代。

### v3 import 回归（原 124 + 新增 16 = 140 例）

默认 CLI 不变，v3 在原 124 例后追加 `I3-*`，原函数、全局包装、callback 和断言保持不变；独立 AST 回读工具会核对其与 D7/v2 的一致性。D7 副本和新的基线材料保存在 [verifier/import-regression](../../easy_Caddy-certificates-editor/verifier/import-regression)。v3 源码 SHA256 为 `4b50cccad0bfcd55df2fb1dbadb3210c3b99dbde85a20370f3d3eac9edc351cb`。

- `apply_manual_caddyfile` 和 `manual_edit_caddyfile` 各 6 例：relative 显式文件、relative glob、合法空 glob、显式 included 坏语法、glob included 坏语法、缺失显式文件。每例先以真实 stock Caddy 校验原文件及同目录候选；fixture 若与预期不符按框架 error 停止该例。候选成功须实际提交并保留 included 文件/registry/owner/mode，失败须保持 live 且不得 reload。
- direct/nested imported storage 各比较管理变量不同/缺失，共 4 例。`systemctl MainPID` 指向隔离 sleep 进程，读取真实 `/proc/PID/environ` 的 NUL 记录，选取必要服务值后独立真实 `caddy adapt`；另适配管理环境作对照。产品可以返回准确服务根，或明确非零诊断拒绝，不能成功返回管理根或错误 HOME 默认根。不会打印、序列化进程环境正文；无关环境 sentinel 若出现在产品输出即失败。

官方 [import 文档](https://caddyserver.com/docs/caddyfile/directives/import) 规定相对文件/glob 以包含 import 的文件为基址，缺失显式文件是错误，空 glob 不是错误。因此 glob 正例即使基址错误也可能静默为空；实际坏 included 的 glob 负例专门检查这个漏洞。这里只在 `/tmp` 运行真实解析器，service/reload 仍模拟；t12 还须对修复 SHA 跑完整 140、旧 30 和真实内部 CA/worker 整合。

固定修复前 `a266…` 的完整 v3 实跑为 **134 passed / 6 failed / 0 error，exit 1**：原 124 全通过；新增红例为两个编辑接口各自的合法 relative import 拒绝与坏 included glob 漏读，以及 direct/nested imported storage 返回管理根。两个空 glob 案例及管理环境变量缺失后明确非零拒绝的案例都按契约通过。测试构建 gate PASS，产品仍 RED；逐类正负对照、冻结字节和公开 raw archive SHA 见 [v3 import 报告](../../easy_Caddy-certificates-editor/verifier/import-regression/REPORT.md)。


## t12 修复版独立验收

固定产品9c577eb10b9066a39c535829659e04d64342f4d33f63d290d8b9a28515d8ab52，冻结v3 suite 4b50cccad0bfcd55df2fb1dbadb3210c3b99dbde85a20370f3d3eac9edc351cb，v4 native driver d52d4309fe5d71629aef52bd4578dd41380ed70a52b66f0d6684eb434fcbeef2。独立Linux完整140/140、旧Caddy30/30、安装补充2/2和真实三布局worker签发/原生续期均通过；新增16个import正负控制包含在140例内。

私有副本还以实际transient USER timer证明前台退出/原copy删除后首次导出发生在手动worker之前；正式root unit安装仍mock，用户timer加速1秒/2秒不代表生产一分钟/重启已验证。sameSHA的正式t13十类proc/literal控制原包读回继承：4正确根、6显式拒绝、0误根成功、0命令执行。

可复查报告：`../../easy_Caddy-certificates-editor/verifier/final-repair/REPORT.md`（相对本 tests 目录），附run/inspection/collection receipts、package-manifest和原始公共包。包SHA d8c5a32c0eb72ceb9460311e38fd036ab92a46e7ca82560f748dd053953a54fb，两端一致；1922份日志/JSON无私钥正文，生产SHA/PID/active/TCP+UDP前后一致。完整命令和真实argv/exit位于报告与run.receipt.json。历史baseline D7 14/110/0及a266 v3 134/6/0保持；本轮不改suite断言或旧regression.py。t12只提供绑定该SHA的独立verification，整体审查与集成由t10/captain另作判定。

## CONTRACT-C2 停服环境文件回归

在原 140 例后新增 `D1-storage-stopped-environment-file`，默认命令现在运行 141 例。前述冻结 SHA 和 t12 结果仍是历史证据，不适用于修改后的产品字节。

用例模拟停止的 systemd unit 通过 `EnvironmentFile` 注入 `XDG_DATA_HOME`，用真实 Caddy `environ` 的 `AppDataDir` 作为正对照，要求 `certificate_storage_root` 明确非零诊断、不返回猜测的 HOME 根，并保持配置、登记、导出目录和 worker 不变。环境文件内容仅由测试夹具读取；产品不读取、source 或 eval 该文件。systemd 元数据仍为隔离 mock，不声称已验证正式 systemd unit 部署。

修复对停服默认根采用保守拒绝：`EnvironmentFiles` 非空或查询失败时明确失败；服务运行时仍读取可信进程环境，停止态的 literal storage root 不受此默认根检查影响。

## 管理页面、依赖归属与日志轮转

`operations.py` 在 Linux 独立 `/tmp` 树运行。包管理、systemctl 和 journalctl 使用隔离模拟；记录文件、证书夹具、PTY、logrotate 文件大小/周期判断/归档压缩使用真实工具。传入真实 logrotate 可执行文件或已验证的私有解包包装器：

```bash
python3 tests/operations.py --script /tmp/PRIVATE/easyCaddy.sh --evidence-dir /tmp/PRIVATE/management-tests --logrotate-bin /usr/sbin/logrotate
```

覆盖主菜单新编号、交互清屏与结果暂停、非交互/source；新增安装归属、重复执行、部分失败、取消、默认/全部范围和连带移除拒绝；证书已有信息/空状态先于输入；统一日志与空提示；daily/weekly/monthly 的真实大小和时间轮转、归档压缩、配置启用失败恢复及不安全日志路径拒绝。不会实际安装/卸载测试主机的系统包或更改生产服务。原证书套件仅随主菜单要求把派发 8/9 更新为 12/13、编号存在性更新为 1–13，其他断言保持；旧 Caddy 回归不变。

## 证书申请、续签设置与自然语言体验

`certificate_experience.py` 是新增的独立 Linux 验收入口，需要 root（仅操作独占 `/tmp` 夹具）、Bash、Python 3、OpenSSL、jq、flock 和支持 `renewal_window_ratio` Caddyfile 子指令的 Caddy；本轮真实验证使用 Caddy 2.11.7。2.10.2 对该子指令的明确拒绝另行记录，不把缺少能力当作测试通过。

```bash
python3 tests/certificate_experience.py \
  --script /tmp/PRIVATE/easyCaddy.sh \
  --caddy-bin /usr/bin/caddy \
  --evidence-dir /tmp/PRIVATE/certificate-experience
```

覆盖父目录与两份完整文件路径、重复域名提醒、安全的 `~/` 展开、非 TTY 不等待、按实际有效期换算天数、开启/关闭/重新开启续签、单独申请、首次签发后的窗口更新、重复后台检查不制造备份、关闭后原存储清理仍不重开申请、保留手工 TLS/共享/通配站点、加载失败回退、续签记录保存失败保持或恢复配置、成功解析不刷 warning、错误仍可见、自然语言状态，以及真实 PTY 等待返回/EOF。

Caddy adapt/validate、OpenSSL、文件权限和路径检查使用真实工具；systemctl/journalctl 使用测试目录中的包装器，安装后台任务只验证配置与启用调用，不修改系统 Caddy。每例保留命令、退出状态和输出；`summary.json` 绑定被测脚本 SHA256。

另有真实进程整合：

```bash
python3 tests/certificate_experience_native.py \
  --script /tmp/PRIVATE/easyCaddy.sh \
  --caddy-bin /usr/bin/caddy \
  --evidence-dir /tmp/PRIVATE/certificate-experience-native
```

该入口在独占目录启动私有 Caddy（loopback 随机高端口、内部 CA、跳过系统信任安装），先打开真实 PTY 等待，再启动签发；检查首次签发、自动复制文件与私钥权限、实际运行配置中的续签比例、TLS/SNI/HTTP 响应，以及关闭固定加载/重新开启的真实 reload。进程在 finally 中停止，保留终端原始输出和结果；系统 timer 启用仍模拟，不连接公共 CA，不冒称已验证自然到期后的公共 ACME 续签。

本次默认列表改为自然语言，原 141 例中的全部内部元数据断言由默认列表与显式 `certificate_technical_details` 共同核对；issuer 字典序选择仍核对实际导出 pair 和同步日志中的选择路径。原断言未删除。管理套件只更新父目录提示与自然语言匹配，保留页面切换、结果停留和退出断言；`regression.py` 保持原字节。

## 脚本版本与更新验收

```bash
python3 tests/script_update.py \
  --script /tmp/PRIVATE/easyCaddy.sh \
  --evidence-dir /tmp/PRIVATE/script-update-tests
```

Linux/root 隔离目录中运行，使用真实 Bash、文件权限、备份和原子改名；curl 由受控下载包装器提供正常/异常候选。覆盖版本 CLI、仅检查、成功更新与权限保留、同版/旧版不覆盖、错误页面、语法损坏、身份不符、下载失败、取消/EOF、候选不执行、并发改动保护、符号链接拒绝、替换失败保留原件与备份、主菜单不自动联网，以及更新成功终止旧会话。systemctl/包管理等无关命令被拦截，脚本更新不得调用它们；主菜单只允许读取服务是否运行。

原证书/反代/管理测试文件保持原字节；版本号与菜单14是新增入口，原编号保持。测试报告绑定本轮实际脚本SHA，不用之前版本的PASS冒充本轮结果。
