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

# Production ignores environment-supplied test paths. Source callers can still set paths after loading.
if [ "${EASY_CADDY_TEST_MODE:-0}" = 1 ]; then
    CADDYFILE=${CADDYFILE:-/etc/caddy/Caddyfile}
    PROXY_CONFIG_FILE=${PROXY_CONFIG_FILE:-/root/caddy_reverse_proxies.txt}
    CERT_STATE_DIR=${CERT_STATE_DIR:-/etc/easy-caddy/certificates}
    CERT_WORKER_INSTALL_DIR=${CERT_WORKER_INSTALL_DIR:-/usr/local/lib/easy-caddy}
    CERT_SYSTEMD_UNIT_DIR=${CERT_SYSTEMD_UNIT_DIR:-/etc/systemd/system}
else
    CADDYFILE=/etc/caddy/Caddyfile
    PROXY_CONFIG_FILE=/root/caddy_reverse_proxies.txt
    CERT_STATE_DIR=/etc/easy-caddy/certificates
    CERT_WORKER_INSTALL_DIR=/usr/local/lib/easy-caddy
    CERT_SYSTEMD_UNIT_DIR=/etc/systemd/system
    unset CERT_STORAGE_DIR_OVERRIDE CADDY_SERVICE_HOME_OVERRIDE CADDY_SERVICE_XDG_DATA_HOME_OVERRIDE
fi
CADDY_CONFIG_DIR=$(dirname -- "$CADDYFILE")
BACKUP_CADDYFILE="${CADDYFILE}.bak"

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
    sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl jq openssl util-linux

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
    if [ "$reload_attempted" -eq 1 ] && ! sudo cmp -s "$work/candidate.caddy" "$CADDYFILE"; then
        echo "错误：reload失败后live已有外部变动，未覆盖；恢复材料：$work" >&2
        return 1
    fi
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

# The adapter resolves imports relative to its input file, not the shell cwd.
# Keep a private validation copy beside live; never place candidate bytes in live.
function caddy_validate_live_context() (
    local candidate=$1 validation
    validation=$(sudo mktemp "$(dirname -- "$CADDYFILE")/.easy-caddy-validate.XXXXXX") || return 1
    trap 'sudo rm -f -- "$validation"' EXIT
    sudo cp -- "$candidate" "$validation" || return 1
    sudo caddy validate --adapter caddyfile --config "$validation"
)

function caddy_commit_transaction() (
    umask 077
    local work=$1
    caddy_config_lock || return 1
    if ! caddy_validate_live_context "$work/candidate.caddy"; then
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
)

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
    certificate_collect_choice || return 1
    apply_reverse_proxy "$domain" "http://127.0.0.1:${port}" || return 1
    certificate_after_proxy "$domain"
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
    certificate_collect_choice || return 1
    apply_reverse_proxy "$domain" "$upstream" || return 1
    certificate_after_proxy "$domain"
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
    echo " 8) 证书管理（查看/复制目录/异步同步/日志）"
    echo " 9) 手动编辑 Caddy 配置（候选校验及事务应用）"
    echo " 0) 退出"
    echo "============================================="
}

#--------------------------------------------
# 证书导出：运行环境发现、受限数据文件、每域名单次同步
# 不执行配置数据；不读取 acme/pki 目录中的账户或 CA 私钥。
#--------------------------------------------
function certificate_error() { printf '错误：%s\n' "$*" >&2; }

function certificate_dependencies() {
    local tool missing=0
    for tool in caddy jq openssl flock realpath stat date sha256sum find cp mv cmp mktemp; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            certificate_error "缺少依赖 $tool（安装 jq、openssl、util-linux、coreutils 和 Caddy）。"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ]
}

function certificate_absolute_path() {
    local path=$1 part current=/ normalized
    [[ "$path" == /* && ! "$path" =~ [[:cntrl:]] ]] || {
        certificate_error "需要不含控制字符的绝对路径：$path"; return 1;
    }
    # 先检查原输入中的祖先，再规范化；link/.. 不能隐藏被经过的链接。
    local -a parts
    IFS=/ read -r -a parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [ -z "$part" ] && continue
        current=${current%/}/$part
        if [ -L "$current" ]; then
            certificate_error "拒绝 symlink 路径：$current"; return 1
        fi
    done
    normalized=$(realpath -ms -- "$path") || return 1
    # 逐段检查，包括尚未创建的路径的现有祖先；不跟随符号链接。
    current=/
    IFS=/ read -r -a parts <<< "${normalized#/}"
    for part in "${parts[@]}"; do
        [ -z "$part" ] && continue
        current=${current%/}/$part
        if [ -L "$current" ]; then
            certificate_error "拒绝 symlink 路径：$current"; return 1
        fi
    done
    printf '%s\n' "$normalized"
}

function certificate_safe_file() {
    local file=$1
    [ -f "$file" ] && [ ! -L "$file" ] &&
        [ "$(stat -c %h -- "$file" 2>/dev/null)" = 1 ]
}

function certificate_controlled_path() {
    local path=$1 current=$1 mode uid
    certificate_absolute_path "$path" >/dev/null || return 1
    while [ "$current" != / ]; do
        if [ -e "$current" ]; then
            [ -d "$current" ] || { certificate_error "不是目录：$current"; return 1; }
            uid=$(stat -c %u -- "$current") || return 1
            mode=$(stat -c %a -- "$current") || return 1
            # root 的受限工作树；共享 /tmp 的 sticky bit 不允许替换 root 的子目录。
            if [ "$uid" != 0 ] || { (( (8#$mode & 0022) != 0 )) &&
                ! { [ "$current" = /tmp ] && (( (8#$mode & 01000) != 0 )); }; }; then
                certificate_error "目录不由 root 安全控制：$current"; return 1
            fi
        fi
        current=${current%/*}; [ -n "$current" ] || current=/
    done
}

# Service environment stays literal data in a subshell. Never eval it or print it.
function caddy_adapt_service_environment() (
    set +x
    local pid=$1 entry variable executable env_executable declaration
    shift
    executable=$(command -v caddy) || return 1
    env_executable=$(command -v env) || return 1
    set -- "$executable" "$1" "$env_executable"
    [ "$pid" -gt 0 ] && [ -r "/proc/$pid/environ" ] || {
        certificate_error '无法可靠读取运行 Caddy 服务环境，未执行 adapt。'; return 1;
    }
    while IFS= read -r variable; do
        export -n "$variable" || {
            certificate_error '无法隔离管理环境，未执行 adapt。'; return 1;
        }
    done < <(compgen -e)
    while IFS= read -r -d '' entry; do
        [[ "$entry" =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]] || {
            certificate_error '运行服务环境有无法安全处理的变量名称，未执行 adapt。'; return 1;
        }
        if [[ "$entry" = _=* ]]; then
            set -- "$1" "$2" "$3" "${entry#_=}"
        else
            variable=${entry%%=*}
            case "$variable" in
                pid|entry|variable|executable|env_executable|declaration|BASH*|RANDOM|SRANDOM|SECONDS|LINENO|HISTCMD|EPOCH*)
                    certificate_error '服务环境键与 Shell 内部状态冲突，无法可靠解析；未执行 adapt。'
                    return 1 ;;
            esac
            declaration=$(declare -p "$variable" 2>/dev/null) || declaration=''
            if [ -n "$declaration" ] && [[ ! "$declaration" =~ ^declare\ (-x|--)\  ]]; then
                certificate_error '服务环境键具有特殊 Shell 属性，无法按原值安全解析；未执行 adapt。'
                return 1
            fi
            export "$entry" || {
                certificate_error '无法设置运行服务环境，未执行 adapt。'; return 1;
            }
        fi
    done < "/proc/$pid/environ" || {
        certificate_error '读取运行服务环境失败，未执行 adapt。'; return 1;
    }
    # Bash would inject its executable into _. GNU env can preserve its real
    # service value (or absence) without exposing the complete environment.
    if [ "$#" -eq 4 ]; then
        exec "$3" "_=$4" "$1" adapt --adapter caddyfile --config "$2"
    else
        exec "$3" -u _ "$1" adapt --adapter caddyfile --config "$2"
    fi
)

function certificate_storage_root() {
    local tool json module root pid entry home='' xdg='' service_env environment_files token user cwd
    for tool in caddy jq realpath; do
        command -v "$tool" >/dev/null 2>&1 || { certificate_error "缺少依赖 $tool。"; return 1; }
    done
    if [ "${EASY_CADDY_TEST_MODE:-0}" = 1 ] && [ -n "${CERT_STORAGE_DIR_OVERRIDE:-}" ]; then
        certificate_absolute_path "$CERT_STORAGE_DIR_OVERRIDE"
        return $?
    fi
    [ -r "$CADDYFILE" ] || { certificate_error "无法读取 Caddyfile：$CADDYFILE"; return 1; }
    pid=$(systemctl show caddy --property=MainPID --value 2>/dev/null) || pid=0
    [[ "$pid" =~ ^[0-9]+$ ]] || pid=0
    if [ "$pid" -gt 0 ]; then
        json=$(caddy_adapt_service_environment "$pid" "$CADDYFILE") || {
            certificate_error '无法使用运行服务环境解析 Caddyfile/import，未扫描证书。'; return 1;
        }
    else
        # Imports may introduce parse-time variables even when the main file has
        # none. A stopped service has no authoritative process environment.
        if grep -qF '{$' "$CADDYFILE" || grep -Eq '(^|[[:space:]])import([[:space:]]|$)' "$CADDYFILE"; then
            certificate_error 'Caddy 服务未运行，无法可靠解析 Caddyfile/import 的服务环境；未扫描证书。'
            return 1
        fi
        json=$(caddy adapt --adapter caddyfile --config "$CADDYFILE") || {
            certificate_error 'Caddy adapt 失败，未扫描证书。'; return 1;
        }
    fi
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$json"; then
        certificate_error 'Caddy adapt 未返回有效 JSON。'; return 1
    fi
    if jq -e 'any(.apps.tls.automation.policies[]?; .storage != null)' >/dev/null <<< "$json"; then
        certificate_error '不支持 TLS automation policy storage 覆盖的证书导出。'; return 1
    fi
    module=$(jq -er 'if .storage == null then "file_system" else .storage.module end | select(type == "string")' <<< "$json") || {
        certificate_error '无法识别 storage module。'; return 1;
    }
    [ "$module" = file_system ] || { certificate_error "不支持该 storage 导出：$module"; return 1; }
    root=$(jq -er '(.storage.root // "") | select(type == "string")' <<< "$json") || return 1
    if [ -n "$root" ]; then
        local reference variable value resolved=0
        while [[ "$root" =~ \{env\.([a-zA-Z_][a-zA-Z0-9_]*)\} ]]; do
            reference=${BASH_REMATCH[0]}; variable=${BASH_REMATCH[1]}; value=''
            [ "$pid" -gt 0 ] && [ -r "/proc/$pid/environ" ] || {
                certificate_error 'storage root 环境占位符无法取得运行服务环境。'; return 1;
            }
            while IFS= read -r -d '' entry; do
                if [[ "$entry" = "$variable="* ]]; then value=${entry#*=}; break; fi
            done < "/proc/$pid/environ"
            [ -n "$value" ] && [[ "$value" != *'{'* && "$value" != *'}'* ]] || {
                certificate_error "storage root 引用的服务变量未定义或未解析：$variable"; return 1;
            }
            root=${root//"$reference"/"$value"}
            resolved=$((resolved+1)); [ "$resolved" -le 16 ] || return 1
        done
        [[ "$root" != *'{'* && "$root" != *'}'* ]] || {
            certificate_error 'storage root 含未解析占位符，未扫描。'; return 1;
        }
        if [[ "$root" != /* ]]; then
            [ "$pid" -gt 0 ] && cwd=$(readlink -e "/proc/$pid/cwd") || {
                certificate_error '相对 storage root 无法确定运行进程 cwd。'; return 1;
            }
            root=$cwd/$root
        fi
        [ "$pid" -gt 0 ] || printf '提示：Caddy 服务未运行，按 literal storage root 只读查找。\n' >&2
        certificate_absolute_path "$root"
        return $?
    fi
    if [ "${EASY_CADDY_TEST_MODE:-0}" = 1 ] && [ -n "${CADDY_SERVICE_HOME_OVERRIDE:-}" ]; then
        home=$CADDY_SERVICE_HOME_OVERRIDE
        xdg=${CADDY_SERVICE_XDG_DATA_HOME_OVERRIDE:-}
    elif [ "$pid" -gt 0 ]; then
        [ -r "/proc/$pid/environ" ] || { certificate_error '无法读取 Caddy 进程环境。'; return 1; }
        while IFS= read -r -d '' entry; do
            case "$entry" in HOME=*) home=${entry#HOME=} ;; XDG_DATA_HOME=*) xdg=${entry#XDG_DATA_HOME=} ;; esac
        done < "/proc/$pid/environ"
    else
        # 仅接受无需 shell 解析的 unit 环境。不能推断管理脚本的 HOME/XDG。
        # A stopped service has no process environment to resolve EnvironmentFile overrides.
        environment_files=$(systemctl show caddy --property=EnvironmentFiles --value 2>/dev/null) || {
            certificate_error '无法读取服务 EnvironmentFile 来源，未扫描证书。'; return 1
        }
        if [[ "$environment_files" =~ [^[:space:]] ]]; then
            certificate_error '服务未运行，EnvironmentFile 环境无法可靠解析；未扫描证书。'
            return 1
        fi
        service_env=$(systemctl show caddy --property=Environment --value 2>/dev/null) || return 1
        [[ "$service_env" != *[\"\'\\]* ]] || { certificate_error '服务未运行，unit 环境无法安全解析。'; return 1; }
        local -a service_values
        read -r -a service_values <<< "$service_env"
        for token in "${service_values[@]}"; do
            case "$token" in HOME=*) home=${token#HOME=} ;; XDG_DATA_HOME=*) xdg=${token#XDG_DATA_HOME=} ;; esac
        done
        user=$(systemctl show caddy --property=User --value 2>/dev/null) || user=''
        if [ -z "$home" ] && [ -n "$user" ]; then
            home=$(getent passwd "$user" | cut -d: -f6)
        fi
        [ -n "$home" ] || { certificate_error '服务未运行，无法确定可信 HOME/XDG 数据目录。'; return 1; }
        printf '提示：Caddy 服务未运行，依据 service User/unit 环境推断数据目录。\n' >&2
    fi
    if [ -n "$xdg" ]; then root=$xdg/caddy
    elif [ -n "$home" ]; then root=$home/.local/share/caddy
    else certificate_error 'Caddy 进程没有可信 HOME/XDG_DATA_HOME，未扫描。'; return 1
    fi
    certificate_absolute_path "$root"
}

function certificate_validate_destination() {
    local path root protected
    path=$(certificate_absolute_path "$1") || return 1
    case "$path" in /|/etc|/usr|/var|/root|/tmp|/home|/opt|/srv|/bin|/sbin|/lib|/lib64|/run|/proc|/sys|/dev)
        certificate_error "目的目录过于宽泛：$path"; return 1 ;; esac
    certificate_controlled_path "$path" || return 1
    root=$(certificate_storage_root) || return 1
    if [[ "$path" = "$root" || "$path" = "$root/"* || "$root" = "$path/"* ]]; then
        certificate_error '目的目录与 Caddy storage 重叠。'; return 1
    fi
    for protected in "$CADDYFILE" "$PROXY_CONFIG_FILE" "$CERT_STATE_DIR" "$CERT_WORKER_INSTALL_DIR" "$CERT_SYSTEMD_UNIT_DIR"; do
        protected=$(realpath -ms -- "$protected") || return 1
        if [[ "$path" = "$protected" || "$path" = "$protected/"* || "$protected" = "$path/"* ]]; then
            certificate_error "目的目录与受保护路径重叠：$protected"; return 1
        fi
    done
    printf '%s\n' "$path"
}

function certificate_state_prepare() {
    [ "$EUID" -eq 0 ] || { certificate_error '证书设置/同步需要 root；请用 sudo bash easyCaddy.sh。'; return 1; }
    certificate_controlled_path "$CERT_STATE_DIR" || return 1
    if [ ! -d "$CERT_STATE_DIR" ]; then mkdir -p -m 700 -- "$CERT_STATE_DIR" || return 1; fi
    local file mode
    for file in "$CERT_STATE_DIR/export-directory" "$CERT_STATE_DIR/export-domains" "$CERT_STATE_DIR/sync.lock" "$CERT_STATE_DIR/sync.log"; do
        if [ -e "$file" ] || [ -L "$file" ]; then
            mode=$(stat -c %a -- "$file") || return 1
            certificate_safe_file "$file" && [ "$(stat -c %u -- "$file")" = 0 ] && (( (8#$mode & 0022) == 0 )) || {
                certificate_error "状态对象不安全：$file"; return 1;
            }
        fi
    done
}

function certificate_read_directory() {
    local path extra
    certificate_safe_file "$CERT_STATE_DIR/export-directory" || { certificate_error '尚未设置安全的证书目的目录。'; return 1; }
    { IFS= read -r path || [ -n "$path" ]; } < "$CERT_STATE_DIR/export-directory" || return 1
    if [ "$(awk 'END {print NR}' "$CERT_STATE_DIR/export-directory")" != 1 ]; then
        certificate_error '目录设置必须只有一行。'; return 1
    fi
    [ -n "$path" ] || { certificate_error '证书目的目录为空。'; return 1; }
    printf '%s\n' "$path"
}

function certificate_read_domains() {
    local domain canonical
    [ -e "$CERT_STATE_DIR/export-domains" ] || { [ ! -L "$CERT_STATE_DIR/export-domains" ]; return $?; }
    certificate_safe_file "$CERT_STATE_DIR/export-domains" || { certificate_error '域名登记对象不安全。'; return 1; }
    while IFS= read -r domain || [ -n "$domain" ]; do
        [ -n "$domain" ] || continue
        validate_proxy_domain "$domain" >/dev/null || { certificate_error "畸形域名登记：$domain"; return 1; }
        canonical=${domain,,}; canonical=${canonical%.}
        [ "$canonical" = "$domain" ] || { certificate_error "域名登记未规范化：$domain"; return 1; }
        printf '%s\n' "$domain"
    done < "$CERT_STATE_DIR/export-domains"
}

function set_certificate_export_directory() (
    umask 077
    local path lock_fd stage
    path=$(certificate_validate_destination "$1") || return 1
    certificate_state_prepare || return 1
    exec {lock_fd}> "$CERT_STATE_DIR/sync.lock" || return 1
    flock -x -w 20 "$lock_fd" || { certificate_error '证书状态锁暂忙。'; return 1; }
    stage=$(mktemp "$CERT_STATE_DIR/.directory.XXXXXX") || return 1
    if ! printf '%s\n' "$path" > "$stage" || ! mv -f -- "$stage" "$CERT_STATE_DIR/export-directory"; then
        rm -f -- "$stage"; certificate_error '目的目录设置保存失败。'; return 1
    fi
    printf '证书目的目录已保存：%s\n' "$path"
)

function certificate_update_registration() (
    umask 077
    local domain=$1 operation=$2 lock_fd domains line stage
    validate_proxy_domain "$domain" >/dev/null || { certificate_error '无效导出域名。'; return 1; }
    domain=${domain,,}; domain=${domain%.}
    if [ "$operation" = remove ] && [ ! -e "$CERT_STATE_DIR/export-domains" ]; then return 0; fi
    certificate_state_prepare || return 1
    exec {lock_fd}> "$CERT_STATE_DIR/sync.lock" || return 1
    flock -x -w 20 "$lock_fd" || { certificate_error '证书状态锁暂忙。'; return 1; }
    domains=$(certificate_read_domains) || return 1
    stage=$(mktemp "$CERT_STATE_DIR/.domains.XXXXXX") || return 1
    while IFS= read -r line; do
        [ -n "$line" ] && [ "$line" != "$domain" ] && printf '%s\n' "$line"
    done <<< "$domains" > "$stage"
    if [ "$operation" = add ]; then printf '%s\n' "$domain" >> "$stage" || return 1; fi
    if ! LC_ALL=C sort -u -o "$stage" "$stage" || ! mv -f -- "$stage" "$CERT_STATE_DIR/export-domains"; then
        rm -f -- "$stage"; certificate_error '导出登记保存失败。'; return 1
    fi
)
function register_certificate_export() { certificate_update_registration "$1" add; }
function unregister_certificate_export() { certificate_update_registration "$1" remove; }

# 输出：notAfter epoch、notBefore epoch；其余元信息在调用者显示。
function certificate_pair_valid() {
    local cert=$1 key=$2 domain=$3 allow_expired=${4:-0} before after now cert_public key_public san
    certificate_safe_file "$cert" && certificate_safe_file "$key" || {
        certificate_error "缺 key 或不安全的证书/key 文件：$cert / $key"; return 1;
    }
    certificate_absolute_path "$cert" >/dev/null && certificate_absolute_path "$key" >/dev/null || return 1
    before=$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null) &&
        after=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null) || {
        certificate_error "坏 PEM 证书：$cert"; return 1;
    }
    before=$(date -d "${before#notBefore=}" +%s) && after=$(date -d "${after#notAfter=}" +%s) || return 1
    now=$(date +%s)
    [ "$allow_expired" = 1 ] || { [ "$before" -le "$now" ] && [ "$now" -lt "$after" ]; } || {
        certificate_error "证书过期或尚未生效：$cert"; return 1;
    }
    san=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null) || return 1
    [[ "$san" = *'Subject Alternative Name'* ]] || { certificate_error "证书缺 SAN：$cert"; return 1; }
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$domain" = *:* ]]; then
        if [ "$(LC_ALL=C openssl x509 -in "$cert" -noout -checkip "$domain" 2>/dev/null)" != "IP $domain does match certificate" ]; then
            certificate_error "SAN/IP 不匹配：$cert"; return 1
        fi
    else
        [[ "$san" = *'DNS:'* ]] || { certificate_error "证书缺 DNS SAN：$cert"; return 1; }
        if [ "$(LC_ALL=C openssl x509 -in "$cert" -noout -checkhost "$domain" 2>/dev/null)" != "Hostname $domain does match certificate" ]; then
            certificate_error "SAN/hostname 不匹配：$cert"; return 1
        fi
    fi
    cert_public=$(set -o pipefail; openssl x509 -in "$cert" -noout -pubkey 2>/dev/null |
        openssl pkey -pubin -outform DER 2>/dev/null | sha256sum) || return 1
    key_public=$(set -o pipefail; openssl pkey -in "$key" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum) || {
        certificate_error "坏 key PEM 或不可读取 key：$key"; return 1;
    }
    [ "$cert_public" = "$key_public" ] || { certificate_error "证书与 key 不匹配：$cert"; return 1; }
    printf '%s %s\n' "$after" "$before"
}

function certificate_candidates() {
    local root=$1 domain=${2:-} cert subject issuer
    [ -e "$root" ] || return 0
    [ -d "$root" ] && [ -r "$root" ] && [ -x "$root" ] || {
        certificate_error "无法读取 storage：$root"; return 1;
    }
    [ -e "$root/certificates" ] || return 0
    [ -d "$root/certificates" ] && [ ! -L "$root/certificates" ] || {
        certificate_error 'storage certificates 不是安全目录。'; return 1;
    }
    # 固定三层，保持 subject 路径和 PEM basename 一致；不经过账户或 CA 目录。
    local -a candidates
    mapfile -d '' -t candidates < <(find "$root/certificates" -mindepth 3 -maxdepth 3 -name '*.crt' -print0)
    wait "$!" || { certificate_error '证书目录遍历失败。'; return 1; }
    for cert in "${candidates[@]}"; do
        subject=${cert%/*}; subject=${subject##*/}
        issuer=${cert%/*}; issuer=${issuer%/*}; issuer=${issuer##*/}
        [[ ! "$issuer" =~ [[:cntrl:]] && ! "$subject" =~ [[:cntrl:]] ]] || continue
        validate_proxy_domain "$subject" >/dev/null || continue
        [ "${cert##*/}" = "$subject.crt" ] || continue
        [ -z "$domain" ] || [ "$subject" = "$domain" ] || continue
        printf '%s\0' "$cert"
    done
}

function certificate_log() {
    local domain=$1 status=$2 detail=${3:-}
    printf '%s [%s] %s %s\n' "$(date -u +%FT%TZ)" "$domain" "$status" "$detail" >> "$CERT_STATE_DIR/sync.log"
    printf '[%s] %s %s\n' "$domain" "$status" "$detail"
}

function certificate_sync_domain() {
    local domain=$1 root=$2 dest=$3 cert key times after before selected='' selected_key='' best_after=0 best_before=0 found=0
    local old=$dest/$domain stage rollback meta cert_hash key_hash mode owner group
    local -a candidates
    mapfile -d '' -t candidates < <(certificate_candidates "$root" "$domain")
    wait "$!" || { certificate_log "$domain" 'error' '无法发现证书，旧副本保留。'; return 1; }
    for cert in "${candidates[@]}"; do
        found=1; key=${cert%.crt}.key
        times=$(certificate_pair_valid "$cert" "$key" "$domain") || continue
        read -r after before <<< "$times"
        if [ -z "$selected" ] || [ "$after" -gt "$best_after" ] ||
            { [ "$after" -eq "$best_after" ] && [ "$before" -gt "$best_before" ]; } ||
            { [ "$after" -eq "$best_after" ] && [ "$before" -eq "$best_before" ] && [[ "$cert" < "$selected" ]]; }; then
            selected=$cert; selected_key=$key; best_after=$after; best_before=$before
        fi
    done
    if [ -z "$selected" ]; then
        if [ "$found" -eq 0 ]; then certificate_log "$domain" '待签发/未发现'; return 0; fi
        certificate_log "$domain" 'error' '候选全失效，旧副本保留。'; return 1
    fi
    if [ -e "$old" ] || [ -L "$old" ]; then
        certificate_controlled_path "$old" || return 1
        if [ -n "$(find "$old" -mindepth 1 -maxdepth 1 ! -name fullchain.pem ! -name privkey.pem -print -quit)" ]; then
            certificate_log "$domain" 'error' "域名目录包含未知对象，未覆盖：$old"; return 1
        fi
        if [ -e "$old/fullchain.pem" ] || [ -L "$old/fullchain.pem" ] || [ -e "$old/privkey.pem" ] || [ -L "$old/privkey.pem" ]; then
            if ! certificate_pair_valid "$old/fullchain.pem" "$old/privkey.pem" "$domain" 1 >/dev/null ||
                [ "$(stat -c %u -- "$old/fullchain.pem")" != 0 ] || [ "$(stat -c %u -- "$old/privkey.pem")" != 0 ]; then
                certificate_log "$domain" 'error' "旧目标不安全/损坏，保留原对象：$old"; return 1
            fi
            if cmp -s -- "$selected" "$old/fullchain.pem" && cmp -s -- "$selected_key" "$old/privkey.pem"; then
                certificate_log "$domain" 'already-current' "$selected"; return 0
            fi
        elif [ -n "$(find "$old" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
            certificate_log "$domain" 'error' "域名目录包含未知对象，未覆盖：$old"; return 1
        fi
    fi
    certificate_controlled_path "$dest" || return 1
    if [ ! -d "$dest" ]; then mkdir -p -m 700 -- "$dest" || return 1; fi
    stage=$(mktemp -d "$dest/.pair.XXXXXX") || return 1
    cert_hash=$(sha256sum -- "$selected") && key_hash=$(sha256sum -- "$selected_key") || { rm -rf -- "$stage"; return 1; }
    if ! cp -- "$selected" "$stage/fullchain.pem" || ! cp -- "$selected_key" "$stage/privkey.pem" ||
        ! chmod 600 -- "$stage/fullchain.pem" "$stage/privkey.pem" ||
        ! certificate_pair_valid "$stage/fullchain.pem" "$stage/privkey.pem" "$domain" >/dev/null ||
        [ "$cert_hash" != "$(sha256sum -- "$selected")" ] || [ "$key_hash" != "$(sha256sum -- "$selected_key")" ]; then
        rm -rf -- "$stage"; certificate_log "$domain" 'error' '暂存失败/源轮换，旧副本保留，下一轮重试。'; return 1
    fi
    if [ -d "$old" ]; then
        if [ -f "$old/fullchain.pem" ]; then
            mode=$(stat -c %a -- "$old/privkey.pem") || { rm -rf -- "$stage"; return 1; }
            mode=$(printf '%03o' "$((8#$mode & 0600))")
            if ! chmod --reference="$old/fullchain.pem" -- "$stage/fullchain.pem" ||
                ! chmod "$mode" -- "$stage/privkey.pem" ||
                ! chown --reference="$old/fullchain.pem" -- "$stage/fullchain.pem" ||
                ! chown --reference="$old/privkey.pem" -- "$stage/privkey.pem"; then
                rm -rf -- "$stage"; return 1
            fi
        fi
        # 目录替换可有极短路径缺口；保留现有目录属性，不扩大权限。
        mode=$(stat -c %a -- "$old") && owner=$(stat -c %u -- "$old") && group=$(stat -c %g -- "$old") || { rm -rf -- "$stage"; return 1; }
        chmod "$mode" -- "$stage" && chown "$owner:$group" -- "$stage" || { rm -rf -- "$stage"; return 1; }
        rollback=$(mktemp -d "$dest/.previous.XXXXXX") || { rm -rf -- "$stage"; return 1; }
        rmdir -- "$rollback" || return 1
        if ! mv -T -- "$old" "$rollback"; then rm -rf -- "$stage"; return 1; fi
        if ! mv -T -- "$stage" "$old"; then
            if mv -T -- "$rollback" "$old"; then rm -rf -- "$stage"; certificate_log "$domain" 'error' '提交失败，旧pair已恢复。'
            else certificate_log "$domain" 'error' "恢复失败；旧pair：$rollback，候选：$stage"; fi
            return 1
        fi
        rm -rf -- "$rollback"
    elif ! mv -T -- "$stage" "$old"; then
        rm -rf -- "$stage"; certificate_log "$domain" 'error' 'pair提交失败。'; return 1
    fi
    certificate_log "$domain" 'synced' "issuer/path=$selected notAfter=$(date -u -d "@$best_after" +%FT%TZ)"
}

function sync_certificates() (
    umask 077
    local requested=${1:-} domains root dest domain lock_fd failed=0 selected=0
    if [ -n "$requested" ]; then
        validate_proxy_domain "$requested" >/dev/null || { certificate_error '无效同步域名。'; return 1; }
        requested=${requested,,}; requested=${requested%.}
    fi
    # 无登记直接退出，不创建目录/锁，不启动 Caddy，不等待签发。
    domains=$(certificate_read_domains) || return 1
    [ -n "$domains" ] || return 0
    if [ -n "$requested" ] && ! grep -Fxq -- "$requested" <<< "$domains"; then return 0; fi
    certificate_dependencies && certificate_state_prepare || return 1
    exec {lock_fd}> "$CERT_STATE_DIR/sync.lock" || return 1
    flock -x -w 20 "$lock_fd" || { certificate_error '证书同步锁暂忙。'; return 1; }
    domains=$(certificate_read_domains) || return 1
    root=$(certificate_storage_root) || return 1
    dest=$(certificate_read_directory) && dest=$(certificate_validate_destination "$dest") || return 1
    [ ! -e "$root" ] || { [ -d "$root" ] && [ -r "$root" ] && [ -x "$root" ]; } || { certificate_error "storage 无法读取：$root"; return 1; }
    while IFS= read -r domain; do
        [ -n "$domain" ] || continue
        [ -z "$requested" ] || [ "$requested" = "$domain" ] || continue
        if ! certificate_sync_domain "$domain" "$root" "$dest"; then failed=1; fi
    done <<< "$domains"
    return "$failed"
)

function list_certificates() {
    local root cert subject key issuer count=0 result domains domain dest
    certificate_dependencies || return 1
    root=$(certificate_storage_root) || return 1
    printf 'Caddy storage：%s\n' "$root"
    local -a candidates
    mapfile -d '' -t candidates < <(certificate_candidates "$root")
    wait "$!" || return 1
    for cert in "${candidates[@]}"; do
        count=$((count+1)); subject=${cert%/*}; subject=${subject##*/}; key=${cert%.crt}.key
        issuer=${cert%/*}; issuer=${issuer%/*}; issuer=${issuer##*/}
        printf '\n域名：%s\nissuer目录：%s\n证书：%s\nkey：%s\n' "$subject" "$issuer" "$cert" "$key"
        if certificate_pair_valid "$cert" "$key" "$subject" >/dev/null; then printf '状态：有效且key匹配（不代表公网信任）\n'
        else printf '状态：无效/缺失或不匹配key\n'; fi
        openssl x509 -in "$cert" -noout -issuer -startdate -enddate 2>/dev/null || :
    done
    [ "$count" -ne 0 ] || printf '待签发/未发现已签发证书。\n'
    if [ -f "$CERT_STATE_DIR/export-directory" ]; then
        dest=$(certificate_read_directory) || return 1
        printf '\n导出目的目录：%s\n' "$dest"
    else printf '\n导出目的目录：未设置\n'; fi
    domains=$(certificate_read_domains) || return 1
    if [ -z "$domains" ]; then printf '按域名复制：无登记\n'
    else
        while IFS= read -r domain; do
            printf '已登记：%s（下次同步检查签发/续期）\n' "$domain"
        done <<< "$domains"
    fi
}

function install_certificate_sync_timer() (
    umask 077
    local domains script service timer lock_fd
    domains=$(certificate_read_domains) || return 1
    [ -n "$domains" ] || return 0
    [ "$EUID" -eq 0 ] || { certificate_error '安装自动同步需要 root。'; return 1; }
    command -v systemctl >/dev/null 2>&1 || { certificate_error 'systemd 不可用，自动同步未启用。'; return 1; }
    certificate_state_prepare || return 1
    exec {lock_fd}> "$CERT_STATE_DIR/sync.lock" || return 1
    flock -x -w 20 "$lock_fd" || return 1
    domains=$(certificate_read_domains) || return 1
    [ -n "$domains" ] || return 0
    certificate_controlled_path "$CERT_WORKER_INSTALL_DIR" && certificate_controlled_path "$CERT_SYSTEMD_UNIT_DIR" || return 1
    mkdir -p -m 700 -- "$CERT_WORKER_INSTALL_DIR" "$CERT_SYSTEMD_UNIT_DIR" || return 1
    script=$CERT_WORKER_INSTALL_DIR/easyCaddy.sh
    service=$CERT_SYSTEMD_UNIT_DIR/easy-caddy-cert-sync.service
    timer=$CERT_SYSTEMD_UNIT_DIR/easy-caddy-cert-sync.timer
    local file
    for file in "$script" "$service" "$timer"; do
        if [ -e "$file" ] || [ -L "$file" ]; then
            certificate_safe_file "$file" && [ "$(stat -c %u -- "$file")" = 0 ] || { certificate_error "worker对象不安全：$file"; return 1; }
        fi
    done
    # 快照保留单文件部署；不向 ExecStart 注入目的路径或域名。
    install -m 700 -- "${BASH_SOURCE[0]}" "$script" || return 1
    local escaped=$script
    escaped=${escaped//\\/\\\\}; escaped=${escaped//\"/\\\"}; escaped=${escaped//%/%%}
    {
        printf '[Unit]\nDescription=Synchronise opted-in Caddy leaf certificates\nAfter=caddy.service\n\n[Service]\nType=oneshot\nUser=root\nUMask=0077\n'
        printf 'ExecStart=/bin/bash "%s" --sync-certificates\n' "$escaped"
    } > "$service" || return 1
    printf '[Unit]\nDescription=Check Caddy certificate exports each minute\n\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=1min\nAccuracySec=1s\nUnit=easy-caddy-cert-sync.service\n\n[Install]\nWantedBy=timers.target\n' > "$timer" || return 1
    chmod 600 -- "$service" "$timer" || return 1
    if ! systemctl daemon-reload || ! systemctl enable --now easy-caddy-cert-sync.timer; then
        certificate_error '自动同步未启用；反代及域名登记保留，可手动运行 --sync-certificates。'; return 1
    fi
    printf '自动同步已启用：一分钟检查签发/续期（签发时间取决于 Caddy/CA）。\n'
)

# 只收集输入，数据由成功的反代事务之后提交。
function certificate_collect_choice() {
    CERT_CHOICE=no; CERT_CHOSEN_DIRECTORY=''; CERT_DIRECTORY_IS_NEW=0
    local answer path
    while true; do
        printf '是否将该域名证书复制到指定目录？[y/yes，默认 n]：\n'
        IFS= read -r answer || { printf '输入结束，已取消。\n'; return 1; }
        case "${answer,,}" in y|yes) CERT_CHOICE=yes; break ;; n|no|'') return 0 ;; *) printf '请输入 y/yes 或 n/no。\n' ;; esac
    done
    if [ -e "$CERT_STATE_DIR/export-directory" ]; then
        path=$(certificate_read_directory) || return 1
    else
        printf '请输入证书目的目录（绝对路径，可含空格）：\n'
        IFS= read -r path || { printf '输入结束，已取消。\n'; return 1; }
        CERT_DIRECTORY_IS_NEW=1
    fi
    CERT_CHOSEN_DIRECTORY=$(certificate_validate_destination "$path") || return 1
}

function certificate_after_proxy() {
    local domain=$1 failed=0
    if [ "$CERT_CHOICE" = no ]; then
        unregister_certificate_export "$domain" || {
            certificate_error '反代配置已应用，但旧证书登记取消失败。'; return 1;
        }
        return 0
    fi
    if [ "$CERT_DIRECTORY_IS_NEW" -eq 1 ]; then
        set_certificate_export_directory "$CERT_CHOSEN_DIRECTORY" || {
            certificate_error '反代配置已应用，证书同步未启用（目录设置失败）。'; return 1;
        }
    fi
    register_certificate_export "$domain" || { certificate_error '反代配置已应用，证书登记失败。'; return 1; }
    sync_certificates "$domain" || failed=1
    install_certificate_sync_timer || failed=1
    if [ "$failed" -ne 0 ]; then
        certificate_error '反代配置已应用，证书导出待完成/自动任务安装失败；登记保留供重试。'; return 1
    fi
}

function certificate_show_logs() {
    local domain=$1 output
    validate_proxy_domain "$domain" >/dev/null || return 1
    domain=${domain,,}; domain=${domain%.}
    if [ -f "$CERT_STATE_DIR/sync.log" ] && [ ! -L "$CERT_STATE_DIR/sync.log" ]; then
        tail -n 200 -- "$CERT_STATE_DIR/sync.log" | grep -F -- "[$domain]" || :
    fi
    output=$(journalctl -u caddy -u easy-caddy-cert-sync --no-pager -n 200 2>&1) || {
        certificate_error "journal 读取失败：$output"; return 1;
    }
    printf '%s\n' "$output" | grep -F -- "$domain" || :
}

function certificate_menu() {
    local option path domain
    while true; do
        printf '\n证书管理\n 1) 查看证书、复制目录及登记状态\n 2) 设置/修改目的目录\n 3) 立即同步已登记域名\n 4) 查看域名日志\n 5) 登记现有域名并开启复制\n 6) 取消域名复制\n 0) 返回\n'
        IFS= read -r option || return 0
        case "$option" in
            1) list_certificates ;;
            2) printf '请输入绝对目的目录：\n'; IFS= read -r path || return 0; set_certificate_export_directory "$path" ;;
            3) sync_certificates ;;
            4) printf '请输入域名：\n'; IFS= read -r domain || return 0; certificate_show_logs "$domain" ;;
            5) printf '请输入已配置域名：\n'; IFS= read -r domain || return 0
                validate_proxy_domain "$domain" || continue
                certificate_collect_choice || continue
                certificate_after_proxy "$domain" ;;
            6) printf '请输入域名：\n'; IFS= read -r domain || return 0; unregister_certificate_export "$domain" ;;
            0) return 0 ;;
            *) printf '无效选项。\n' ;;
        esac
    done
}

#--------------------------------------------
# 手动编辑：唯一备份、候选文件、独立 validate、锁下提交/reload/恢复
# 自动注册表保持字节不变；不会重建手工站点。
#--------------------------------------------
function caddy_config_lock() {
    local lock=$CADDYFILE.easy-caddy.lock
    certificate_controlled_path "$(dirname -- "$CADDYFILE")" || return 1
    # noclobber 不会截断另一事务刚创建且持锁的 inode。
    if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
        (umask 077; set -o noclobber; : > "$lock") 2>/dev/null || :
    fi
    certificate_safe_file "$lock" && [ "$(stat -c %u -- "$lock")" = 0 ] || {
        certificate_error "配置锁不安全/无法创建（请以 root 执行）：$lock"; return 1;
    }
    exec {CADDY_LOCK_FD}< "$lock" || { certificate_error '无法打开配置事务锁（请以 root 执行）。'; return 1; }
    flock -x -w 20 "$CADDY_LOCK_FD" || { certificate_error '配置事务锁暂忙。'; return 1; }
}

function caddy_manual_snapshot() {
    local work=$1 backup
    certificate_safe_file "$CADDYFILE" && certificate_absolute_path "$CADDYFILE" >/dev/null || {
        certificate_error "live Caddyfile 不是安全普通文件：$CADDYFILE"; return 1;
    }
    caddy_config_lock || return 1
    # inode、owner、mode、size 和时间戳也参与冲突检查，不只比较内容。
    stat -c '%d:%i:%u:%g:%a:%s:%y:%z' -- "$CADDYFILE" > "$work/original.identity" || return 1
    sudo cp -p -- "$CADDYFILE" "$work/original.caddy" && cp -p -- "$work/original.caddy" "$work/candidate.caddy" || return 1
    backup=$(sudo mktemp "${CADDYFILE}.manual-backup.$(date -u +%Y%m%dT%H%M%S).XXXXXX") || return 1
    if ! sudo cp -p -- "$CADDYFILE" "$backup"; then
        certificate_error "备份创建失败：$backup"; return 1
    fi
    printf '%s\n' "$backup" > "$work/backup-path"
    flock -u "$CADDY_LOCK_FD"
    exec {CADDY_LOCK_FD}<&-
}

function caddy_manual_current_matches() {
    local work=$1 current
    certificate_safe_file "$CADDYFILE" || return 1
    current=$(stat -c '%d:%i:%u:%g:%a:%s:%y:%z' -- "$CADDYFILE") || return 1
    [ "$current" = "$(cat "$work/original.identity")" ] &&
        sudo cmp -s -- "$work/original.caddy" "$CADDYFILE"
}

function caddy_manual_commit() {
    local work=$1 backup identity submitted
    local candidate=$work/candidate.caddy
    backup=$(cat "$work/backup-path") || return 1
    printf '备份：%s\n候选：%s\n' "$backup" "$candidate"
    certificate_safe_file "$candidate" || { certificate_error "候选不是安全普通文件；恢复材料：$work"; return 1; }
    if cmp -s -- "$work/original.caddy" "$candidate"; then
        printf '未修改，无需加载。\n'; rm -rf -- "$work"; return 0
    fi
    if ! caddy_validate_live_context "$candidate" > "$work/validate.log" 2>&1; then
        tail -n 30 -- "$work/validate.log" >&2
        certificate_error "候选 validate 校验失败；live 未改，草稿及日志保留：$work"; return 1
    fi
    caddy_config_lock || return 1
    if ! caddy_manual_current_matches "$work"; then
        certificate_error "Caddyfile 已有外部变动/身份变化，拒绝覆盖；草稿和备份：$work / $backup"; return 1
    fi
    # 提交副本保持 live 的 owner/mode，采用同目录 rename 防止半写入。
    submitted=$(sudo mktemp "${CADDYFILE}.candidate.XXXXXX") || return 1
    if ! sudo cp -p -- "$work/original.caddy" "$submitted" || ! sudo cp -- "$candidate" "$submitted" ||
        ! sudo mv -fT -- "$submitted" "$CADDYFILE"; then
        sudo rm -f -- "$submitted"
        certificate_error "Caddyfile 提交失败，草稿及备份保留：$work / $backup"; return 1
    fi
    identity=$(stat -c '%d:%i:%u:%g:%a:%s:%y:%z' -- "$CADDYFILE") || return 1
    if sudo systemctl reload caddy > "$work/reload.log" 2>&1; then
        printf 'Caddy 配置已校验并加载；自动反代注册表保持原样，手工站点不会登记。\n备份：%s\n' "$backup"
        rm -rf -- "$work"; return 0
    fi
    tail -n 30 -- "$work/reload.log" >&2
    if ! certificate_safe_file "$CADDYFILE" ||
        [ "$identity" != "$(stat -c '%d:%i:%u:%g:%a:%s:%y:%z' -- "$CADDYFILE")" ] ||
        ! sudo cmp -s -- "$candidate" "$CADDYFILE"; then
        certificate_error "reload 失败且 live 已有外部变动，未覆盖；live：$CADDYFILE，备份：$backup，草稿：$candidate"; return 1
    fi
    submitted=$(sudo mktemp "${CADDYFILE}.restore.XXXXXX") || return 1
    if ! sudo cp -p -- "$work/original.caddy" "$submitted" || ! sudo mv -fT -- "$submitted" "$CADDYFILE"; then
        certificate_error "reload 失败，恢复原件失败；live：$CADDYFILE，备份：$backup，草稿：$candidate"; return 1
    fi
    if sudo systemctl reload caddy >> "$work/reload.log" 2>&1; then
        certificate_error "reload 失败，原配置已恢复并重新加载；坏草稿及日志：$work，备份：$backup"
    else
        certificate_error "原文件已恢复，但恢复 reload 失败，服务状态需处理；live：$CADDYFILE，备份：$backup，草稿/日志：$work"
    fi
    return 1
}

function apply_manual_caddyfile() (
    umask 077
    local input=${1:-} work
    command -v flock >/dev/null 2>&1 || { certificate_error '缺少依赖 flock（util-linux）。'; return 1; }
    [ -n "$input" ] && certificate_safe_file "$input" && certificate_absolute_path "$(realpath -ms -- "$input")" >/dev/null || {
        certificate_error '候选不是安全普通文件。'; return 1;
    }
    work=$(mktemp -d "$(dirname -- "$CADDYFILE")/.easy-caddy-edit.XXXXXX") || {
        certificate_error '无法在 Caddyfile 目录建立0700候选目录，请以 root 执行。'; return 1;
    }
    caddy_manual_snapshot "$work" || { certificate_error "备份失败，材料：$work"; return 1; }
    cp -- "$input" "$work/candidate.caddy" || { certificate_error "候选复制失败：$work"; return 1; }
    caddy_manual_commit "$work"
)

function manual_edit_caddyfile() (
    umask 077
    local editor=${VISUAL:-${EDITOR:-}} work executable
    local -a argv
    command -v flock >/dev/null 2>&1 || { certificate_error '缺少依赖 flock（util-linux）。'; return 1; }
    if [ -n "$editor" ]; then
        # 安全简单 argv：常规 vim -f；引号/转义/shell metacharacter 不作 shell 语法解析。
        if [[ "$editor" =~ [[:cntrl:]] || "$editor" = *[\"\'\\\;\|\&\<\>\`\$\(\)]* ]]; then
            certificate_error 'EDITOR/VISUAL 不能安全拆为argv；请使用可执行文件名及普通参数，例如 vim -f。'; return 1
        fi
        read -r -a argv <<< "$editor"
    elif command -v nano >/dev/null 2>&1; then argv=(nano)
    elif command -v vi >/dev/null 2>&1; then argv=(vi)
    else certificate_error '没有可用编辑器，请设置 EDITOR 或安装 nano/vi。'; return 1
    fi
    [ "${#argv[@]}" -gt 0 ] && command -v "${argv[0]}" >/dev/null 2>&1 || { certificate_error '编辑器不存在。'; return 1; }
    work=$(mktemp -d "$(dirname -- "$CADDYFILE")/.easy-caddy-edit.XXXXXX") || return 1
    caddy_manual_snapshot "$work" || { certificate_error "备份失败，材料：$work"; return 1; }
    printf '编辑候选：%s\n备份：%s\n' "$work/candidate.caddy" "$(cat "$work/backup-path")"
    if ! "${argv[@]}" "$work/candidate.caddy"; then
        if certificate_safe_file "$work/candidate.caddy" && cmp -s -- "$work/original.caddy" "$work/candidate.caddy"; then
            printf '编辑已取消/失败，未修改 live。\n' >&2; rm -rf -- "$work"
        else certificate_error "编辑器失败；live 未修改，草稿保留：$work"; fi
        return 1
    fi
    caddy_manual_commit "$work"
)

# Source callers load functions without reading stdin or entering any menu.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi
if [ "$#" -gt 0 ]; then
    case "$1" in
        --sync-certificates)
            [ "$#" -le 2 ] || { certificate_error '用法：--sync-certificates [DOMAIN]'; exit 2; }
            sync_certificates "${2:-}"
            exit $? ;;
        *) certificate_error "未知参数：$1"; exit 2 ;;
    esac
fi

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
        8)
            certificate_menu
            ;;
        9)
            manual_edit_caddyfile
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
