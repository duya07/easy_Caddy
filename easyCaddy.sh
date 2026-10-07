#!/usr/bin/env bash
# caddy_proxy_tool.sh
# 功能：
#   1) 自动安装/卸载 Caddy
#   2) 配置反向代理（本地端口 / 远程网址）
#   3) 查看 Caddy 服务状态（在菜单界面显示）
#   4) 查看当前反向代理配置，并显示上游服务是否在运行
#   5) 删除指定的反向代理配置
#   6) 重启 Caddy 服务
#   7) 一键删除 Caddy（卸载并删除配置文件）
# 适用于 Debian/Ubuntu 系列系统

# Caddyfile 默认路径
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_CONFIG_DIR="/etc/caddy"
BACKUP_CADDYFILE="${CADDYFILE}.bak"

# 反向代理配置存储
PROXY_CONFIG_FILE="/root/caddy_reverse_proxies.txt"

#--------------------------------------------
# 检查 Caddy 是否已安装
#--------------------------------------------
function check_caddy_installed() {
    if command -v caddy >/dev/null 2>&1; then
        return 0  # 已安装
    else
        return 1  # 未安装
    fi
}

#--------------------------------------------
# 安装 Caddy（官方仓库）
#--------------------------------------------
function install_caddy() {
    echo "开始安装 Caddy..."
    # 安装依赖
    sudo apt-get update
    sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl

    # 添加官方 GPG key
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    # 添加官方源
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | sudo tee /etc/apt/sources.list.d/caddy-stable.list

    # 更新并安装 Caddy
    sudo apt-get update
    sudo apt-get install -y caddy

    if check_caddy_installed; then
        echo "Caddy 安装成功！"
    else
        echo "Caddy 安装失败，请检查日志。"
        exit 1
    fi
}

#--------------------------------------------
# 检查指定端口服务是否在运行
#--------------------------------------------
function check_port_running() {
    local port=$1
    if timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
        echo "运行中"
    else
        echo "未运行"
    fi
}

#--------------------------------------------
# 判断 upstream 是否指向本机回环地址
# 匹配 http(s)://127.0.0.1、http(s)://localhost、http(s)://[::1]，可带或不带端口
#--------------------------------------------
function upstream_is_loopback() {
    local upstream=$1
    case "$upstream" in
        http://127.0.0.1|http://127.0.0.1:*|\
        https://127.0.0.1|https://127.0.0.1:*|\
        http://localhost|http://localhost:*|\
        https://localhost|https://localhost:*|\
        http://\[::1\]|http://\[::1\]:*|\
        https://\[::1\]|https://\[::1\]:*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

#--------------------------------------------
# 从回环 upstream 中取端口号
# 未写明端口且主机名干净时，按协议给默认端口（http=80 / https=443）；
# 端口段非法或主机名解析不出来时返回空串，由调用方如实显示「端口未知」，
# 不再静默回落成 80，避免把「解析失败」显示成「127.0.0.1:80 的状态」。
#--------------------------------------------
function loopback_port() {
    local upstream=$1
    local hostport host
    hostport=${upstream#*://}

    # 明确带端口：IPv6 字面量 [addr]:8080 与普通 host:8080
    if [[ "$hostport" =~ ^\[[^]]*\]:([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    if [[ "$hostport" =~ ^([^:]+):([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[2]}"
        return
    fi

    # 未写明端口：主机名必须是干净的（非空、无空白、无游离冒号；IPv6 需写成 [addr]）
    host="$hostport"
    if [ -z "$host" ] || [[ "$host" == *[[:space:]]* ]]; then
        return
    fi
    if [[ "$host" != \[*\] ]] && [[ "$host" == *:* ]]; then
        return
    fi

    case "$upstream" in
        https://*) echo 443 ;;
        *)         echo 80 ;;
    esac
}

#--------------------------------------------
# 检查远程 upstream 是否可达（带超时，探测失败不影响菜单继续使用）
# 语义说明：这里用 curl -k 探测的是「目标主机是否在线」，不校验证书有效性 ——
#           自签名证书的内网上游也能被如实报告为可达；
#           因此「可达」只代表主机与 HTTP(S) 端口能连上，不代表 Caddy 反代一定成功
#           （Caddy 对 HTTPS 上游默认严格校验证书，证书不被信任时反代仍会失败）。
#--------------------------------------------
function check_remote_upstream() {
    local upstream=$1

    # 优先用 curl：连接超时 2 秒、总超时 4 秒
    if command -v curl >/dev/null 2>&1; then
        if curl -k -s -I -o /dev/null --connect-timeout 2 --max-time 4 "$upstream" 2>/dev/null; then
            echo "可达"
        else
            echo "不可达"
        fi
        return
    fi

    # 没有 curl 时退化为 /dev/tcp 探测主机端口
    local hostport host port
    hostport=${upstream#*://}
    hostport=${hostport%%/*}
    if [[ "$hostport" =~ ^\[[^]]*\]:([0-9]+)$ ]]; then
        host=${hostport%:*}
        port="${BASH_REMATCH[1]}"
    elif [[ "$hostport" =~ ^(.+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        host="$hostport"
        case "$upstream" in
            https://*) port=443 ;;
            *)         port=80 ;;
        esac
    fi
    if timeout 2 bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
        echo "可达"
    else
        echo "不可达"
    fi
}

#--------------------------------------------
# 生成单个反向代理的 Caddyfile 块（本地端口与远程网址共用）
# 注意：{upstream_hostport} 是 Caddy 占位符，printf 的格式串用单引号包裹，
#       不会被 shell 展开或吞掉，必须原样写进 Caddyfile。
#       反代 HTTPS 上游时，Caddy v2.11.0 起会自动把 Host 设为 {upstream_hostport}，
#       而更早的版本不会，因此这里默认就写入 header_up，跨版本都正确（新版只是冗余）。
#--------------------------------------------
function build_proxy_block() {
    local domain=$1
    local upstream=$2
    if upstream_is_loopback "$upstream"; then
        printf '%s {\n    reverse_proxy %s\n}\n' "$domain" "$upstream"
    else
        printf '%s {\n    reverse_proxy %s {\n        header_up Host {upstream_hostport}\n    }\n}\n' "$domain" "$upstream"
    fi
}

#--------------------------------------------
# 校验远程网址输入（不通过时输出错误提示，通过时不输出）
# 要求：必须显式带 http:// 或 https://，且不含 path / query / fragment
#--------------------------------------------
function validate_remote_upstream() {
    local url=$1

    case "$url" in
        http://*|https://*) ;;
        *)
            echo "错误：远程网址必须以 http:// 或 https:// 开头（不接受裸域名），请重新输入。"
            return
            ;;
    esac

    local rest hostonly portpart
    rest=${url#*://}

    # 含空白字符（如 "https://a.com b.com"）会让生成的 Caddyfile 语法错误，
    # caddy 校验失败后 systemctl restart 也会失败，可能连带停掉原有站点，必须拒掉
    case "$rest" in
        *[[:space:]]*)
            echo "错误：远程网址不能包含空格等空白字符，请重新输入。"
            return
            ;;
    esac

    # 含 userinfo（"https://user:pass@host"）不是 Caddy upstream 支持的写法
    case "$rest" in
        *@*)
            echo "错误：远程网址不能包含用户名/密码（@），请只输入 协议 + 主机名（可带端口）。"
            return
            ;;
    esac

    hostonly=${rest%%[/?#]*}

    if [ -z "$hostonly" ]; then
        echo "错误：远程网址缺少主机名（示例：https://target.example.com），请重新输入。"
        return
    fi

    if [ "$hostonly" != "$rest" ]; then
        echo "错误：远程网址不能包含路径、查询串或锚点（Caddy 的 upstream 地址不支持），请只输入 协议 + 主机名（可带端口）。"
        return
    fi

    # 端口段校验：主机段里出现冒号时，最后一段必须是 1-65535 的数字；
    # 多冒号形式（未加方括号的 IPv6）一律拒绝；
    # [ ] 包裹的 IPv6 字面量（Caddy 支持）单独放行：端口取 ] 之后的部分，
    # 否则 ${hostonly##*:} 会把 IPv6 地址里的冒号误当成端口分隔符而误杀合法上游
    portpart=${hostonly##*:}
    if [[ "$hostonly" == \[* ]]; then
        portpart=""
        if [[ "$hostonly" =~ ^\[[^]]*\]:([0-9]{1,5})$ ]]; then
            portpart="${BASH_REMATCH[1]}"
        elif [[ ! "$hostonly" =~ ^\[[^]]*\]$ ]]; then
            echo "错误：远程网址的主机名格式不正确（IPv6 字面量应写成 [地址] 或 [地址]:端口），请重新输入。"
            return
        fi
    elif [ "$portpart" == "$hostonly" ]; then
        # 主机段里没有端口（不含冒号），无需端口校验
        portpart=""
    else
        if [[ "$hostonly" == *:*:* ]]; then
            echo "错误：远程网址的主机名格式不正确（IPv6 请勿直接写在主机位置），请重新输入。"
            return
        fi
    fi
    if [ -n "$portpart" ] && { ! [[ "$portpart" =~ ^[0-9]{1,5}$ ]] || [ "$portpart" -lt 1 ] || [ "$portpart" -gt 65535 ]; }; then
        echo "错误：远程网址的端口必须是 1-65535 之间的数字，请重新输入。"
        return
    fi
}

#--------------------------------------------
# 写入配置并生效（本地端口与远程网址共用）
#--------------------------------------------
function apply_reverse_proxy() {
    local domain=$1
    local upstream=$2
    local port
    local cfg_line cfg_domain

    # 同一域名不允许重复配置：否则 Caddyfile 里会出现两个同名 site 块，
    # Caddy 遇到重复 site 地址的行为不可预期。这里按 " -> " 前的字段做精确比较
    # （不是子串匹配），避免把 sub.example.com 误判成已配置的 example.com。
    if [ -f "$PROXY_CONFIG_FILE" ]; then
        while IFS= read -r cfg_line; do
            cfg_domain="${cfg_line%% -> *}"
            if [ "$cfg_domain" = "$domain" ]; then
                echo "错误：域名 ${domain} 已配置，请先用菜单 5 删除后再添加。"
                return
            fi
        done < "$PROXY_CONFIG_FILE"
    fi

    # 检查 Caddyfile 是否备份过，没有则备份一下
    if [ ! -f "$BACKUP_CADDYFILE" ]; then
        sudo cp "$CADDYFILE" "$BACKUP_CADDYFILE"
    fi

    # 添加新的反向代理配置到 Caddyfile
    echo "配置反向代理：${domain} -> ${upstream}"
    build_proxy_block "$domain" "$upstream" | sudo tee -a "$CADDYFILE" >/dev/null

    # 将配置信息保存到代理配置列表文件
    echo "${domain} -> ${upstream}" >> "$PROXY_CONFIG_FILE"

    # 重启 Caddy 以应用配置
    echo "正在重启 Caddy 服务以应用新配置..."
    sudo systemctl restart caddy

    # 检查上游服务状态
    if upstream_is_loopback "$upstream"; then
        port=$(loopback_port "$upstream")
        echo "上游服务（127.0.0.1:${port}）状态：$(check_port_running "$port")"
    else
        echo "上游网址（${upstream}）状态：$(check_remote_upstream "$upstream")"
    fi
    echo "Caddy 服务状态："
    sudo systemctl status caddy --no-pager
}

#--------------------------------------------
# 配置反向代理：反代本地端口（输入域名及上游服务端口）
#--------------------------------------------
function setup_reverse_proxy() {
    echo "请输入域名（例如 example.com）："
    read domain
    if [ -z "$domain" ]; then
        echo "域名输入不能为空。"
        return
    fi

    while true; do
        echo "请输入上游服务端口（例如 8080）："
        read port
        if [ -z "$port" ]; then
            echo "端口输入不能为空。"
            return
        fi
        if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo "错误：端口必须是 1-65535 之间的数字（例如 8080），请重新输入。"
            continue
        fi
        break
    done

    apply_reverse_proxy "$domain" "http://127.0.0.1:${port}"
}

#--------------------------------------------
# 配置反向代理：反代远程网址（输入域名及远程网址）
#--------------------------------------------
function setup_reverse_proxy_remote() {
    local upstream=""
    local err=""

    echo "请输入域名（例如 example.com）："
    read domain
    if [ -z "$domain" ]; then
        echo "域名输入不能为空。"
        return
    fi

    while true; do
        echo "请输入远程网址（必须带 http:// 或 https:// 前缀，例如 https://target.example.com）："
        read upstream || { echo "输入结束，已取消。"; return; }
        if [ -z "$upstream" ]; then
            echo "远程网址输入不能为空。"
            continue
        fi
        err=$(validate_remote_upstream "$upstream")
        if [ -n "$err" ]; then
            echo "$err"
            continue
        fi
        break
    done

    apply_reverse_proxy "$domain" "$upstream"
}

#--------------------------------------------
# 反向代理二级菜单
#--------------------------------------------
function reverse_proxy_menu() {
    while true; do
        echo "============================================="
        echo "           配置 & 启用反向代理                "
        echo "============================================="
        echo " 1) 反代本地端口（域名 -> http://127.0.0.1:端口）"
        echo " 2) 反代远程网址（域名 -> https://目标网址）"
        echo " 0) 返回"
        echo "============================================="
        read -p "请输入选项: " proxy_opt || return
        case "$proxy_opt" in
            1)
                setup_reverse_proxy
                ;;
            2)
                setup_reverse_proxy_remote
                ;;
            0)
                return
                ;;
            *)
                echo "无效选项，请重新输入。"
                ;;
        esac
        echo
    done
}

#--------------------------------------------
# 查看 Caddy 服务状态
#--------------------------------------------
function show_caddy_status() {
    if check_caddy_installed; then
        echo "Caddy 服务状态："
        sudo systemctl status caddy --no-pager
    else
        echo "系统中未安装 Caddy。"
    fi
}

#--------------------------------------------
# 查看反向代理配置，并显示上游服务状态
#--------------------------------------------
function show_reverse_proxies() {
    if [ -f "$PROXY_CONFIG_FILE" ]; then
        echo "当前反向代理配置："
        lineno=0
        while IFS= read -r line; do
            # 行号与配置文件物理行号严格一致（删除功能按物理行号定位，不能跳号）
            lineno=$((lineno+1))
            # 空行直接跳过：既不必显示，也不能拿空串去探测
            if [ -z "$line" ]; then
                continue
            fi
            # 解析格式 "域名 -> upstream"，upstream 可能是本地回环地址，也可能是远程网址
            upstream=$(echo "$line" | awk -F' -> ' '{print $2}')
            if [ -z "$upstream" ]; then
                echo "${lineno}) ${line} [配置行格式不正确]"
                continue
            fi
            if upstream_is_loopback "$upstream"; then
                port=$(loopback_port "$upstream")
                if [ -z "$port" ]; then
                    echo "${lineno}) ${line} [本地端口未知（上游地址解析不出端口），未探测]"
                else
                    status=$(check_port_running "$port")
                    echo "${lineno}) ${line} [本地端口 ${port}，上游服务状态：$status]"
                fi
            else
                status=$(check_remote_upstream "$upstream")
                echo "${lineno}) ${line} [远程网址，可达性：$status]"
            fi
        done < "$PROXY_CONFIG_FILE"
    else
        echo "没有配置任何反向代理。"
    fi
}

#--------------------------------------------
# 从当前 Caddyfile 中按块删除指定域名的 site 块
# 用法：remove_proxy_block <域名>
# 说明：域名按字面比较（不用正则，域名里的 . 不会被当成通配），
#       并按花括号深度找到配对的 }，因此远程块里 reverse_proxy 的嵌套 { } 也能正确处理；
#       其余内容与顺序保持不变；找不到该块时只给提示、不报错。
#--------------------------------------------
function remove_proxy_block() {
    local domain=$1
    local srcfile tmpfile line trimmed
    local in_block=0 depth=0 removed=0 braces_open braces_close

    if [ ! -f "$CADDYFILE" ]; then
        echo "Caddyfile 不存在（${CADDYFILE}），已跳过。"
        return
    fi

    srcfile=$(mktemp) || return 1
    tmpfile=$(mktemp) || { rm -f "$srcfile"; return 1; }

    # 读取当前 Caddyfile（Caddyfile 属 root 时用 sudo 拷出来读）
    if ! cp "$CADDYFILE" "$srcfile" 2>/dev/null; then
        if ! sudo cp "$CADDYFILE" "$srcfile" 2>/dev/null; then
            echo "无法读取 Caddyfile（${CADDYFILE}），已跳过。"
            rm -f "$srcfile" "$tmpfile"
            return
        fi
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$in_block" -eq 0 ]; then
            # 只认行首（允许前导空白）精确为 "<域名> {" 的那一行
            trimmed="${line#"${line%%[![:space:]]*}"}"
            if [ "$trimmed" = "${domain} {" ] || [ "$trimmed" = "${domain}{" ]; then
                in_block=1
                depth=1
                removed=1
                continue
            fi
            printf '%s\n' "$line" >> "$tmpfile"
        else
            # 块内：按花括号深度找配对的 }（嵌套的 { } 一并计数）。
            # 这里用 tr 计数而不是参数扩展：参数扩展里用 } 做字符类（${line//[^}]/}）
            # 时，bash 会把那个 } 当成 ${...} 的结束符导致解析错位，实测结果是往
            # 替换结果里多塞进一个 "]/}"，于是删除后会残留一个孤立的 }。
            braces_open=$(printf '%s' "$line" | tr -cd '{' | wc -c)
            braces_close=$(printf '%s' "$line" | tr -cd '}' | wc -c)
            depth=$((depth + braces_open - braces_close))
            if [ "$depth" -le 0 ]; then
                in_block=0
            fi
        fi
    done < "$srcfile"

    if [ "$removed" -eq 1 ]; then
        if ! cp "$tmpfile" "$CADDYFILE" 2>/dev/null; then
            sudo cp "$tmpfile" "$CADDYFILE"
        fi
    else
        echo "Caddyfile 中未找到域名 ${domain} 的配置块，已跳过。"
    fi

    rm -f "$srcfile" "$tmpfile"
}

#--------------------------------------------
# 删除指定的反向代理
#--------------------------------------------
function delete_reverse_proxy() {
    local target_domain
    show_reverse_proxies
    echo "请输入要删除的反向代理配置编号："
    read proxy_number
    if [ -z "$proxy_number" ]; then
        echo "无效的输入。"
        return
    fi

    # 先取出该编号对应的域名，用于稍后从 Caddyfile 里按块删除
    target_domain=$(sed -n "${proxy_number}p" "$PROXY_CONFIG_FILE" | awk -F' -> ' '{print $1}')
    if [ -z "$target_domain" ]; then
        echo "配置文件中没有第 ${proxy_number} 行，已跳过。"
        return
    fi

    # 删除配置列表里对应的行
    sed -i "${proxy_number}d" "$PROXY_CONFIG_FILE"

    # 只从当前 Caddyfile 里删除这一个域名的 site 块。
    # 注意：这里不再从 .bak 整体恢复再把剩余块重新追加 —— 那会把用户在脚本外
    # 对 Caddyfile 做的改动（自己加的站点、注释等）一起回滚掉。
    echo "正在从 Caddyfile 中删除 ${target_domain} 的配置块..."
    remove_proxy_block "$target_domain"

    # 重启 Caddy 服务
    echo "重启 Caddy 服务..."
    sudo systemctl restart caddy
    echo "反向代理删除成功！"
}

#--------------------------------------------
# 重启 Caddy 服务
#--------------------------------------------
function restart_caddy() {
    echo "正在重启 Caddy 服务..."
    sudo systemctl restart caddy
    echo "Caddy 服务已重启。"
    sudo systemctl status caddy --no-pager
}

#--------------------------------------------
# 一键删除 Caddy（卸载并删除配置）
#--------------------------------------------
function remove_caddy() {
    echo "确定要卸载 Caddy 并删除配置文件吗？(y/n)"
    read confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 停止并卸载
        sudo systemctl stop caddy
        sudo apt-get remove --purge -y caddy

        # 删除仓库源
        sudo rm -f /etc/apt/sources.list.d/caddy-stable.list
        sudo apt-get update

        # 删除配置文件
        if [ -f "$BACKUP_CADDYFILE" ]; then
            sudo rm -f "$CADDYFILE" "$BACKUP_CADDYFILE"
        else
            sudo rm -f "$CADDYFILE"
        fi

        # 删除反向代理配置文件
        if [ -f "$PROXY_CONFIG_FILE" ]; then
            sudo rm -f "$PROXY_CONFIG_FILE"
        fi

        echo "Caddy 已卸载并删除配置文件。"
    else
        echo "操作已取消。"
    fi
}

#--------------------------------------------
# 显示菜单（顶部显示 Caddy 运行状态）
#--------------------------------------------
function show_menu() {
    echo "============================================="
    # 显示 Caddy 运行状态
    caddy_status=$(systemctl is-active caddy 2>/dev/null)
    if [ "$caddy_status" == "active" ]; then
        echo "Caddy 状态：运行中"
    else
        echo "Caddy 状态：未运行"
    fi
    echo "           Caddy 一键部署 & 管理脚本          "
    echo "============================================="
    echo " 1) 安装 Caddy（如已安装则跳过）"
    echo " 2) 配置 & 启用反向代理（反代本地端口 / 远程网址）"
    echo " 3) 查看 Caddy 服务状态"
    echo " 4) 查看当前反向代理配置（显示上游服务状态）"
    echo " 5) 删除指定的反向代理"
    echo " 6) 重启 Caddy 服务"
    echo " 7) 卸载 Caddy（删除配置）"
    echo " 0) 退出"
    echo "============================================="
}

#--------------------------------------------
# 主循环
#--------------------------------------------
while true; do
    show_menu
    read -p "请输入选项: " opt || break
    case "$opt" in
        1)
            if check_caddy_installed; then
                echo "Caddy 已安装，跳过安装。"
            else
                install_caddy
            fi
            ;;
        2)
            if ! check_caddy_installed; then
                echo "Caddy 未安装，先执行安装步骤。"
                install_caddy
            fi
            reverse_proxy_menu
            ;;
        3)
            show_caddy_status
            ;;
        4)
            show_reverse_proxies
            ;;
        5)
            delete_reverse_proxy
            ;;
        6)
            restart_caddy
            ;;
        7)
            remove_caddy
            ;;
        0)
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo "无效选项，请重新输入。"
            ;;
    esac
    echo
done
