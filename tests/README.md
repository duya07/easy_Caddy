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
