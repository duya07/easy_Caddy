#!/usr/bin/env bash
# EASY_CADDY_SCRIPT_ID=duya07/easy_Caddy
SCRIPT_VERSION='1.0.0'
SCRIPT_UPDATE_SOURCE_URL='https://raw.githubusercontent.com/duya07/easy_Caddy/refs/heads/main/easyCaddy.sh'

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
    DEPENDENCY_STATE_DIR=${DEPENDENCY_STATE_DIR:-/var/lib/easy-caddy/dependencies}
    LOG_MANAGER_STATE_DIR=${LOG_MANAGER_STATE_DIR:-/var/lib/easy-caddy/logs}
    LOG_SYSTEMD_UNIT_DIR=${LOG_SYSTEMD_UNIT_DIR:-/etc/systemd/system}
else
    CADDYFILE=/etc/caddy/Caddyfile
    PROXY_CONFIG_FILE=/root/caddy_reverse_proxies.txt
    CERT_STATE_DIR=/etc/easy-caddy/certificates
    CERT_WORKER_INSTALL_DIR=/usr/local/lib/easy-caddy
    CERT_SYSTEMD_UNIT_DIR=/etc/systemd/system
    DEPENDENCY_STATE_DIR=/var/lib/easy-caddy/dependencies
    LOG_MANAGER_STATE_DIR=/var/lib/easy-caddy/logs
    LOG_SYSTEMD_UNIT_DIR=/etc/systemd/system
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
    local message
    if message=$(sudo caddy validate --adapter caddyfile --config "$validation" 2>&1); then
        printf '配置检查通过，Caddy 可以读取这份配置。\n'
    else
        printf '配置检查没有通过，原文件不会被替换。具体原因：\n%s\n' "$message" >&2
        return 1
    fi
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
    certificate_collect_choice "$domain" || return 1
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
    certificate_collect_choice "$domain" || return 1
    apply_reverse_proxy "$domain" "$upstream" || return 1
    certificate_after_proxy "$domain"
}

#--------------------------------------------
# 反向代理二级菜单
#--------------------------------------------

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
# 终端菜单视觉层：只定义函数，不在顶层执行。
# 颜色仅在 stdout 为真实 TTY、NO_COLOR 未设置（含空值）且 TERM 非 dumb 时启用；
# 其余情况输出纯文本（无 ANSI）。版面按 40 列终端设计，不依赖特殊字体。

# 当前 stdout 是否启用 ANSI 颜色
ui_color_enabled() {
    [ -t 1 ] && [ -z "${NO_COLOR+x}" ] && [ "${TERM:-}" != "dumb" ]
}

# ui_paint <sgr> <text>：不换行输出；颜色关闭或 sgr 为空时输出纯文本
ui_paint() {
    if [ -n "$1" ] && ui_color_enabled; then
        printf '\033[%sm%s\033[0m' "$1" "$2"
    else
        printf '%s' "$2"
    fi
}

# ui_say <sgr> <text>：带换行输出
ui_say() {
    ui_paint "$1" "$2"
    printf '\n'
}

# ui_rule <sgr> <char>：36 列分隔线（ASCII，宽度固定，CJK 宽字符环境也不换行）
ui_rule() {
    local i line=''
    for ((i = 0; i < 36; i++)); do
        line+="$2"
    done
    ui_say "$1" "$line"
}

# ui_header <标题>：顶部标题块（上下双线 + 空行）
ui_header() {
    ui_rule '36' '='
    ui_say '1;36' "  $1"
    ui_rule '36' '='
    printf '\n'
}

# ui_group <分组名>：分组标题
ui_group() {
    printf '  '
    ui_say '1' "$1"
}

# ui_item <编号> <标签> [说明] [标签 SGR]：选项行，形如 "    N) 标签"
ui_item() {
    printf '    '
    ui_paint '36' "$1)"
    printf ' '
    ui_paint "${4:-}" "$2"
    if [ -n "${3:-}" ]; then
        printf '  '
        ui_paint '2' "$3"
    fi
    printf '\n'
}

# ui_sub <说明>：选项下方的暗色缩进说明行
ui_sub() {
    printf '       '
    ui_say '2' "$1"
}

# ui_ask <提示>：输入提示文字（不读取输入）
ui_ask() {
    ui_say '36' "$1"
}

# ui_warn <信息>：错误或无效输入提示
ui_warn() {
    ui_say '1;31' "$1"
}

#--------------------------------------------
# 显示主菜单（顶部显示 Caddy 运行状态）
#--------------------------------------------

#--------------------------------------------
# 反向代理二级菜单
#--------------------------------------------

#--------------------------------------------
# 证书管理菜单
#--------------------------------------------

# Interactive page layer; business functions remain in the single-file script.
ui_interactive() { [ -t 0 ] && [ -t 1 ]; }

ui_page() {
    if ui_interactive && [ "${TERM:-}" != dumb ]; then printf '\033[2J\033[H'; fi
    ui_header "$1"
}

ui_pause() {
    ui_interactive || return 0
    local answer
    printf '\n按回车返回菜单…'
    IFS= read -r answer
}

certificate_context_state() {
    local dest domains domain
    certificate_controlled_path "$CERT_STATE_DIR" || return 1
    if [ -e "$CERT_STATE_DIR/export-directory" ] || [ -L "$CERT_STATE_DIR/export-directory" ]; then
        dest=$(certificate_read_directory) || return 1
        printf '当前目的目录（父目录）：%s\n' "$dest"
        printf '每个域名会自动追加一层子目录；这里只填写父目录。\n'
    else
        printf '当前目的目录：未设置\n'
    fi
    domains=$(certificate_read_domains) || return 1
    printf '\n已登记域名与复制状态：\n'
    if [ -z "$domains" ]; then printf '  无已登记域名；自动复制未登记。\n'
    else
        while IFS= read -r domain; do
            printf '  %s  [已开启复制登记]\n' "$domain"
            [ -z "${dest:-}" ] || printf '    最终文件：%s/%s/fullchain.pem\n              %s/%s/privkey.pem\n' "$dest" "$domain" "$dest" "$domain"
        done <<< "$domains"
    fi
}

certificate_available_domains() {
    local domains line domain
    domains=$(certificate_read_domains) || return 1
    {
        [ -z "$domains" ] || printf '%s\n' "$domains"
        certificate_automation_domains || return 1
        if [ -e "$PROXY_CONFIG_FILE" ] || [ -L "$PROXY_CONFIG_FILE" ]; then
            certificate_safe_file "$PROXY_CONFIG_FILE" || return 1
            while IFS= read -r line || [ -n "$line" ]; do
                [[ "$line" == *' -> '* ]] || continue
                domain=${line%% -> *}
                validate_proxy_domain "$domain" >/dev/null 2>&1 || continue
                domain=${domain,,}; domain=${domain%.}
                printf '%s\n' "$domain"
            done < "$PROXY_CONFIG_FILE"
        fi
        if certificate_safe_file "$CERT_STATE_DIR/sync.log"; then
            awk 'match($0, /\[[^]]+\]/) {print substr($0, RSTART+1, RLENGTH-2)}' "$CERT_STATE_DIR/sync.log" |
                while IFS= read -r domain; do
                    validate_proxy_domain "$domain" >/dev/null 2>&1 && printf '%s\n' "$domain"
                done
        fi
    } | sort -u
}

certificate_context_certificates() {
    local root cert subject expiry count=0
    if ! command -v caddy >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
        printf '\n已有证书：暂无法读取，请先在主菜单 2 检测并安装依赖。\n'
        return 0
    fi
    root=$(certificate_storage_root) || return 1
    printf '\n已有证书：\n'
    local -a candidates
    mapfile -d '' -t candidates < <(certificate_candidates "$root")
    wait "$!" || return 1
    for cert in "${candidates[@]}"; do
        count=$((count+1)); subject=${cert%/*}; subject=${subject##*/}
        expiry=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null) || { printf '  %s：证书无法读取，请查看详细信息。\n' "$subject"; continue; }
        expiry=$(date -d "${expiry#notAfter=}" +%s) || continue
        printf '  %s：%s 到期。\n' "$subject" "$(certificate_ui_human_date "$expiry")"
    done
    [ "$count" -gt 0 ] || printf '  无已签发证书（尚未签发或未发现）。\n'
}

certificate_overview() {
    local scope=${1:-full} domains
    certificate_context_state || return 1
    case "$scope" in full|all) certificate_context_certificates || return 1 ;; esac
    if [ "$scope" = logs ]; then
        domains=$(certificate_available_domains) || return 1
        printf '\n可查看日志的域名：\n'
        if [ -n "$domains" ]; then printf '%s\n' "$domains"
        else printf '  无可查看日志的域名。\n'; fi
    fi
    printf '\n'
}

certificate_select_domain() {
    local scope=${1:-available} domains input domain index=0
    CERT_SELECTED_DOMAIN=''
    if [ "$scope" = registered ]; then domains=$(certificate_read_domains) || return 1
    else domains=$(certificate_available_domains) || return 1; fi
    local -a choices=()
    if [ -n "$domains" ]; then
        while IFS= read -r domain; do
            choices+=("$domain"); index=$((index+1))
            printf '  %s) %s\n' "$index" "$domain"
        done <<< "$domains"
    elif [ "$scope" = registered ]; then
        printf '当前没有已登记域名，无需取消复制。\n'; return 1
    else
        printf '当前没有可选域名，可输入已有站点的域名。\n'
    fi
    printf '请选择域名编号或输入域名（0 取消）：\n'
    IFS= read -r input || return 1
    [ "$input" != 0 ] && [ -n "$input" ] || { printf '操作已取消。\n'; return 1; }
    if [[ "$input" =~ ^[0-9]+$ ]] && [ "${#input}" -le 6 ]; then
        index=$((10#$input))
        if [ "$index" -ge 1 ] && [ "$index" -le "${#choices[@]}" ]; then input=${choices[index-1]}
        else printf '域名编号无效。\n'; return 1; fi
    fi
    validate_proxy_domain "$input" || return 1
    input=${input,,}; input=${input%.}
    if [ "$scope" = registered ] && ! printf '%s\n' "$domains" | grep -Fxq -- "$input"; then
        printf '该域名未登记复制。\n'; return 1
    fi
    CERT_SELECTED_DOMAIN=$input
}

function show_menu() {
    local state_sgr state_text
    caddy_status=$(systemctl is-active caddy 2>/dev/null)
    if [ "$caddy_status" = active ]; then state_sgr='1;32'; state_text='运行中'
    else state_sgr='1;31'; state_text='未运行'; fi
    ui_page 'Caddy 一键部署与管理'
    printf '  脚本版本：%s\n' "$SCRIPT_VERSION"
    printf '  Caddy 状态：'; ui_say "$state_sgr" "$state_text"
    certificate_main_summary
    printf '\n'
    ui_group '部署与代理'
    ui_item 1 '安装 Caddy' '（已装则跳过）'
    ui_item 2 '依赖检测与安装'
    ui_item 3 '配置反向代理'
    printf '\n'
    ui_group '服务运维'
    ui_item 4 '查看服务状态'
    ui_item 5 '查看反代配置' '（含上游状态）'
    ui_item 6 '删除反向代理' '' '1;31'
    ui_item 7 '重启 Caddy 服务'
    ui_item 8 '日志查看'
    ui_item 9 '日志轮转设置'
    printf '\n'
    ui_group '维护'
    ui_item 10 '卸载 Caddy' '（删除配置）' '1;31'
    ui_item 11 '依赖卸载' '（默认仅新增）' '1;31'
    ui_item 12 '证书管理' '（查看/同步/日志）'
    ui_item 13 '手动编辑配置' '（先校验再应用）'
    ui_item 14 '检查/更新脚本' '（保留配置与证书）'
    printf '\n'
    ui_item 0 '退出'
    ui_rule '2' '-'
}

function reverse_proxy_menu() {
    local proxy_opt
    while true; do
        ui_page '配置 & 启用反向代理'
        ui_item 1 '反代本地端口'
        ui_sub '域名 -> http://127.0.0.1:端口'
        ui_item 2 '反代远程网址'
        ui_sub '域名 -> https://目标网址'
        printf '\n'; ui_item 0 '返回'; ui_rule '2' '-'
        read -p '请输入选项 > ' proxy_opt || return
        case "$proxy_opt" in
            1) ui_page '反代本地端口'; setup_reverse_proxy ;;
            2) ui_page '反代远程网址'; setup_reverse_proxy_remote ;;
            0) return 0 ;;
            *) ui_page '选项提示'; ui_warn '无效选项，请重新输入。' ;;
        esac
        ui_pause || return 0
    done
}

function certificate_menu() {
    local option path
    while true; do
        ui_page '证书管理'
        ui_item 1 '查看证书与登记状态'
        ui_item 2 '设置/修改目的目录'
        ui_item 3 '立即同步已登记域名'
        ui_item 4 '查看域名日志'
        ui_item 5 '登记现有域名并开启复制'
        ui_item 6 '取消域名复制'
        ui_item 7 '申请证书' '（无需先配置反代）'
        ui_item 8 '设置自动续签' '（开启/关闭/提前天数）'
        ui_item 9 '查看技术详情' '（原始字段与诊断）'
        ui_item 10 '等待域名证书签发'
        printf '\n'; ui_item 0 '返回'; ui_rule '2' '-'
        printf '请选择 > '
        IFS= read -r option || return 0
        case "$option" in
            1) ui_page '查看证书与登记状态'
                list_certificates ;;
            2) ui_page '设置/修改目的目录'
                certificate_set_directory_menu ;;
            3) ui_page '立即同步已登记域名'
                certificate_overview full && sync_certificates ;;
            4) ui_page '查看域名日志'
                if certificate_overview logs && certificate_select_domain available; then
                    certificate_show_logs "$CERT_SELECTED_DOMAIN"
                fi ;;
            5) ui_page '登记现有域名并开启复制'
                if certificate_overview full && certificate_select_domain available; then
                    certificate_collect_choice "$CERT_SELECTED_DOMAIN" && certificate_after_proxy "$CERT_SELECTED_DOMAIN"
                fi ;;
            6) ui_page '取消域名复制'
                if certificate_overview state && certificate_select_domain registered; then
                    unregister_certificate_export "$CERT_SELECTED_DOMAIN" &&
                        printf '复制登记已取消：%s\n' "$CERT_SELECTED_DOMAIN"
                fi ;;
            7) ui_page '申请域名证书'; certificate_request_menu ;;
            8) ui_page '设置自动续签'; certificate_renewal_menu ;;
            9) ui_page '证书技术详情'; certificate_technical_details ;;
            10) ui_page '等待证书签发'
                certificate_select_domain available && certificate_watch_domain "$CERT_SELECTED_DOMAIN" ;;
            0) return 0 ;;
            *) ui_page '选项提示'; ui_warn '无效选项。' ;;
        esac
        ui_pause || return 0
    done
}

# Debian/Ubuntu dependency ownership; records are data, never shell code.
dependency_manifest() {
    cat <<'PACKAGES'
curl|curl
gnupg|gpg
jq|jq
openssl|openssl
util-linux|flock
coreutils|realpath stat date sha256sum cp mv cmp mktemp install timeout tee cat chmod mkdir sort head tail cut tr readlink wc
findutils|find
grep|grep
sed|sed
mawk|awk
sudo|sudo
ca-certificates|
logrotate|logrotate
gzip|gzip
PACKAGES
}

dependency_package_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9-]+)?$ ]]; }

dependency_installed() {
    local status
    status=$(dpkg-query -W -f='${db:Status-Status}\n' -- "$1" 2>/dev/null) || return 1
    [ "$status" = installed ]
}

dependency_related_packages() {
    local package tools
    while IFS='|' read -r package tools; do printf '%s\n' "$package"; done < <(dependency_manifest)
}

dependency_report() {
    local package tools tool available broken=0
    DEPENDENCY_MISSING_PACKAGES=()
    command -v dpkg-query >/dev/null 2>&1 || { certificate_error '需要 Debian/Ubuntu 的 dpkg-query。'; return 1; }
    printf '脚本依赖检测（仅安装缺失项）：\n'
    while IFS='|' read -r package tools; do
        available=1
        for tool in $tools; do command -v "$tool" >/dev/null 2>&1 || available=0; done
        [ -n "$tools" ] || { dependency_installed "$package" || available=0; }
        if [ "$available" -eq 1 ]; then printf '  已安装  %s\n' "$package"
        elif dependency_installed "$package"; then
            printf '  异常    %s（包已安装但命令不可用，未重复安装）\n' "$package"; broken=1
        else
            printf '  缺失    %s\n' "$package"; DEPENDENCY_MISSING_PACKAGES+=("$package")
        fi
    done < <(dependency_manifest)
    if command -v caddy >/dev/null 2>&1; then printf '  已安装  Caddy（由安装/卸载 Caddy 菜单管理）\n'
    else printf '  缺失    Caddy（请使用主菜单 1 安装）\n'; fi
    printf '\n'
    [ "$broken" -eq 0 ]
}

dependency_safe_record() {
    local mode
    certificate_safe_file "$1" || return 1
    mode=$(stat -c %a -- "$1") || return 1
    [ "$(stat -c %u -- "$1")" = 0 ] && (( (8#$mode & 0022) == 0 ))
}

dependency_prepare_state() {
    local file
    [ "$EUID" -eq 0 ] || { certificate_error '依赖管理需要 root。'; return 1; }
    command -v apt-get >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || {
        certificate_error '依赖管理需要 apt-get 和 flock。'; return 1;
    }
    certificate_controlled_path "$DEPENDENCY_STATE_DIR" || return 1
    if [ -e "$DEPENDENCY_STATE_DIR" ]; then
        [ -d "$DEPENDENCY_STATE_DIR" ] && [ "$(stat -c %u -- "$DEPENDENCY_STATE_DIR")" = 0 ] || return 1
    else mkdir -p -m 700 -- "$DEPENDENCY_STATE_DIR" || return 1; fi
    for file in installed-packages pending-before pending-plan lock; do
        if [ -e "$DEPENDENCY_STATE_DIR/$file" ] || [ -L "$DEPENDENCY_STATE_DIR/$file" ]; then
            dependency_safe_record "$DEPENDENCY_STATE_DIR/$file" || { certificate_error "依赖记录不安全：$file"; return 1; }
        fi
    done
    chmod 700 -- "$DEPENDENCY_STATE_DIR"
}

dependency_read_owned() {
    local package file=$DEPENDENCY_STATE_DIR/installed-packages
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then return 0; fi
    dependency_safe_record "$file" || { certificate_error '安装归属记录不安全。'; return 1; }
    while IFS= read -r package || [ -n "$package" ]; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || { certificate_error '安装记录包含无效包名。'; return 1; }
        printf '%s\n' "$package"
    done < "$file"
}

dependency_snapshot() {
    local records
    records=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${Essential}\t${Protected}\n') || return 1
    printf '%s\n' "$records" | awk -F '\t' '$2 == "installed" {print $1}' | LC_ALL=C sort -u > "$1" || return 1
    chmod 600 -- "$1"
}

dependency_save_owned() {
    local stage
    stage=$(mktemp "$DEPENDENCY_STATE_DIR/.owned.XXXXXX") || return 1
    if ! LC_ALL=C sort -u -- "$1" > "$stage" || ! chmod 600 -- "$stage" || ! mv -f -- "$stage" "$DEPENDENCY_STATE_DIR/installed-packages"; then
        rm -f -- "$stage"; certificate_error '依赖安装归属记录保存失败。'; return 1
    fi
}

dependency_pending_clear() { rm -f -- "$DEPENDENCY_STATE_DIR/pending-before" "$DEPENDENCY_STATE_DIR/pending-plan"; }

dependency_no_pending() {
    if [ -e "$DEPENDENCY_STATE_DIR/pending-before" ] || [ -e "$DEPENDENCY_STATE_DIR/pending-plan" ]; then
        certificate_error "发现未完成的安装事务。请核对 $DEPENDENCY_STATE_DIR/pending-before 与 pending-plan；为避免误归属，本次不自动认领或卸载现有包。"
        return 1
    fi
}

dependency_install_menu() (
    umask 077
    local answer package plan before after rc=0 owned actual stage lock_fd
    dependency_report || return 1
    [ "${#DEPENDENCY_MISSING_PACKAGES[@]}" -gt 0 ] || { printf '所有依赖已满足，无需安装；已有包归属保持不变。\n'; return 0; }
    printf '本次仅安装以下缺失项：\n'; printf '  %s\n' "${DEPENDENCY_MISSING_PACKAGES[@]}"
    printf '确认安装？[y/yes，默认 n]：\n'
    IFS= read -r answer || return 0
    case "${answer,,}" in y|yes) ;; *) printf '操作已取消。\n'; return 0 ;; esac
    dependency_prepare_state || return 1
    exec {lock_fd}> "$DEPENDENCY_STATE_DIR/lock" || return 1
    flock -x -w 30 "$lock_fd" || { certificate_error '依赖管理锁暂忙。'; return 1; }
    dependency_no_pending || return 1
    stage=$(mktemp -d "$DEPENDENCY_STATE_DIR/.transaction.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    dependency_report || return 1
    [ "${#DEPENDENCY_MISSING_PACKAGES[@]}" -gt 0 ] || { printf '缺失项已由其他操作安装，本次未新增归属。\n'; return 0; }
    apt-get update || { certificate_error '软件包索引更新失败，未安装。'; return 1; }
    dependency_snapshot "$stage/before" || return 1
    plan=$(LC_ALL=C apt-get --simulate --no-remove --no-install-recommends install -- "${DEPENDENCY_MISSING_PACKAGES[@]}") || return 1
    if printf '%s\n' "$plan" | grep -q '^Remv '; then certificate_error '安装计划包含移除，已拒绝。'; return 1; fi
    printf '%s\n' "$plan" | awk '$1 == "Inst" {print $2}' | LC_ALL=C sort -u > "$stage/plan"
    while IFS= read -r package; do dependency_package_name "$package" || return 1; done < "$stage/plan"
    printf '\nAPT 本次安装计划（含所需传递依赖）：\n'; cat -- "$stage/plan"
    install -m 600 -- "$stage/before" "$DEPENDENCY_STATE_DIR/pending-before" &&
        install -m 600 -- "$stage/plan" "$DEPENDENCY_STATE_DIR/pending-plan" || return 1
    apt-get --no-remove --no-install-recommends install -y -- "${DEPENDENCY_MISSING_PACKAGES[@]}" || rc=$?
    dependency_snapshot "$stage/after" || { certificate_error '安装后状态读取失败；保留事务快照。'; return 1; }
    owned=$(dependency_read_owned) || return 1
    printf '%s\n' "$owned" | sed '/^$/d' > "$stage/owned"
    LC_ALL=C comm -13 "$stage/before" "$stage/after" > "$stage/new"
    local -A planned=()
    while IFS= read -r package; do planned["${package%%:*}"]=1; done < "$stage/plan"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        if [ "${planned[${package%%:*}]:-0}" = 1 ]; then
            printf '%s\n' "$package" >> "$stage/owned"
            printf '已记录本功能新安装：%s\n' "$package"
        fi
    done < "$stage/new"
    dependency_save_owned "$stage/owned" || return 1
    dependency_pending_clear || return 1
    if [ "$rc" -ne 0 ]; then certificate_error '安装未全部成功，已记录实际成功安装的新包。'; return "$rc"; fi
    printf '依赖安装完成；原有依赖未记为本功能安装。\n'
)

dependency_protected() {
    local flags base=${1%%:*}
    case "$base" in bash|apt|dpkg|systemd|systemd-sysv|coreutils|findutils|grep|sed|mawk|gawk|util-linux|libc6) return 0 ;; esac
    flags=$(dpkg-query -W -f='${Essential}\t${Protected}\n' -- "$1" 2>/dev/null) || return 0
    [[ "$flags" == *yes* ]]
}

dependency_uninstall_menu() (
    umask 077
    local choice answer owned candidates package plan rc=0 stage lock_fd
    printf '依赖卸载范围：\n 1) 仅本功能新安装并记录的依赖（默认）\n 2) 全部相关可卸载依赖（包括原有依赖）\n 0) 取消\n'
    IFS= read -r choice || return 0
    case "$choice" in ''|1) choice=1 ;; 2) ;; 0) return 0 ;; *) certificate_error '无效卸载范围。'; return 1 ;; esac
    dependency_prepare_state || return 1
    exec {lock_fd}> "$DEPENDENCY_STATE_DIR/lock" || return 1
    flock -x -w 30 "$lock_fd" || return 1
    dependency_no_pending || return 1
    owned=$(dependency_read_owned) || return 1
    if [ "$choice" = 1 ]; then candidates=$owned
    else candidates=$(printf '%s\n%s\n' "$(dependency_related_packages)" "$owned" | sed '/^$/d' | LC_ALL=C sort -u); fi
    local -a selected=()
    local -A allowed=()
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_installed "$package" || continue
        if dependency_protected "$package"; then printf '保留系统基础/受保护包：%s\n' "$package"; continue; fi
        selected+=("$package"); allowed["${package%%:*}"]=1
    done <<< "$candidates"
    [ "${#selected[@]}" -gt 0 ] || { printf '本次范围内没有可卸载依赖。\n'; return 0; }
    plan=$(LC_ALL=C apt-get --simulate -o APT::Get::AutomaticRemove=false remove -- "${selected[@]}") || return 1
    local -a removals=()
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || return 1
        if [ "${allowed[${package%%:*}]:-0}" != 1 ] || dependency_protected "$package"; then
            printf 'APT 还将移除清单外或受保护的包：%s\n' "$package"
            certificate_error '该卸载计划超出范围，已停止；没有卸载任何包。'; return 1
        fi
        removals+=("$package")
    done < <(printf '%s\n' "$plan" | awk '$1 == "Remv" {print $2}')
    [ "${#removals[@]}" -gt 0 ] || { printf 'APT 没有需要移除的项目。\n'; return 0; }
    printf '\n本次将卸载的具体项目：\n'; printf '  %s\n' "${removals[@]}"
    printf '只执行上述清单，不运行 autoremove。确认卸载？[y/yes，默认 n]：\n'
    IFS= read -r answer || return 0
    case "${answer,,}" in y|yes) ;; *) printf '操作已取消。\n'; return 0 ;; esac
    stage=$(mktemp -d "$DEPENDENCY_STATE_DIR/.uninstall.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    apt-get -o APT::Get::AutomaticRemove=false remove -y -- "${removals[@]}" || rc=$?
    : > "$stage/owned"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_installed "$package" && printf '%s\n' "$package" >> "$stage/owned"
    done <<< "$owned"
    dependency_save_owned "$stage/owned" || return 1
    if [ "$rc" -ne 0 ]; then certificate_error '卸载未全部成功；未卸载的安装记录已保留。'; return "$rc"; fi
    printf '依赖卸载完成；未选中的原有依赖保持不变。\n'
)

# Log views and dedicated rotation of easy_Caddy-owned files.
log_file_view() {
    local file=$1
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then printf '暂无日志（文件尚未生成）。\n'; return 0; fi
    certificate_safe_file "$file" || { certificate_error '日志不是安全普通文件。'; return 1; }
    if [ -s "$file" ]; then tail -n 200 -- "$file"
    else printf '暂无日志（文件为空）。\n'; fi
}

log_journal_view() {
    local output
    output=$(journalctl -u "$1" --no-pager -n 200 2>&1) || { certificate_error "日志读取失败：$output"; return 1; }
    if [ -n "$output" ]; then printf '%s\n' "$output"
    else printf '暂无服务日志。\n'; fi
}

logs_menu() {
    local option
    while true; do
        ui_page '日志查看'
        ui_item 1 'Caddy 服务日志'
        ui_item 2 '证书同步文件日志'
        ui_item 3 '证书同步任务日志'
        ui_item 4 '按域名查看日志'
        printf '\n'; ui_item 0 '返回'; ui_rule '2' '-'
        printf '请选择 > '
        IFS= read -r option || return 0
        case "$option" in
            1) ui_page 'Caddy 服务日志'; log_journal_view caddy ;;
            2) ui_page '证书同步文件日志'; log_file_view "$CERT_STATE_DIR/sync.log" ;;
            3) ui_page '证书同步任务日志'; log_journal_view easy-caddy-cert-sync ;;
            4) ui_page '按域名查看日志'
                if certificate_overview logs && certificate_select_domain available; then certificate_show_logs "$CERT_SELECTED_DOMAIN"; fi ;;
            0) return 0 ;;
            *) ui_page '选项提示'; ui_warn '无效日志选项。' ;;
        esac
        ui_pause || return 0
    done
}

log_rotation_safe_file() {
    local mode
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then return 0; fi
    certificate_safe_file "$1" || return 1
    mode=$(stat -c %a -- "$1") || return 1
    [ "$(stat -c %u -- "$1")" = 0 ] && (( (8#$mode & 0022) == 0 ))
}

log_rotation_paths() {
    local path
    for path in "$LOG_MANAGER_STATE_DIR" "$LOG_SYSTEMD_UNIT_DIR" "$CERT_STATE_DIR"; do
        certificate_absolute_path "$path" >/dev/null && certificate_controlled_path "$path" || return 1
    done
    for path in "$LOG_MANAGER_STATE_DIR/logrotate.conf" "$LOG_MANAGER_STATE_DIR/period" "$LOG_MANAGER_STATE_DIR/logrotate.status" "$LOG_MANAGER_STATE_DIR/rotation.lock" \
                "$LOG_SYSTEMD_UNIT_DIR/easy-caddy-logrotate.service" "$LOG_SYSTEMD_UNIT_DIR/easy-caddy-logrotate.timer" "$CERT_STATE_DIR/sync.log"; do
        log_rotation_safe_file "$path" || { certificate_error "日志轮转对象不安全：$path"; return 1; }
    done
}

log_rotation_show() {
    local period='未设置' state='未启用' value
    log_rotation_paths || return 1
    if [ -e "$LOG_MANAGER_STATE_DIR/period" ]; then
        value=$(cat -- "$LOG_MANAGER_STATE_DIR/period") || return 1
        case "$value" in daily) period='每天' ;; weekly) period='每周' ;; monthly) period='每月' ;; *) certificate_error '轮转周期记录无效。'; return 1 ;; esac
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet easy-caddy-logrotate.timer; then state='运行中'; fi
    printf '当前轮转周期：%s\n定时检查：%s（每小时检查）\n' "$period" "$state"
    printf '保留：14 份；大小上限触发：10 MiB。\n轮转文件：%s/sync.log\n' "$CERT_STATE_DIR"
    printf 'Caddy/任务服务日志继续使用 journald 的现有保留策略；本设置管理脚本文件日志。\n\n'
    command -v logrotate >/dev/null 2>&1 || printf '缺少 logrotate，请先通过主菜单 2 安装依赖。\n'
}

log_rotation_quote() {
    local value=$1
    value=${value//\\/\\\\}; value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

log_rotation_unit_quote() {
    local value=$1
    value=${value//%/%%}
    log_rotation_quote "$value"
}

log_rotation_atomic_file() {
    local stage
    stage=$(mktemp "${2}.stage.XXXXXX") || return 1
    if ! install -m 600 -- "$1" "$stage" || ! mv -f -- "$stage" "$2"; then rm -f -- "$stage"; return 1; fi
}

log_rotation_apply() (
    umask 077
    local period=$1 binary stage lock_fd path name was_active=0 restore_failed=0
    case "$period" in daily|weekly|monthly) ;; *) certificate_error '轮转周期只支持 daily、weekly、monthly。'; return 1 ;; esac
    [ "$EUID" -eq 0 ] || { certificate_error '日志轮转设置需要 root。'; return 1; }
    binary=$(command -v logrotate) || { certificate_error '缺少 logrotate，请先在主菜单 2 安装依赖。'; return 1; }
    binary=$(readlink -f -- "$binary") || return 1
    [[ "$binary" == /* && ! "$binary" =~ [[:cntrl:]] ]] || return 1
    command -v systemctl >/dev/null 2>&1 || { certificate_error '需要 systemd 执行定时轮转。'; return 1; }
    log_rotation_paths || return 1
    mkdir -p -m 700 -- "$LOG_MANAGER_STATE_DIR" || return 1
    [ "$(stat -c %u -- "$LOG_MANAGER_STATE_DIR")" = 0 ] || return 1
    exec {lock_fd}> "$LOG_MANAGER_STATE_DIR/rotation.lock" || return 1
    flock -x -w 30 "$lock_fd" || return 1
    log_rotation_paths || return 1
    stage=$(mktemp -d "$LOG_MANAGER_STATE_DIR/.rotation.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    {
        log_rotation_quote "$CERT_STATE_DIR/sync.log"; printf ' {\n    %s\n    rotate 14\n    maxsize 10M\n    missingok\n    notifempty\n    compress\n    delaycompress\n    copytruncate\n    su root root\n}\n' "$period"
    } > "$stage/logrotate.conf" || return 1
    if ! "$binary" --debug --state "$LOG_MANAGER_STATE_DIR/logrotate.status" "$stage/logrotate.conf" > "$stage/validation.log" 2>&1; then
        certificate_error '轮转配置校验失败；未启用。'; cat -- "$stage/validation.log" >&2; return 1
    fi
    {
        printf '[Unit]\nDescription=Rotate easy_Caddy file logs\n\n[Service]\nType=oneshot\nUser=root\nUMask=0077\n'
        printf 'ExecStart='; log_rotation_unit_quote "$binary"
        printf ' --state '; log_rotation_unit_quote "$LOG_MANAGER_STATE_DIR/logrotate.status"
        printf ' '; log_rotation_unit_quote "$LOG_MANAGER_STATE_DIR/logrotate.conf"; printf '\n'
    } > "$stage/easy-caddy-logrotate.service" || return 1
    printf '[Unit]\nDescription=Check easy_Caddy log rotation hourly\n\n[Timer]\nOnCalendar=hourly\nPersistent=true\nAccuracySec=1min\nUnit=easy-caddy-logrotate.service\n\n[Install]\nWantedBy=timers.target\n' > "$stage/easy-caddy-logrotate.timer" || return 1
    printf '%s\n' "$period" > "$stage/period"
    mkdir -p -m 700 -- "$LOG_SYSTEMD_UNIT_DIR" || return 1
    local -a names=(logrotate.conf period easy-caddy-logrotate.service easy-caddy-logrotate.timer)
    local -a targets=("$LOG_MANAGER_STATE_DIR/logrotate.conf" "$LOG_MANAGER_STATE_DIR/period" "$LOG_SYSTEMD_UNIT_DIR/easy-caddy-logrotate.service" "$LOG_SYSTEMD_UNIT_DIR/easy-caddy-logrotate.timer")
    local i failed=0
    for i in "${!targets[@]}"; do
        if [ -e "${targets[i]}" ]; then cp -p -- "${targets[i]}" "$stage/original-${names[i]}" || return 1; fi
    done
    systemctl is-active --quiet easy-caddy-logrotate.timer && was_active=1
    for i in "${!targets[@]}"; do
        log_rotation_atomic_file "$stage/${names[i]}" "${targets[i]}" || { failed=1; break; }
    done
    if [ "$failed" -eq 0 ]; then
        systemctl daemon-reload && systemctl enable --now easy-caddy-logrotate.timer || failed=1
    fi
    if [ "$failed" -ne 0 ]; then
        if [ "$was_active" -eq 0 ]; then
            systemctl stop easy-caddy-logrotate.timer >/dev/null 2>&1 || :
            systemctl disable easy-caddy-logrotate.timer >/dev/null 2>&1 || :
        fi
        for i in "${!targets[@]}"; do
            if [ -e "$stage/original-${names[i]}" ]; then cp -p -- "$stage/original-${names[i]}" "${targets[i]}" || restore_failed=1
            else rm -f -- "${targets[i]}" || restore_failed=1; fi
        done
        systemctl daemon-reload >/dev/null 2>&1 || restore_failed=1
        if [ "$was_active" -eq 1 ]; then systemctl restart easy-caddy-logrotate.timer >/dev/null 2>&1 || restore_failed=1; fi
        if [ "$restore_failed" -eq 0 ]; then certificate_error '轮转设置未启用，已恢复原设置。'
        else certificate_error '轮转设置失败，恢复未全部成功，请检查管理文件和专用 timer。'; fi
        return 1
    fi
    printf '日志轮转已启用：%s；每小时检查，14 份，超过 10 MiB 提前轮转。\n' "$period"
)

log_rotation_menu() {
    local choice period answer
    log_rotation_show || return 1
    printf '请选择轮转周期：\n 1) 每天\n 2) 每周\n 3) 每月\n 0) 返回\n'
    IFS= read -r choice || return 0
    case "$choice" in 1) period=daily ;; 2) period=weekly ;; 3) period=monthly ;; 0|'') return 0 ;; *) certificate_error '无效轮转周期。'; return 1 ;; esac
    printf '将轮转 %s/sync.log，保留14份，大小触发10MiB，周期%s。\n确认应用？[y/yes，默认 n]：\n' "$CERT_STATE_DIR" "$period"
    IFS= read -r answer || return 0
    case "${answer,,}" in y|yes) log_rotation_apply "$period" ;; *) printf '操作已取消。\n' ;; esac
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
        json=$(caddy_adapt_quiet caddy_adapt_service_environment "$pid" "$CADDYFILE") || {
            certificate_error '无法使用运行服务环境解析 Caddyfile/import，未扫描证书。'; return 1;
        }
    else
        # Imports may introduce parse-time variables even when the main file has
        # none. A stopped service has no authoritative process environment.
        if grep -qF '{$' "$CADDYFILE" || grep -Eq '(^|[[:space:]])import([[:space:]]|$)' "$CADDYFILE"; then
            certificate_error 'Caddy 服务未运行，无法可靠解析 Caddyfile/import 的服务环境；未扫描证书。'
            return 1
        fi
        json=$(caddy_adapt_quiet caddy adapt --adapter caddyfile --config "$CADDYFILE") || {
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
    case "$status" in
        synced) printf '%s：证书已复制完成，可以在目的目录中使用。\n' "$domain" ;;
        already-current) printf '%s：副本已经是最新证书，无需重复复制。\n' "$domain" ;;
        '待签发/未发现') printf '%s：还在等待证书签发，后台会继续检查。\n' "$domain" ;;
        error) printf '%s：这次复制未完成，原有文件保留。%s\n' "$domain" "$detail" ;;
        *) printf '%s：%s %s\n' "$domain" "$status" "$detail" ;;
    esac
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

function certificate_technical_details() {
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

function list_certificates() {
    local root domains known automated domain cert subject dest='' registered registered_domains
    local -a candidates
    certificate_dependencies || return 1
    root=$(certificate_storage_root) || return 1
    registered_domains=$(certificate_read_domains) || return 1
    known=$(certificate_available_domains) || return 1
    mapfile -d '' -t candidates < <(certificate_candidates "$root")
    wait "$!" || return 1
    domains=$known
    for cert in "${candidates[@]}"; do
        subject=${cert%/*}; subject=${subject##*/}
        domains+=$'\n'$subject
    done
    domains=$(printf '%s\n' "$domains" | sed '/^$/d' | LC_ALL=C sort -u)
    if [ -e "$CERT_STATE_DIR/export-directory" ] || [ -L "$CERT_STATE_DIR/export-directory" ]; then
        dest=$(certificate_read_directory) || return 1
        printf '证书复制父目录：%s（域名子目录由脚本自动追加）。\n' "$dest"
    else printf '自动复制尚未设置父目录；这不影响 Caddy 自己申请和使用证书。\n'; fi
    [ -n "$domains" ] || { printf '\n还没有可显示的证书或域名（待签发/未发现）；可以选择“申请证书”。\n'; return 0; }
    while IFS= read -r domain; do
        registered=no
        if printf '%s\n' "$registered_domains" | grep -Fxq -- "$domain"; then registered=yes; fi
        certificate_ui_domain_status "$root" "$domain" "$registered" "$dest" || return 1
    done <<< "$domains"
    printf '\n需要内部目录、原始日期或错误原因时，请选择“查看技术详情”或“查看域名日志”。\n'
}

function install_certificate_sync_timer() (
    umask 077
    local domains automated script service timer lock_fd worker_argument=--sync-certificates
    domains=$(certificate_read_domains) || return 1
    automated=$(certificate_automation_domains) || return 1
    [ -z "$automated" ] || worker_argument=--certificate-maintenance
    [ -n "$domains$automated" ] || return 0
    [ "$EUID" -eq 0 ] || { certificate_error '安装自动同步需要 root。'; return 1; }
    command -v systemctl >/dev/null 2>&1 || { certificate_error 'systemd 不可用，自动同步未启用。'; return 1; }
    certificate_state_prepare || return 1
    exec {lock_fd}> "$CERT_STATE_DIR/sync.lock" || return 1
    flock -x -w 20 "$lock_fd" || return 1
    domains=$(certificate_read_domains) || return 1
    automated=$(certificate_automation_domains) || return 1
    [ -n "$domains$automated" ] || return 0
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
        printf 'ExecStart=/bin/bash "%s" %s\n' "$escaped" "$worker_argument"
    } > "$service" || return 1
    printf '[Unit]\nDescription=Check Caddy certificate exports each minute\n\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=1min\nAccuracySec=1s\nUnit=easy-caddy-cert-sync.service\n\n[Install]\nWantedBy=timers.target\n' > "$timer" || return 1
    chmod 600 -- "$service" "$timer" || return 1
    local service_message
    if ! service_message=$(systemctl daemon-reload 2>&1) || ! service_message=$(systemctl enable --now easy-caddy-cert-sync.timer 2>&1); then
        certificate_error '后台证书检查没有启用。设置仍保留，可重试开启；立即同步仍可手动运行。'
        printf '%s\n' "$service_message" >&2
        return 1
    fi
    printf '后台证书检查已开启：每分钟检查一次，签发或续签完成后会更新已登记的副本。\n'
    printf '关闭此页面不会中断 Caddy 申请；也可以留在当前页面等待结果。\n'
)

# 只收集输入，数据由成功的反代事务之后提交。
function certificate_collect_choice() {
    CERT_CHOICE=no; CERT_CHOSEN_DIRECTORY=''; CERT_DIRECTORY_IS_NEW=0
    local answer path domain=${1:-${CERT_SELECTED_DOMAIN:-example.com}} duplicate_answer
    while true; do
        printf '是否将该域名证书复制到指定目录？[y/yes，默认 n]：\n'
        IFS= read -r answer || { printf '输入结束，已取消。\n'; return 1; }
        case "${answer,,}" in y|yes) CERT_CHOICE=yes; break ;; n|no|'') return 0 ;; *) printf '请输入 y/yes 或 n/no。\n' ;; esac
    done
    if [ -e "$CERT_STATE_DIR/export-directory" ]; then
        path=$(certificate_read_directory) || return 1
    else
        printf '请选择证书的父目录，脚本会自动在下面建立 %s 子目录。\n' "$domain"
        printf '例如填 /root/cert，证书就会放在 /root/cert/%s/；不要再把域名填在父目录末尾。\n' "$domain"
        printf '请输入证书父目录（绝对路径或 ~/，可含空格）：\n'
        IFS= read -r path || { printf '输入结束，已取消。\n'; return 1; }
        CERT_DIRECTORY_IS_NEW=1
    fi
    path=$(certificate_normalize_destination_input "$path") || return 1
    CERT_CHOSEN_DIRECTORY=$(certificate_validate_destination "$path") || return 1
    certificate_destination_preview "$CERT_CHOSEN_DIRECTORY" "$domain" || return 1
    if [ "${CERT_CHOSEN_DIRECTORY##*/}" = "$domain" ]; then
        printf '父目录末尾已经是域名，继续会重复一层。确定仍使用这个父目录？[y/yes，默认 n]：\n'
        IFS= read -r duplicate_answer || return 1
        case "${duplicate_answer,,}" in y|yes) ;; *) printf '已取消，请重新选择父目录。\n'; return 1 ;; esac
    fi
}

function certificate_after_proxy() {
    local domain=$1 failed=0
    if [ "$CERT_CHOICE" = no ]; then
        unregister_certificate_export "$domain" || {
            certificate_error '反代配置已应用，但旧证书登记取消失败。'; return 1;
        }
        certificate_watch_domain "$domain"
        return $?
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
    certificate_watch_domain "$domain"
}

function certificate_show_logs() {
    local domain=$1 output file_output='' journal_output=''
    validate_proxy_domain "$domain" >/dev/null || return 1
    domain=${domain,,}; domain=${domain%.}
    if [ -e "$CERT_STATE_DIR/sync.log" ] || [ -L "$CERT_STATE_DIR/sync.log" ]; then
        certificate_safe_file "$CERT_STATE_DIR/sync.log" || { certificate_error '同步日志不是安全普通文件。'; return 1; }
        file_output=$(tail -n 200 -- "$CERT_STATE_DIR/sync.log" | grep -F -- "[$domain]" || :)
    fi
    output=$(journalctl -u caddy -u easy-caddy-cert-sync --no-pager -n 200 2>&1) || {
        certificate_error "journal 读取失败：$output"; return 1;
    }
    journal_output=$(printf '%s\n' "$output" | grep -F -- "$domain" || :)
    printf '域名日志：%s\n' "$domain"
    [ -z "$file_output" ] || printf '%s\n' "$file_output"
    [ -z "$journal_output" ] || printf '%s\n' "$journal_output"
    [ -n "$file_output$journal_output" ] || printf '该域名暂无日志。\n'
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

# Certificate automation uses Caddy's own issuer; export registration is independent.
certificate_automation_domains() {
    local directory=$CERT_STATE_DIR/automation file domain
    [ -e "$directory" ] || { [ ! -L "$directory" ]; return $?; }
    certificate_controlled_path "$directory" || return 1
    for file in "$directory"/*; do
        [ -e "$file" ] || [ -L "$file" ] || continue
        domain=${file##*/}
        [[ "$domain" = .* ]] && continue
        validate_proxy_domain "$domain" >/dev/null 2>&1 && certificate_safe_file "$file" || {
            certificate_error '证书续签设置中有无法识别或不安全的记录，请先检查。'; return 1;
        }
        printf '%s\n' "$domain"
    done
}

certificate_automation_read() {
    local domain=$1 mode days phase extra file
    validate_proxy_domain "$domain" >/dev/null || return 1
    file=$CERT_STATE_DIR/automation/${domain,,}
    [ -e "$file" ] || { [ ! -L "$file" ] && return 2; return 1; }
    certificate_controlled_path "$CERT_STATE_DIR/automation" && certificate_safe_file "$file" || return 1
    [ "$(stat -c %u -- "$file")" = 0 ] && [ "$(awk 'END {print NR}' "$file")" = 1 ] || return 1
    read -r mode days phase extra < "$file" || return 1
    case "$mode:$phase" in on:waiting|on:active|off:waiting|off:fixed) ;; *) return 1 ;; esac
    [[ "$days" =~ ^[0-9]{1,3}$ ]] && [ -z "$extra" ] || return 1
    if [ "$mode" = on ]; then [ "$days" -ge 1 ] && [ "$days" -le 365 ] || return 1
    else [ "$days" = 0 ] || return 1; fi
    printf '%s %s %s\n' "$mode" "$days" "$phase"
}

certificate_select_pair() {
    local root=$1 domain=$2 cert times expires starts best='' best_end=0 best_start=0
    local -a choices
    mapfile -d '' -t choices < <(certificate_candidates "$root" "$domain")
    wait "$!" || return 1
    local fixed rule fixed_file
    if rule=$(certificate_automation_read "$domain") && [[ "$rule" = 'off 0 fixed' ]]; then
        fixed=$(dirname -- "$CADDYFILE")/easy-caddy-fixed/$domain
        choices=()
        for fixed_file in "$fixed"/.pair.*/"$domain.crt"; do
            [ -f "$fixed_file" ] && choices+=("$fixed_file")
        done
    fi
    for cert in "${choices[@]}"; do
        times=$(certificate_pair_valid "$cert" "${cert%.crt}.key" "$domain" 2>/dev/null) || continue
        read -r expires starts <<< "$times"
        if [ -z "$best" ] || [ "$expires" -gt "$best_end" ] ||
            { [ "$expires" -eq "$best_end" ] && [ "$starts" -gt "$best_start" ]; } ||
            { [ "$expires" -eq "$best_end" ] && [ "$starts" -eq "$best_start" ] && [[ "$cert" < "$best" ]]; }; then
            best=$cert; best_end=$expires; best_start=$starts
        fi
    done
    [ -n "$best" ] || return 2
    printf '%s\n' "$best"
}

certificate_renewal_ratio() {
    local cert=$1 days=$2 first last lifetime
    [[ "$days" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$days" -le 365 ] || {
        certificate_error '请填写 1 到 365 之间的整数天数。'; return 1;
    }
    [ -n "$cert" ] || { printf '0.33333333\n'; return 0; }
    first=$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null) &&
        last=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null) || return 1
    first=$(date -d "${first#notBefore=}" +%s) && last=$(date -d "${last#notAfter=}" +%s) || return 1
    lifetime=$((last-first))
    [ "$lifetime" -gt "$((days*86400))" ] || {
        certificate_error "提前 $days 天已达到或超过这张证书的总有效期，请选择更小的天数。"; return 1;
    }
    LC_ALL=C awk -v days="$days" -v seconds="$lifetime" 'BEGIN {printf "%.8f\n", days*86400/seconds}'
}

certificate_automation_describe() {
    local domain=$1 rule mode days phase rc
    rule=$(certificate_automation_read "$domain"); rc=$?
    if [ "$rc" = 2 ]; then printf '自动续签：沿用 Caddy 原有设置（尚未在此单独设置）。\n'; return 0; fi
    [ "$rc" = 0 ] || { certificate_error '暂时无法可靠读取此域名的续签设置。'; return 1; }
    read -r mode days phase <<< "$rule"
    if [ "$mode" = on ]; then
        printf '自动续签：已开启，目标在到期前 %s 天进入续签窗口。\n' "$days"
        [ "$phase" != waiting ] || printf '  首次签发后会按实际有效期换算；目前先使用 Caddy 默认窗口。\n'
        printf '  CA 可能要求更早续签；服务和域名验证必须保持可用。\n'
    elif [ "$phase" = fixed ]; then
        printf '自动续签：已关闭，当前加载固定证书；到期前需要手动重新开启续签。\n'
    else
        printf '自动续签：已选择关闭；等待首次签发，完成后后台任务会切换为固定证书。\n'
    fi
}

# Only the marked TLS segment is ours; the rest of the user's site is retained.
certificate_fixed_copy() (
    umask 077
    local cert=$1 domain=$2 base stage key=${1%.crt}.key
    base=$(dirname -- "$CADDYFILE")/easy-caddy-fixed/$domain
    certificate_controlled_path "$base" || return 1
    mkdir -p -m 755 -- "$base" || return 1
    stage=$(mktemp -d "$base/.pair.XXXXXX") || return 1
    if ! cp -- "$cert" "$stage/$domain.crt" || ! cp -- "$key" "$stage/$domain.key" ||
        ! chmod 600 -- "$stage/$domain.crt" "$stage/$domain.key" ||
        ! chown --reference="$key" -- "$stage" "$stage/$domain.crt" "$stage/$domain.key" ||
        ! certificate_pair_valid "$stage/$domain.crt" "$stage/$domain.key" "$domain" >/dev/null; then
        rm -rf -- "$stage"; certificate_error '固定证书副本未能安全保存，续签设置未改动。'; return 1
    fi
    printf '%s/%s.crt\n' "$stage" "$domain"
)

certificate_policy_candidate() {
    local input=$1 output=$2 domain=$3 policy=$4 allow_new=${5:-no} span start finish total first status
    caddy_site_span "$input" "$domain" check; status=$?
    if [ "$status" = 10 ]; then
        span=$(caddy_site_span "$input" "$domain" delete) || return 1
        read -r start finish <<< "$span"
        (set -o pipefail; head -c "$finish" -- "$input" | tail -c "$((finish-start))") > "$output.site" || return 1
        IFS= read -r first < "$output.site" || return 1
        if ! [[ "$first" =~ ^[[:space:]]*(https://)?${domain//./\.}[[:space:]]*\{[[:space:]]*$ ]]; then
            certificate_error '这个站点的地址写法较复杂或仅启用了 HTTP，请用手动编辑调整 TLS；原配置保持不变。'; return 1
        fi
        LC_ALL=C awk -v domain="$domain" '
            $0 == "    # easy-caddy-certificate-policy-begin " domain {if (inside || seen++) exit 9; inside=1; next}
            $0 == "    # easy-caddy-certificate-policy-end " domain {if (!inside) exit 9; inside=0; next}
            !inside {print}
            END {if (inside) exit 9}
        ' "$output.site" > "$output.clean" || { certificate_error '脚本管理的 TLS 标记不完整，未覆盖。'; return 1; }
        if grep -Eq '^[[:space:]]*(tls|import)[[:space:]]' "$output.clean"; then
            certificate_error '此站点已有手工 TLS 或 import 设置；为保留你的配置，请先在手动编辑中处理，未自动覆盖。'; return 1
        fi
        head -c "$start" -- "$input" > "$output" || return 1
        {
            IFS= read -r first
            printf '%s\n    # easy-caddy-certificate-policy-begin %s\n' "$first" "$domain"
            cat -- "$policy"
            printf '    # easy-caddy-certificate-policy-end %s\n' "$domain"
            cat
        } < "$output.clean" >> "$output" || return 1
        total=$(wc -c < "$input") || return 1
        tail -c "$((total-finish))" -- "$input" >> "$output" || return 1
    else
        [ "$status" = 0 ] || return 1
        [ "$allow_new" = yes ] || { certificate_error '没有找到可单独管理的站点；可先选择“申请证书”。'; return 1; }
        if grep -Eq '(^|[[:space:],])\*\.[^[:space:]]+' "$input"; then
            certificate_error '当前配置含通配域名，新增精确站点可能遮蔽原有内容；请用手动配置申请，原站点保持不变。'; return 1
        fi
        cat -- "$input" > "$output" || return 1
        {
            printf '\n%s {\n    # easy-caddy-certificate-policy-begin %s\n' "$domain" "$domain"
            cat -- "$policy"
            printf '    # easy-caddy-certificate-policy-end %s\n    respond "This host is managed for certificate issuance." 404\n}\n' "$domain"
        } >> "$output" || return 1
    fi
}

certificate_automation_set() (
    umask 077
    local domain=${1:-} mode=${2:-} days=${3:-30} origin=${4:-menu} root cert='' rule ratio phase
    local directory lock_fd work file stage backup candidate_copy result old_rule saved_mode saved_days saved_phase keep_work=0 config_changed=0 restore_work
    validate_proxy_domain "$domain" >/dev/null || return 1
    domain=${domain,,}; domain=${domain%.}
    case "$mode" in
        on) [[ "$days" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$days" -le 365 ] || {
                certificate_error '请填写 1 到 365 之间的整数天数。'; return 1; } ;;
        off) days=0 ;;
        *) certificate_error '续签选项无效，请选择开启或关闭。'; return 1 ;;
    esac
    if [ "$mode" = on ]; then
        if ! printf 'probe.invalid {\n tls {\n renewal_window_ratio 0.33333333\n }\n respond "test"\n}\n' |
            caddy adapt --adapter caddyfile --config - >/dev/null 2>&1; then
            certificate_error '当前 Caddy 不支持设置续签窗口，请先更新 Caddy 后重试（已验证 2.11.7 支持，2.10.2 不支持）；原配置未改动。'
            return 1
        fi
    fi
    certificate_dependencies && certificate_state_prepare || return 1
    directory=$CERT_STATE_DIR/automation
    certificate_controlled_path "$directory" || return 1
    [ -d "$directory" ] || mkdir -m 700 -- "$directory" || return 1
    file=$directory/$domain
    if [ -e "$file" ] || [ -L "$file" ]; then certificate_automation_read "$domain" >/dev/null || return 1; fi
    for stage in "$CERT_STATE_DIR/automation.lock"; do
        [ ! -e "$stage" ] && [ ! -L "$stage" ] || certificate_safe_file "$stage" || return 1
    done
    exec {lock_fd}> "$CERT_STATE_DIR/automation.lock" || return 1
    flock -x -w 20 "$lock_fd" || { certificate_error '另一项证书设置正在保存，请稍后再试。'; return 1; }
    # An old worker snapshot must not replace a concurrently changed user rule.
    if [ "$origin" = maintenance ]; then
        rule=$(certificate_automation_read "$domain") || return 1
        read -r mode days phase <<< "$rule"
    fi
    # Once disabled, expiry or storage cleanup must never re-enable issuance.
    if [ "$mode" = off ] && old_rule=$(certificate_automation_read "$domain"); then
        read -r saved_mode saved_days saved_phase <<< "$old_rule"
        if [ "$saved_mode:$saved_phase" = off:fixed ]; then
            [ "$origin" = maintenance ] || certificate_automation_describe "$domain"
            return 0
        fi
    fi
    root=$(certificate_storage_root) || return 1
    cert=$(certificate_select_pair "$root" "$domain"); result=$?
    [ "$result" = 0 ] || [ "$result" = 2 ] || return 1
    phase=waiting
    if [ "$mode" = on ]; then
        ratio=$(certificate_renewal_ratio "$cert" "$days") || return 1
        [ -z "$cert" ] || phase=active
    elif [ -n "$cert" ]; then
        # A loaded SAN certificate would affect other sites too; refuse that scope.
        if [ "$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -oE '(DNS:|IP Address:)[^,]+' | wc -l)" != 1 ]; then
            certificate_error '当前证书覆盖多个域名，关闭其续签会影响其他站点，未自动修改。'; return 1
        fi
        phase=fixed
    fi
    work=$(mktemp -d "$(dirname -- "$CADDYFILE")/.easy-caddy-policy.XXXXXX") || return 1
    trap 'case "${stage:-}" in "$directory"/.rule.*) rm -f -- "$stage";; esac; [ -z "${candidate_copy:-}" ] || rm -f -- "$candidate_copy"; if [ "$keep_work" = 0 ]; then rm -rf -- "$work"; fi' EXIT
    caddy_config_lock || return 1
    stat -c '%d:%i:%u:%g:%a:%s:%y:%z' -- "$CADDYFILE" > "$work/original.identity" &&
        cp -p -- "$CADDYFILE" "$work/original.caddy" || return 1
    flock -u "$CADDY_LOCK_FD"
    exec {CADDY_LOCK_FD}<&-
    if grep -Eq '^[[:space:]]*auto_https([[:space:]]+|$)' "$work/original.caddy"; then
        certificate_error 'Caddyfile 已有全局 auto_https 自定义设置；请先手动核对，避免覆盖其签发意图。'; return 1
    fi
    if [ "$mode" = off ] && [ -n "$cert" ]; then
        cert=$(certificate_fixed_copy "$cert" "$domain") || return 1
        printf '    tls %s %s\n' "$(log_rotation_quote "$cert")" "$(log_rotation_quote "${cert%.crt}.key")" > "$work/policy"
    elif [ "$mode" = on ]; then
        printf '    tls {\n        renewal_window_ratio %s\n    }\n' "${ratio:-0.33333333}" > "$work/policy"
    else
        printf '    # Waiting for the first certificate before loading a fixed copy.\n' > "$work/policy"
    fi
    local allow_new=no
    [ "$origin" != request ] || allow_new=yes
    certificate_policy_candidate "$work/original.caddy" "$work/candidate.caddy" "$domain" "$work/policy" "$allow_new" || return 1
    stage=$(mktemp "$directory/.rule.XXXXXX") || return 1
    printf '%s %s %s\n' "$mode" "$days" "$phase" > "$stage" || return 1
    candidate_copy=$(mktemp "$directory/.candidate.XXXXXX") || return 1
    cp -- "$work/candidate.caddy" "$candidate_copy" || return 1
    if cmp -s -- "$work/original.caddy" "$work/candidate.caddy"; then
        rm -rf -- "$work"
    else
        backup=$(mktemp "${CADDYFILE}.manual-backup.$(date -u +%Y%m%dT%H%M%S).XXXXXX") || return 1
        cp -p -- "$work/original.caddy" "$backup" && printf '%s\n' "$backup" > "$work/backup-path" || return 1
        keep_work=1
        if ! caddy_manual_commit "$work"; then rm -f -- "$candidate_copy"; return 1; fi
        keep_work=0; config_changed=1
    fi
    if ! cmp -s -- "$stage" "$file"; then
        if ! mv -fT -- "$stage" "$file"; then
            if [ "$config_changed" = 0 ]; then
                certificate_error '续签记录未能保存；配置原本无需修改，原文件和原设置保持不变。'
            elif cmp -s -- "$candidate_copy" "$CADDYFILE"; then
                certificate_error '续签记录未能保存，正在恢复原配置。'
                restore_work=$(mktemp -d "$(dirname -- "$CADDYFILE")/.easy-caddy-policy-restore.XXXXXX") || return 1
                stat -c '%d:%i:%u:%g:%a:%s:%y:%z' -- "$CADDYFILE" > "$restore_work/original.identity" &&
                    cp -p -- "$CADDYFILE" "$restore_work/original.caddy" &&
                    cp -- "$backup" "$restore_work/candidate.caddy" &&
                    printf '%s\n' "$backup" > "$restore_work/backup-path" || return 1
                flock -u "$CADDY_LOCK_FD"
                exec {CADDY_LOCK_FD}<&-
                caddy_manual_commit "$restore_work" || return 1
            else certificate_error "配置另有变动，未覆盖；原配置备份：$backup"; fi
            rm -f -- "$candidate_copy"; return 1
        fi
    fi
    rm -f -- "$candidate_copy"
    if [ "$origin" != maintenance ]; then
        install_certificate_sync_timer || { certificate_error '续签设置已保存，但后台维护任务未启用，请重试；可暂时留在等待页面。'; return 1; }
        certificate_automation_describe "$domain"
    fi
)

certificate_automation_run() {
    local domains domain rule mode days phase failed=0
    domains=$(certificate_automation_domains) || return 1
    [ -n "$domains" ] || return 0
    while IFS= read -r domain; do
        rule=$(certificate_automation_read "$domain") || { failed=1; continue; }
        read -r mode days phase <<< "$rule"
        certificate_automation_set "$domain" "$mode" "$days" maintenance || failed=1
    done <<< "$domains"
    return "$failed"
}

certificate_request() {
    local domain=${1:-} mode=${2:-on} days=${3:-30}
    certificate_automation_set "$domain" "$mode" "$days" request || return 1
    printf '\n证书申请已交给 Caddy：%s。\n' "$domain"
    printf '签发完成时间由域名验证和 CA 决定；已存在的有效证书会直接使用，不会重复强制申请。\n'
}

certificate_renewal_choice() {
    local answer days
    CERT_RENEWAL_MODE=on; CERT_RENEWAL_DAYS=30
    printf '首次申请完成后，是否自动续签？[Y/n，回车开启]：\n'
    IFS= read -r answer || return 1
    case "${answer,,}" in
        n|no) CERT_RENEWAL_MODE=off; CERT_RENEWAL_DAYS=0
            printf '将仅申请这一次；首次签发后由后台任务切换为固定证书，之后需自行处理到期。\n'; return 0 ;;
        y|yes|'') ;;
        *) certificate_error '请输入 y/yes 或 n/no。'; return 1 ;;
    esac
    printf '希望在到期前多少天开始续签？[1–365，回车 30]：\n'
    IFS= read -r days || return 1
    days=${days:-30}
    [[ "$days" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$days" -le 365 ] || { certificate_error '请输入 1 到 365 的整数。'; return 1; }
    CERT_RENEWAL_DAYS=$days
    printf '将按实际证书有效期换算为 Caddy 续签窗口；CA 的续签建议可能让时间更早。\n'
}

certificate_request_menu() {
    local domain
    printf '为域名申请证书，无需先配置反代。已有站点会保留原来的内容与上游。\n'
    printf '请确保域名解析到本机，且 CA 能访问 80 或 443 端口；通配符及手工 DNS 验证请使用手动配置。\n\n'
    ui_ask '请输入要申请证书的域名（空输入取消）：'
    IFS= read -r domain || return 1
    [ -n "$domain" ] || return 0
    validate_proxy_domain "$domain" || return 1
    domain=${domain,,}; domain=${domain%.}
    certificate_renewal_choice && certificate_collect_choice "$domain" || return 1
    certificate_request "$domain" "$CERT_RENEWAL_MODE" "$CERT_RENEWAL_DAYS" || return 1
    certificate_after_proxy "$domain"
}

certificate_renewal_menu() {
    certificate_overview state && certificate_select_domain available || return 1
    certificate_automation_describe "$CERT_SELECTED_DOMAIN" || return 1
    certificate_renewal_choice || return 1
    certificate_automation_set "$CERT_SELECTED_DOMAIN" "$CERT_RENEWAL_MODE" "$CERT_RENEWAL_DAYS"
}

# Successful adapt warnings are diagnostics, never certificate states. Failed parses retain details.
caddy_adapt_quiet() (
    umask 077
    local diagnostic code
    diagnostic=$(mktemp) || return 1
    trap 'rm -f -- "$diagnostic"' EXIT
    "$@" 2> "$diagnostic"; code=$?
    if [ "$code" -ne 0 ]; then
        certificate_error 'Caddy 无法解析当前配置，暂时不能确认签发状态；请根据下方原因修正。'
        tail -n 20 -- "$diagnostic" >&2
    fi
    return "$code"
)

# Human-facing certificate views. Raw engine details remain available explicitly.
certificate_normalize_destination_input() {
    local input=${1:-}
    case "$input" in
        '~'|'~/'*) [[ "${HOME:-}" = /* ]] || { certificate_error '当前用户的主目录不可用，请输入绝对路径。'; return 1; }
            printf '%s\n' "$HOME${input#\~}" ;;
        '~'*) certificate_error '只支持 ~ 或 ~/；其他用户的目录请填写完整路径。'; return 1 ;;
        *) printf '%s\n' "$input" ;;
    esac
}

certificate_destination_preview() {
    local parent=$1 domain=$2
    validate_proxy_domain "$domain" >/dev/null || return 1
    parent=$(certificate_normalize_destination_input "$parent") || return 1
    parent=$(certificate_absolute_path "$parent") || return 1
    domain=${domain,,}; domain=${domain%.}
    printf '\n你选择的是父目录：%s\n' "$parent"
    printf '脚本会自动追加域名目录，最终文件是：\n  %s/%s/fullchain.pem\n  %s/%s/privkey.pem\n' "$parent" "$domain" "$parent" "$domain"
    if [ "${parent##*/}" = "$domain" ]; then
        printf '注意：父目录末尾已经是域名，以上路径会重复一层。通常应填它的上一级目录：%s\n' "${parent%/*}"
    else printf '请填写父目录即可，不需要再手动添加域名。\n'; fi
}

certificate_ui_human_date() { date -d "@$1" '+%Y-%m-%d %H:%M %Z'; }

certificate_ui_export_result() {
    local dest=$1 domain=$2 current=${3:-} pair
    if [ ! -e "$dest/$domain/fullchain.pem" ] && [ ! -e "$dest/$domain/privkey.pem" ]; then
        printf '尚未复制；签发完成后由后台任务复制。'; return 0
    fi
    if ! pair=$(certificate_pair_valid "$dest/$domain/fullchain.pem" "$dest/$domain/privkey.pem" "$domain" 2>&1); then
        printf '已有副本未通过校验，旧文件保留；请查看详细信息。'; return 1
    fi
    if [ -n "$current" ] && { ! cmp -s -- "$current" "$dest/$domain/fullchain.pem" || ! cmp -s -- "${current%.crt}.key" "$dest/$domain/privkey.pem"; }; then
        printf '已有副本；Caddy 已有更新版本，等待下一次同步。'
    else printf '已复制，证书与私钥配对有效。'; fi
}

certificate_ui_domain_status() {
    local root=$1 domain=$2 registered=$3 dest=$4 cert='' code times expires starts now days issuer
    printf '\n域名：%s\n' "$domain"
    cert=$(certificate_select_pair "$root" "$domain"); code=$?
    if [ "$code" = 0 ]; then
        times=$(certificate_pair_valid "$cert" "${cert%.crt}.key" "$domain") || return 1
        read -r expires starts <<< "$times"
        now=$(date +%s); days=$(((expires-now)/86400))
        printf '  证书已签发，当前有效，证书与私钥匹配。\n'
        printf '  生效时间：%s\n  到期时间：%s（剩余 %s 天）\n' "$(certificate_ui_human_date "$starts")" "$(certificate_ui_human_date "$expires")" "$days"
        issuer=$(openssl x509 -in "$cert" -noout -issuer -nameopt multiline 2>/dev/null | awk -F'= *' '/organizationName/{print $2; exit}')
        [ -n "$issuer" ] || issuer=$(openssl x509 -in "$cert" -noout -issuer -nameopt multiline 2>/dev/null | awk -F'= *' '/commonName/{print $2; exit}')
        printf '  签发机构：%s（这里只核对文件和配对，未验证公网信任链）\n' "${issuer:-无法读取}"
    elif [ "$code" = 2 ]; then
        local found
        found=$(certificate_candidates "$root" "$domain" | tr '\0' '\n') || return 1
        if [ -n "$found" ]; then
            printf '  已发现证书文件，但已过期、尚未生效或配对异常；请查看技术详情，原副本不会被覆盖。\n'
        elif [[ "$(certificate_automation_read "$domain")" = 'off 0 fixed' ]]; then
            printf '  固定证书已到期或不可读取；自动续签保持关闭，请在到期前手动处理。\n'
        else printf '  正在等待签发，目前还没有发现可用证书（待签发/未发现）。\n'; fi
    else return 1; fi
    certificate_automation_describe "$domain" || return 1
    if [ "$registered" = yes ]; then
        printf '  自动复制：已登记。\n'
        if [ -n "$dest" ]; then
            printf '  复制结果：'; certificate_ui_export_result "$dest" "$domain" "$cert"; printf '\n'
            printf '  证书文件：%s/%s/fullchain.pem\n  私钥文件：%s/%s/privkey.pem\n' "$dest" "$domain" "$dest" "$domain"
        else printf '  复制位置尚未设置，请先选择父目录。\n'; fi
    else printf '  自动复制：未登记；证书仍保留在 Caddy 自己的证书目录里。\n'; fi
}

certificate_watch_domain() {
    local domain=$1 root domains dest='' registered=no answer code cert elapsed began=0
    # Scripts and workers must never consume extra input or do interactive writes.
    ui_interactive || return 0
    validate_proxy_domain "$domain" >/dev/null || return 1
    root=$(certificate_storage_root) || return 1
    domains=$(certificate_read_domains) || return 1
    if printf '%s\n' "$domains" | grep -Fxq -- "$domain"; then
        registered=yes; dest=$(certificate_read_directory) || return 1
    fi
    printf '\n现在可以留在这里等待证书，不需要猜测什么时候申请完成。\n'
    certificate_ui_domain_status "$root" "$domain" "$registered" "$dest" || return 1
    cert=$(certificate_select_pair "$root" "$domain"); code=$?
    if [ "$code" = 0 ]; then
        certificate_automation_run || printf '续签策略尚未完全应用，请查看证书管理中的提示。\n'
        [ "$registered" != yes ] || sync_certificates "$domain"
        printf '\n证书已经准备好，可以返回菜单。\n'; return 0
    fi
    printf '\n回车：留在此页自动刷新；r：返回菜单，Caddy 和后台任务继续申请/检查。\n请选择 > '
    IFS= read -r answer || return 0
    [ -z "$answer" ] || return 0
    began=$SECONDS
    while true; do
        cert=$(certificate_select_pair "$root" "$domain"); code=$?
        if [ "$code" = 0 ]; then
            printf '\n证书已经签发完成！\n'
            certificate_automation_run || printf '续签设置尚待后台重试，请查看详细信息。\n'
            if [ "$registered" = yes ]; then
                if sync_certificates "$domain"; then printf '复制检查已完成，下面显示最终文件状态。\n'
                else printf '证书已签发，但复制没有成功；原有文件保留，可在菜单重试同步。\n'; fi
            fi
            certificate_ui_domain_status "$root" "$domain" "$registered" "$dest"
            return 0
        fi
        [ "$code" = 2 ] || return 1
        elapsed=$((SECONDS-began))
        printf '已等待 %s 秒，还在等待可用证书。输入 r 并回车可返回菜单。\n' "$elapsed"
        if [ "$elapsed" -ge 120 ]; then
            printf '已等候两分钟。回车继续等待，输入其他内容返回菜单：'
            IFS= read -r answer || return 0
            [ -z "$answer" ] || return 0
            began=$SECONDS
        fi
        if IFS= read -r -t 3 answer; then
            case "${answer,,}" in r|0|q) printf '已返回；Caddy 与后台任务会继续处理。\n'; return 0 ;; esac
        else
            code=$?
            [ "$code" -gt 128 ] || return 0
        fi
    done
}

certificate_main_summary() {
    local domains domain dest='' summary total=0 ready=0
    domains=$(certificate_read_domains 2>/dev/null) || { printf '  证书状态暂时无法读取，请进入 12 查看原因。\n'; return 0; }
    [ -n "$domains" ] || return 0
    dest=$(certificate_read_directory 2>/dev/null) || { printf '  已登记证书复制，但父目录不可读，请进入 12 处理。\n'; return 0; }
    while IFS= read -r domain; do
        total=$((total+1))
        if certificate_pair_valid "$dest/$domain/fullchain.pem" "$dest/$domain/privkey.pem" "$domain" >/dev/null 2>&1; then
            ready=$((ready+1)); printf '  %s：证书已复制，可使用。\n' "$domain"
        else printf '  %s：尚未复制可用证书，请进入 12 查看签发进度。\n' "$domain"; fi
    done <<< "$domains"
    printf '  证书副本：%s/%s 已准备好；详情在 12 证书管理。\n' "$ready" "$total"
}

certificate_set_directory_menu() {
    local path domains domain duplicate=no answer
    certificate_overview state || return 1
    printf '这里填写父目录；脚本会在下方自动创建每个域名的子目录。\n'
    ui_ask '请输入证书父目录（绝对路径或 ~/；空输入取消）：'
    IFS= read -r path || return 0
    [ -n "$path" ] || { printf '已取消。\n'; return 0; }
    path=$(certificate_normalize_destination_input "$path") || return 1
    path=$(certificate_validate_destination "$path") || return 1
    domains=$(certificate_read_domains) || return 1
    if [ -z "$domains" ]; then certificate_destination_preview "$path" example.com || return 1
    else
        while IFS= read -r domain; do
            certificate_destination_preview "$path" "$domain" || return 1
            [ "${path##*/}" != "$domain" ] || duplicate=yes
        done <<< "$domains"
    fi
    if [ "$duplicate" = yes ]; then
        printf '以上路径会重复域名。仍按这个父目录保存？[y/yes，默认 n]：\n'
        IFS= read -r answer || return 1
        case "${answer,,}" in y|yes) ;; *) printf '已取消，请选择上一级父目录。\n'; return 0 ;; esac
    fi
    set_certificate_export_directory "$path"
}

# Root already has privileges. Avoid repeated sudo hostname-resolution noise in
# this script process only; sourcing must not replace the caller's sudo command.
if [ "$EUID" = 0 ] && [ "${EASY_CADDY_TEST_MODE:-0}" != 1 ] && [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    sudo() { command "$@"; }
fi

# Script updates are explicit operations, independent of Caddy/configuration.
script_version_valid() {
    [[ "$1" =~ ^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$ ]]
}

script_version_from_file() {
    local file=$1 line version='' count=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^SCRIPT_VERSION=\'([0-9]+\.[0-9]+\.[0-9]+)\'$ ]]; then
            version=${BASH_REMATCH[1]}; count=$((count+1))
        fi
    done < "$file"
    [ "$count" = 1 ] && script_version_valid "$version" || return 1
    printf '%s\n' "$version"
}

script_version_compare() {
    script_version_valid "$1" && script_version_valid "$2" || return 1
    local index left right
    local -a current candidate
    IFS=. read -r -a current <<< "$1"
    IFS=. read -r -a candidate <<< "$2"
    for index in 0 1 2; do
        left=$((10#${current[index]})); right=$((10#${candidate[index]}))
        if [ "$left" -lt "$right" ]; then printf '%s\n' -1; return 0; fi
        if [ "$left" -gt "$right" ]; then printf '%s\n' 1; return 0; fi
    done
    printf '0\n'
}

# Return 10 only after replacement: the caller must finish the old process.
script_update() (
    umask 077
    local action=${1:-check} target directory work stage='' backup='' lock lock_fd
    local original_identity original_hash current_identity remote_version comparison answer tool
    case "$action" in check|apply) ;; *) certificate_error '更新操作无效。'; return 2 ;; esac
    for tool in curl bash realpath stat sha256sum mktemp grep head wc cp mv chmod chown flock; do
        command -v "$tool" >/dev/null 2>&1 || { certificate_error "缺少 $tool，暂时无法检查或更新；请先在依赖菜单处理。"; return 1; }
    done
    target=$(certificate_absolute_path "$(realpath -ms -- "${BASH_SOURCE[0]}")") || return 1
    certificate_safe_file "$target" || { certificate_error '当前脚本不是独立普通文件，请先下载到本地再更新。'; return 1; }
    directory=$(dirname -- "$target")
    original_identity=$(stat -c '%d:%i:%u:%g:%a:%s:%y:%z' -- "$target") || return 1
    original_hash=$(sha256sum -- "$target") || return 1
    [ "$(script_version_from_file "$target")" = "$SCRIPT_VERSION" ] || {
        certificate_error '磁盘脚本与当前加载版本不同，请重新运行脚本后再检查更新。'; return 1;
    }
    printf '当前脚本版本：%s\n更新来源：duya07/easy_Caddy 的 main 分支。\n' "$SCRIPT_VERSION"
    work=$(mktemp -d) || return 1
    trap 'rm -rf -- "$work"; [ -z "$stage" ] || rm -f -- "$stage"' EXIT
    if ! curl --fail --silent --show-error --location --max-redirs 3 \
        --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 45 --retry 1 \
        --max-filesize 2097152 --output "$work/candidate.sh" "$SCRIPT_UPDATE_SOURCE_URL" 2> "$work/download.log"; then
        certificate_error '暂时无法下载新版脚本，可能是网络或下载源不可用；当前脚本保持不变。'
        return 1
    fi
    if [ ! -s "$work/candidate.sh" ] || [ "$(wc -c < "$work/candidate.sh")" -gt 2097152 ] ||
        [ "$(head -n 1 -- "$work/candidate.sh")" != '#!/usr/bin/env bash' ] ||
        ! grep -Fxq '# EASY_CADDY_SCRIPT_ID=duya07/easy_Caddy' "$work/candidate.sh"; then
        certificate_error '下载结果不是可识别的 easy_Caddy 脚本，当前文件保持不变。'; return 1
    fi
    remote_version=$(script_version_from_file "$work/candidate.sh") || {
        certificate_error '下载的脚本没有唯一、有效的版本号，可能是旧版或异常页面；当前文件保持不变。'; return 1;
    }
    if ! env -u BASH_ENV -u ENV bash --noprofile --norc -n "$work/candidate.sh" 2> "$work/syntax.log"; then
        certificate_error '下载的脚本没有通过 Bash 语法检查，当前文件保持不变。'; return 1
    fi
    comparison=$(script_version_compare "$SCRIPT_VERSION" "$remote_version") || return 1
    printf '线上脚本版本：%s\n' "$remote_version"
    case "$comparison" in
        0) printf '你已经在使用当前版本，无需更新。\n'; return 0 ;;
        1) printf '本地版本比线上版本更新，本次不降级。\n'; return 0 ;;
    esac
    if [ "$action" = check ]; then
        printf '有新版本可用。可在主菜单 14 更新，或运行：bash ./easyCaddy.sh --update\n'
        return 0
    fi
    [ "$(stat -c %u -- "$target")" = "$EUID" ] && [ -w "$directory" ] || {
        certificate_error '没有权限替换此脚本，请使用脚本所属用户执行（root 文件请用 sudo）。'; return 1;
    }
    if [ "$EUID" = 0 ]; then certificate_controlled_path "$directory" || return 1; fi
    printf '\n将把 %s 更新为 %s。\n' "$SCRIPT_VERSION" "$remote_version"
    printf '会先备份当前脚本；你的反代配置、证书、目录登记和运行中的服务不会被修改。\n'
    printf '更新成功后本次会话将结束，请重新运行脚本。确认更新？[y/yes，默认 n]：\n'
    IFS= read -r answer || { printf '输入结束，已取消更新。\n'; return 0; }
    case "${answer,,}" in y|yes) ;; *) printf '已取消更新，当前脚本保持不变。\n'; return 0 ;; esac
    lock=$target.update.lock
    if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then (set -o noclobber; : > "$lock") 2>/dev/null || :; fi
    certificate_safe_file "$lock" && [ "$(stat -c %u -- "$lock")" = "$EUID" ] || {
        certificate_error '更新锁不可安全使用，当前脚本保持不变。'; return 1;
    }
    exec {lock_fd}< "$lock" || return 1
    flock -x -w 10 "$lock_fd" || { certificate_error '另一个更新正在进行，请稍后重试。'; return 1; }
    certificate_safe_file "$target" || return 1
    current_identity=$(stat -c '%d:%i:%u:%g:%a:%s:%y:%z' -- "$target") || return 1
    if [ "$original_identity" != "$current_identity" ] || [ "$original_hash" != "$(sha256sum -- "$target")" ]; then
        certificate_error '等待期间脚本被其他操作改动，未覆盖；请重新运行后再更新。'; return 1
    fi
    stage=$(mktemp "$directory/.easy-caddy-update.XXXXXX") || return 1
    cp -- "$work/candidate.sh" "$stage" && chmod --reference="$target" -- "$stage" &&
        chown --reference="$target" -- "$stage" || { certificate_error '新版暂存失败，当前脚本保持不变。'; return 1; }
    backup=$(mktemp "$target.backup.$SCRIPT_VERSION.$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || return 1
    if ! cp -p -- "$target" "$backup" || ! cmp -s -- "$target" "$backup"; then
        certificate_error "备份没有完成，未替换脚本；请检查：$backup"; return 1
    fi
    if ! certificate_safe_file "$target" || [ "$original_identity" != "$(stat -c '%d:%i:%u:%g:%a:%s:%y:%z' -- "$target")" ] ||
        [ "$original_hash" != "$(sha256sum -- "$target")" ]; then
        certificate_error "脚本又发生了变动，未覆盖；备份：$backup"; return 1
    fi
    if ! mv -fT -- "$stage" "$target"; then
        certificate_error "替换失败，原脚本保留；备份：$backup"; return 1
    fi
    stage=''
    printf '\n更新成功：%s → %s。\n备份：%s\n请重新运行：bash "%s"\n' "$SCRIPT_VERSION" "$remote_version" "$backup" "$target"
    if [ -f "$CERT_WORKER_INSTALL_DIR/easyCaddy.sh" ]; then
        printf '证书后台快照仍按原版运行；需要刷新时，可重新开启一次证书复制或保存续签设置。\n'
    fi
    return 10
)

# Source callers load functions without reading stdin or entering any menu.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi
if [ "$#" -gt 0 ]; then
    case "$1" in
        --version)
            [ "$#" = 1 ] || { certificate_error '用法：--version'; exit 2; }
            printf 'easy_Caddy %s\n' "$SCRIPT_VERSION"; exit 0 ;;
        --check-update|--update)
            [ "$#" = 1 ] || { certificate_error '用法：--check-update 或 --update'; exit 2; }
            if [ "$1" = --check-update ]; then script_update check; update_result=$?
            else script_update apply; update_result=$?; fi
            [ "$update_result" != 10 ] || update_result=0
            exit "$update_result" ;;
        --sync-certificates)
            [ "$#" -le 2 ] || { certificate_error '用法：--sync-certificates [DOMAIN]'; exit 2; }
            sync_certificates "${2:-}"
            exit $? ;;
        --certificate-maintenance)
            [ "$#" = 1 ] || { certificate_error '用法：--certificate-maintenance'; exit 2; }
            certificate_automation_run; maintenance_result=$?
            sync_certificates || maintenance_result=1
            exit "$maintenance_result" ;;
        *) certificate_error "未知参数：$1"; exit 2 ;;
    esac
fi

#--------------------------------------------
# 主循环
#--------------------------------------------
while true; do
    show_menu
    read -p '请输入选项: ' opt || break
    case "$opt" in
        1) ui_page '安装 Caddy'
            if check_caddy_installed; then printf 'Caddy 已安装，跳过安装。\n'
            else install_caddy; fi ;;
        2) ui_page '依赖检测与安装'; dependency_install_menu ;;
        3) if ! check_caddy_installed; then
                ui_page '安装 Caddy'; printf 'Caddy 未安装，先执行安装步骤。\n'; install_caddy
            fi
            reverse_proxy_menu; continue ;;
        4) ui_page 'Caddy 服务状态'; show_caddy_status ;;
        5) ui_page '当前反向代理配置'; show_reverse_proxies ;;
        6) ui_page '删除反向代理'; delete_reverse_proxy ;;
        7) ui_page '重启 Caddy 服务'; restart_caddy ;;
        8) logs_menu; continue ;;
        9) ui_page '日志轮转设置'; log_rotation_menu ;;
        10) ui_page '卸载 Caddy'; remove_caddy ;;
        11) ui_page '依赖卸载'; dependency_uninstall_menu ;;
        12) certificate_menu; continue ;;
        13) ui_page '手动编辑 Caddy 配置'; manual_edit_caddyfile ;;
        14) ui_page '脚本版本与更新'
            script_update apply; update_result=$?
            if [ "$update_result" = 10 ]; then exit 0; fi ;;
        0) printf '退出脚本。\n'; exit 0 ;;
        *) ui_page '选项提示'; ui_warn '无效选项，请重新输入。' ;;
    esac
    ui_pause || break
done
