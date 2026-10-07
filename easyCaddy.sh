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
#--------------------------------------------
# 输入仅接受单个 DNS 主机/IP 与 http(s) authority，不让输入成为配置语法。
#--------------------------------------------
function valid_proxy_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

function valid_ipv4_literal() {
    local address=$1 part
    local -a parts
    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a parts <<< "$address"
    for part in "${parts[@]}"; do
        [[ ${#part} -le 3 ]] && (( 10#$part <= 255 )) || return 1
    done
}

function valid_ipv6_literal() {
    local address=$1 left right group suffix
    local -a groups
    if [[ "$address" == *.* ]]; then
        suffix=${address##*:}
        valid_ipv4_literal "$suffix" || return 1
        address="${address%:*}:0:0"
    fi
    [[ "$address" =~ ^[[:xdigit:]:]+$ && "$address" == *:* ]] || return 1
    if [[ "$address" == *::* ]]; then
        left=${address%%::*}
        right=${address#*::}
        [[ "$right" != *::* && "$left" != *: && "$right" != :* ]] || return 1
        address="${left}${left:+:}${right}"
        if [ -z "$address" ]; then return 0; fi
        IFS=: read -r -a groups <<< "$address"
        [ "${#groups[@]}" -lt 8 ] || return 1
    else
        [[ "$address" != :* && "$address" != *: ]] || return 1
        IFS=: read -r -a groups <<< "$address"
        [ "${#groups[@]}" -eq 8 ] || return 1
    fi
    for group in "${groups[@]}"; do
        [[ "$group" =~ ^[[:xdigit:]]{1,4}$ ]] || return 1
    done
}

function validate_proxy_domain() {
    local host=$1 label
    local -a labels
    if [[ "$host" == \[*\] ]]; then
        valid_ipv6_literal "${host:1:${#host}-2}" && return 0
    elif [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        valid_ipv4_literal "$host" && return 0
    elif [[ ${#host} -le 253 && "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.?$ ]]; then
        host=${host%.}
        IFS=. read -r -a labels <<< "$host"
        for label in "${labels[@]}"; do
            if [[ ! "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ || ${#label} -gt 63 ]]; then
                echo "错误：域名的标签格式不正确。"
                return 1
            fi
        done
        return 0
    fi
    echo "错误：请输入单个合法域名或 IP，不能包含路径、端口或配置语法。"
    return 1
}

function validate_remote_upstream() {
    local url=$1 authority host port=""
    case "$url" in
        http://*|https://*) authority=${url#*://} ;;
        *) echo "错误：远程网址必须以 http:// 或 https:// 开头。"; return 1 ;;
    esac
    if [[ "$authority" == \[* ]]; then
        if [[ "$authority" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
            host=${BASH_REMATCH[1]}
            port=${BASH_REMATCH[3]}
            if ! valid_ipv6_literal "$host"; then
                echo "错误：IPv6 主机地址不正确。"; return 1
            fi
        else
            echo "错误：IPv6 authority 应为 [地址] 或 [地址]:端口。"; return 1
        fi
    else
        if [[ "$authority" =~ ^([^:]+)(:([0-9]+))?$ ]]; then
            host=${BASH_REMATCH[1]}
            port=${BASH_REMATCH[3]}
            validate_proxy_domain "$host" || return 1
        else
            echo "错误：网址必须是 协议 + 主机名（可带数字端口），不能含空主机或空端口。"; return 1
        fi
    fi
    if [ -n "$port" ] && ! valid_proxy_port "$port"; then
        echo "错误：端口必须是 1-65535 之间的数字。"; return 1
    fi
    return 0
}

#--------------------------------------------
# awk 只定位词法 token 的字节范围；真正的裁剪由 head/tail 完成，保留 EOF/CRLF。
# 花括号仅在独立的未引用 token 时计入结构；引号/反引号/占位符不是块边界。
# 顶层 import、动态地址、共享地址及不完整边界无法安全编辑时失败。
# mode=check: 无重复返回0，有目标返回10；mode=delete: 输出开始/结束字节。
#--------------------------------------------
function caddy_site_span() {
    local source=$1 domain=$2 mode=$3 size
    size=$(wc -c < "$source") || return 1
    LC_ALL=C awk -v wanted="${domain,,}" -v mode="$mode" -v total="$size" '
    function error(message) { print "错误：" message > "/dev/stderr"; bad=1 }
    function host(address, position) {
        address=tolower(address)
        sub(/^https?:\/\//, "", address)
        sub(/\/.*/, "", address)
        if (substr(address,1,1)=="[") {
            position=index(address,"]")
            if (!position) return ""
            return substr(address,1,position)
        }
        sub(/:.*/, "", address)
        sub(/\.$/, "", address)
        return address
    }
    function emit(value, quoted, finish, n, parts, j, target, addresses) {
        if (!quoted && value ~ /^<</) error("不支持 heredoc 多行内容，拒绝自动编辑。")
        if (!quoted && value=="{") {
            if (depth==0) {
                target=0; addresses=0
                for (j=1;j<=headers;j++) {
                    if (header[j]=="import" || header[j] ~ /[{}]/) error("不能安全识别顶层 import 或动态地址。")
                    n=split(header[j],parts,",")
                    for (k=1;k<=n;k++) if (parts[k]!="") {
                        addresses++
                        if (host(parts[k])==wanted) target=1
                    }
                }
                if (target) {
                    found++
                    if (addresses!=1) error("目标在多地址共享站点中，拒绝删除别名。")
                    if (mode=="delete" && header[1] !~ /^(https?:\/\/)?[^/]+$/) error("不能安全删除带路径的站点。")
                    begin=header_start
                }
                deleting=target
                headers=0
            }
            depth++
        } else if (!quoted && value=="}") {
            depth--
            if (depth<0) error("Caddyfile 块边界不完整。")
            if (depth==0 && deleting) {
                if (substr(text,finish+1) !~ /^[ \t\r]*(#.*)?$/) error("目标结束行包含其他内容，拒绝编辑。")
                end=line_end
                deleting=0
            }
        } else if (depth==0) {
            if (headers==0) {
                if (substr(text,1,token_start-1) !~ /^[ \t\r]*$/) error("站点头与其他内容共用一行，拒绝编辑。")
                header_start=offset
            }
            header[++headers]=value
            if (value=="import") error("顶层 import 可能包含站点，拒绝自动编辑。")
        }
    }
    BEGIN { sub(/\.$/, "", wanted); depth=0; quote=""; token=""; offset=0 }
    {
        text=$0; line_end=offset+length(text)
        if (line_end<total) line_end++
        for (i=1;i<=length(text);i++) {
            c=substr(text,i,1)
            if (quote!="") {
                if (quote=="\"" && c=="\\") {
                    i++; if (i>length(text)) error("不支持跨行转义的引号内容。")
                    else token=token substr(text,i,1)
                } else if (c==quote) {
                    quote=""; in_quote=1
                } else token=token c
                continue
            }
            if (c ~ /[ \t\r]/) {
                if (started) { emit(token,in_quote,i-1); token=""; started=0; in_quote=0 }
            } else if (c=="#" && !started) {
                break
            } else if (c=="\"" || c=="`") {
                if (started) error("不能安全识别混合引用 token。")
                if (!started) token_start=i
                quote=c; started=1; in_quote=1
            } else {
                if (in_quote) error("引用 token 后缺少分隔符。")
                if (!started) token_start=i
                started=1; token=token c
            }
        }
        if (quote=="") {
            if (started) emit(token,in_quote,length(text))
            token=""; started=0; in_quote=0
        } else token=token "\n"
        offset=line_end
    }
    END {
        if (quote!="" || depth!=0 || headers!=0) error("Caddyfile 词法/块边界不完整，未编辑。")
        if (bad) exit 2
        if (mode=="check") { if (found) exit 10; exit 0 }
        if (found!=1) { error("未找到唯一目标站点，未编辑。"); exit 2 }
        print begin, end
    }' "$source"
}

function caddy_prepare_transaction() {
    local work=$1
    if [ ! -f "$CADDYFILE" ] || ! sudo cp -p "$CADDYFILE" "$work/original.caddy"; then
        echo "错误：无法读取现有 Caddyfile。"; return 1
    fi
    if [ -e "$PROXY_CONFIG_FILE" ]; then
        if [ ! -f "$PROXY_CONFIG_FILE" ] || ! sudo cp -p "$PROXY_CONFIG_FILE" "$work/original.registry"; then
            echo "错误：无法读取注册表。"; return 1
        fi
        : > "$work/had-registry" || return 1
    else
        : > "$work/original.registry" || return 1
    fi
    cp -p "$work/original.caddy" "$work/candidate.caddy" &&
        cp -p "$work/original.registry" "$work/candidate.registry"
}

function caddy_restore_transaction() {
    local work=$1 reload_attempted=$2 failed=0
    sudo cp -p "$work/original.caddy" "$CADDYFILE" || failed=1
    if [ -f "$work/had-registry" ]; then
        sudo cp -p "$work/original.registry" "$PROXY_CONFIG_FILE" || failed=1
    else
        sudo rm -f "$PROXY_CONFIG_FILE" || failed=1
    fi
    if [ "$reload_attempted" -eq 1 ] && ! sudo systemctl reload caddy; then
        echo "错误：原文件已尝试恢复，但重新加载原配置失败，服务状态需确认。"
        failed=1
    fi
    if [ "$failed" -ne 0 ]; then
        echo "错误：恢复未完整完成，恢复材料保留在：$work"
    else
        echo "错误：变更失败，原配置和注册表已恢复。"
        sudo rm -rf "$work"
    fi
    return 1
}

function caddy_commit_transaction() {
    local work=$1
    if ! sudo caddy validate --adapter caddyfile --config "$work/candidate.caddy"; then
        echo "错误：候选 Caddyfile 校验失败，原文件未改动。"
        sudo rm -rf "$work"; return 1
    fi
    # 拒绝覆盖读取快照后发生的外部变更。
    if ! sudo cmp -s "$work/original.caddy" "$CADDYFILE" ||
        { [ -f "$work/had-registry" ] && ! sudo cmp -s "$work/original.registry" "$PROXY_CONFIG_FILE"; } ||
        { [ ! -f "$work/had-registry" ] && [ -e "$PROXY_CONFIG_FILE" ]; }; then
        echo "错误：配置或注册表已被其他操作改动，未提交。"
        sudo rm -rf "$work"; return 1
    fi
    if [ ! -e "$BACKUP_CADDYFILE" ] && ! sudo cp -p "$work/original.caddy" "$BACKUP_CADDYFILE"; then
        echo "错误：无法创建首次备份，原配置未改动；恢复材料：$work"
        return 1
    fi
    if ! sudo cp "$work/candidate.caddy" "$CADDYFILE"; then
        echo "错误：提交 Caddyfile 失败。"
        caddy_restore_transaction "$work" 0; return 1
    fi
    if ! sudo cp "$work/candidate.registry" "$PROXY_CONFIG_FILE"; then
        echo "错误：提交注册表失败。"
        caddy_restore_transaction "$work" 0; return 1
    fi
    if ! sudo systemctl reload caddy; then
        echo "错误：Caddy reload 失败。"
        caddy_restore_transaction "$work" 1; return 1
    fi
    sudo rm -rf "$work"
    return 0
}

#--------------------------------------------
# 写入配置并生效（本地端口与远程网址共用）
#--------------------------------------------
function apply_reverse_proxy() {
    local domain=$1 upstream=$2 work cfg_line cfg_domain wanted rc port
    validate_proxy_domain "$domain" || return 1
    validate_remote_upstream "$upstream" || return 1
    work=$(mktemp -d) || { echo "错误：无法创建配置暂存目录。"; return 1; }
    if ! caddy_prepare_transaction "$work"; then
        sudo rm -rf "$work"; return 1
    fi
    wanted=${domain,,}; wanted=${wanted%.}
    while IFS= read -r cfg_line || [ -n "$cfg_line" ]; do
        [ -z "$cfg_line" ] && continue
        cfg_domain=${cfg_line%% -> *}
        cfg_domain=${cfg_domain,,}; cfg_domain=${cfg_domain%.}
        if [ "$cfg_domain" = "$wanted" ]; then
            echo "错误：域名 ${domain} 已配置，请先删除后再添加。"
            sudo rm -rf "$work"; return 1
        fi
    done < "$work/original.registry"
    caddy_site_span "$work/original.caddy" "$domain" check
    rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 10 ]; then echo "错误：当前 Caddyfile 已存在域名 ${domain}。"; fi
        sudo rm -rf "$work"; return 1
    fi
    if ! {
        if [ -s "$work/candidate.caddy" ] && [ -n "$(tail -c 1 "$work/candidate.caddy")" ]; then printf '\n'; fi
        build_proxy_block "$domain" "$upstream"
    } >> "$work/candidate.caddy"; then
        echo "错误：生成候选配置失败。"; sudo rm -rf "$work"; return 1
    fi
    if ! {
        if [ -s "$work/candidate.registry" ] && [ -n "$(tail -c 1 "$work/candidate.registry")" ]; then printf '\n'; fi
        printf '%s -> %s\n' "$domain" "$upstream"
    } >> "$work/candidate.registry"; then
        echo "错误：生成候选注册表失败。"; sudo rm -rf "$work"; return 1
    fi
    caddy_commit_transaction "$work" || return 1
    echo "反向代理配置成功：${domain} -> ${upstream}"
    if upstream_is_loopback "$upstream"; then
        port=$(loopback_port "$upstream")
        echo "上游服务（127.0.0.1:${port}）状态：$(check_port_running "$port")"
    else
        echo "上游网址（${upstream}）状态：$(check_remote_upstream "$upstream")"
    fi
    return 0
}

#--------------------------------------------
# 配置反向代理：反代本地端口（输入域名及上游服务端口）
#--------------------------------------------
function setup_reverse_proxy() {
    local domain port
    echo "请输入域名（例如 example.com）："
    IFS= read -r domain || { echo "输入结束，已取消。"; return 1; }
    validate_proxy_domain "$domain" || return 1
    while true; do
        echo "请输入上游服务端口（例如 8080）："
        IFS= read -r port || { echo "输入结束，已取消。"; return 1; }
        if ! valid_proxy_port "$port"; then
            echo "错误：端口必须是 1-65535 之间的数字，请重新输入。"
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
    local domain upstream err
    echo "请输入域名（例如 example.com）："
    IFS= read -r domain || { echo "输入结束，已取消。"; return 1; }
    validate_proxy_domain "$domain" || return 1
    while true; do
        echo "请输入远程网址（必须带 http:// 或 https:// 前缀，例如 https://target.example.com）："
        IFS= read -r upstream || { echo "输入结束，已取消。"; return 1; }
        if ! err=$(validate_remote_upstream "$upstream"); then
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
    local lineno line upstream port status
    if [ -f "$PROXY_CONFIG_FILE" ]; then
        echo "当前反向代理配置："
        lineno=0
        while IFS= read -r line || [ -n "$line" ]; do
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
#       按原始字节保留目标外内容；找不到唯一目标或不能安全识别时返回失败。
#--------------------------------------------
function caddy_copy_without_range() {
    local source=$1 candidate=$2 begin=$3 end=$4
    [[ "$begin" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] && [ "$end" -ge "$begin" ] || return 1
    { head -c "$begin" "$source" && tail -c "+$((end + 1))" "$source"; } > "$candidate"
}

function remove_proxy_block() {
    local domain=$1 source=${2:-} candidate=${3:-} work span begin end
    validate_proxy_domain "$domain" || return 1
    if [ "$#" -eq 1 ]; then
        work=$(mktemp -d) || return 1
        if ! caddy_prepare_transaction "$work" ||
            ! remove_proxy_block "$domain" "$work/original.caddy" "$work/candidate.caddy"; then
            sudo rm -rf "$work"; return 1
        fi
        caddy_commit_transaction "$work"
        return $?
    fi
    [ "$#" -eq 3 ] && [ -f "$source" ] || return 1
    span=$(caddy_site_span "$source" "$domain" delete) || return 1
    read -r begin end <<< "$span"
    caddy_copy_without_range "$source" "$candidate" "$begin" "$end"
}

#--------------------------------------------
# 删除指定的反向代理
#--------------------------------------------
function delete_reverse_proxy() {
    local proxy_number work line target_domain span begin end size
    show_reverse_proxies
    echo "请输入要删除的反向代理配置编号："
    IFS= read -r proxy_number || { echo "输入结束，已取消。"; return 1; }
    if [[ ! "$proxy_number" =~ ^[0-9]{1,9}$ ]] || (( 10#$proxy_number < 1 )); then
        echo "错误：请输入有效的数字编号。"; return 1
    fi
    proxy_number=$((10#$proxy_number))
    work=$(mktemp -d) || return 1
    if ! caddy_prepare_transaction "$work"; then sudo rm -rf "$work"; return 1; fi
    line=$(sed -n "${proxy_number}p" "$work/original.registry")
    if [[ "$line" != *" -> "* ]]; then
        echo "错误：该编号不存在或注册表行格式不正确。"; sudo rm -rf "$work"; return 1
    fi
    target_domain=${line%% -> *}
    if ! remove_proxy_block "$target_domain" "$work/original.caddy" "$work/candidate.caddy"; then
        echo "错误：未能安全删除目标，配置和注册表未改动。"; sudo rm -rf "$work"; return 1
    fi
    size=$(wc -c < "$work/original.registry") || { sudo rm -rf "$work"; return 1; }
    span=$(LC_ALL=C awk -v selected="$proxy_number" -v total="$size" '
        BEGIN { offset=0 }
        { end=offset+length($0); if (end<total) end++; if (NR==selected) print offset,end; offset=end }
    ' "$work/original.registry")
    read -r begin end <<< "$span"
    if ! caddy_copy_without_range "$work/original.registry" "$work/candidate.registry" "$begin" "$end"; then
        echo "错误：生成候选注册表失败。"; sudo rm -rf "$work"; return 1
    fi
    caddy_commit_transaction "$work" || return 1
    echo "反向代理删除成功！"
    return 0
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
