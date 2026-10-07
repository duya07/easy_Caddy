#!/bin/bash

# 检查是否以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 用户运行此脚本。"
  exit 1
fi

# 安装 Nginx
install_nginx() {
  echo "正在安装 Nginx..."
  apt update && apt install -y nginx
  if [ $? -eq 0 ]; then
    echo "Nginx 安装完成！"
  else
    echo "Nginx 安装失败，请检查日志。"
    exit 1
  fi
}

# nginx 配置路径（测试可覆盖；主配置候选保留相同的相对 include 基目录）
CONFIG_DIR="/etc/nginx/sites-available"
ENABLED_DIR="/etc/nginx/sites-enabled"
NGINX_MAIN_CONFIG="/etc/nginx/nginx.conf"

# 校验器成功不输出，失败输出原因并返回非零。
validate_local_port() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    echo "错误：端口必须是 1-65535 之间的数字。"; return 1
  fi
}

nginx_valid_ipv4() {
  local value="$1" part; local -a parts
  [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$value"
  for part in "${parts[@]}"; do
    [[ ${#part} -le 3 ]] && (( 10#$part <= 255 )) || return 1
  done
}

nginx_valid_ipv6() {
  local value="$1" part count=0 compressed=0 seen_ipv4=0; local -a parts
  [[ "$value" == *:* && "$value" != *:::* && "$value" != *[^0-9a-fA-F:.]* ]] || return 1
  if [[ "$value" == *::* ]]; then
    compressed=1
    part="${value#*::}"; [[ "$part" != *::* ]] || return 1
  else
    [[ "$value" != :* && "$value" != *: ]] || return 1
  fi
  [[ "$value" != :* || "$value" == ::* ]] || return 1
  [[ "$value" != *: || "$value" == *:: ]] || return 1
  IFS=: read -r -a parts <<< "$value"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    if [[ "$part" == *.* ]]; then
      (( !seen_ipv4 )) && [[ "$value" == *:"$part" ]] && nginx_valid_ipv4 "$part" || return 1
      seen_ipv4=1
      ((count+=2))
    else
      [[ "$part" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
      ((count+=1))
    fi
  done
  if ((compressed)); then ((count < 8)); else ((count == 8)); fi
}

nginx_valid_host() {
  local host="$1" label; local -a labels
  [[ -n "$host" && ${#host} -le 253 ]] || return 1
  if [[ "$host" == *:* ]]; then nginx_valid_ipv6 "$host"; return; fi
  if [[ "$host" =~ ^[0-9.]+$ ]]; then nginx_valid_ipv4 "$host"; return; fi
  host="${host%.}"
  [[ -n "$host" && "$host" != *..* && "$host" != *[^a-zA-Z0-9.-]* ]] || return 1
  IFS=. read -r -a labels <<< "$host"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
  done
}

validate_domain() {
  if ! nginx_valid_host "$1"; then
    echo "错误：域名必须是单个普通 DNS 主机名或 IP 地址，不能包含路径或配置语法。"; return 1
  fi
}

validate_remote_upstream() {
  local url="$1" rest host port=""
  [[ "$url" == http://* || "$url" == https://* ]] || {
    echo "错误：远程网址必须以 http:// 或 https:// 开头。"; return 1;
  }
  rest="${url#*://}"
  if [[ "$rest" == \[* ]]; then
    if [[ "$rest" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
      host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[3]}"
      nginx_valid_ipv6 "$host" || { echo "错误：IPv6 地址无效。"; return 1; }
    else
      echo "错误：IPv6 地址必须写成 [地址] 或 [地址]:端口。"; return 1
    fi
  else
    if [[ "$rest" =~ ^([^:]+)(:([0-9]+))?$ ]]; then
      host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[3]}"
      nginx_valid_host "$host" || { echo "错误：上游主机名无效。"; return 1; }
    else
      echo "错误：上游必须是主机名或 IP，可带非空端口，不能包含路径、认证信息或配置语法。"; return 1
    fi
  fi
  [[ -z "$port" ]] || validate_local_port "$port"
}

upstream_is_loopback() {
  case "$1" in
    http://127.0.0.1|http://127.0.0.1:*|https://127.0.0.1|https://127.0.0.1:*|http://localhost|http://localhost:*|https://localhost|https://localhost:*|http://\[::1\]|http://\[::1\]:*|https://\[::1\]|https://\[::1\]:*) return 0 ;;
    *) return 1 ;;
  esac
}

build_server_block() {
  local domain="$1" upstream="$2" hostport host_header
  validate_domain "$domain" && validate_remote_upstream "$upstream" || return 1
  hostport="${upstream#*://}"; host_header="$hostport"
  upstream_is_loopback "$upstream" && host_header='$host'
  # URL 原样保留；proxy_pass 不加尾斜线，以保留原始 URI。
  printf 'server {\n    listen 80;\n    server_name %s;\n\n    location / {\n        # 域名在 nginx 启动/reload 时解析，地址变化后需要 reload。\n        proxy_pass %s;\n        proxy_ssl_server_name on;\n        proxy_set_header Host %s;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n    }\n}\n' "$domain" "$upstream" "$host_header"
}

# 将整个输入作为一个记录读取。词法分析忽略注释/引号内的花括号，
# 以字节位置替换指令，保留其余字节（包括 CRLF、尾注释和 EOF）。
# 仅支持一个单地址 server、一个直接的 location /；复杂 include 安全拒绝。
nginx_transform_config() {
  local mode="$1" source="$2" output="$3" domain="$4" upstream="$5" mirror="$6"
  local hostport="${upstream#*://}" header sslhost
  header="$hostport"; upstream_is_loopback "$upstream" && header='$host'
  sslhost="$hostport"
  if [[ "$sslhost" == \[* ]]; then sslhost="${sslhost%%]*}"; sslhost="${sslhost#[}"; else sslhost="${sslhost%%:*}"; fi
  LC_ALL=C awk -v mode="$mode" -v domain="$domain" -v upstream="$upstream" \
    -v header="$header" -v sslhost="$sslhost" -v mirror="$mirror" \
    -v enabled="$ENABLED_DIR" -v available="$CONFIG_DIR" -v main_dir="$(dirname -- "$NGINX_MAIN_CONFIG")" '
  function fail(message) { print "无法安全改写 nginx 配置：" message > "/dev/stderr"; bad=1; exit 1 }
  function replace(a,b,value) { rstart[++nr]=a; rend[nr]=b; rtext[nr]=value }
  function directive(endpos,    id,j,path,absolute) {
    if (!na) fail("空指令")
    id=++nd; name[id]=arg[1]; dep[id]=depth; ctx[id]=block[depth]
    start[id]=apos[1]; finish[id]=endpos; argc[id]=na
    for(j=1;j<=na;j++) { val[id,j]=arg[j]; vpos[id,j]=apos[j]; vend[id,j]=aend[j] }
    if(mode=="main" && arg[1]=="include") {
      if(na!=2) fail("include 参数歧义")
      path=arg[2]; absolute=path
      if(substr(path,1,1)!="/") absolute=main_dir "/" path
      if(absolute==enabled "/*") { replace(apos[2],aend[2],"\"" mirror "/*\""); includes++ }
      else if(index(absolute,enabled "/")==1 || index(absolute,available "/")==1) fail("复杂站点 include 不支持")
    }
    na=0
  }
  BEGIN { RS="\0" }
  {
    text=$0; n=length(text); depth=0
    for(i=1;i<=n;) {
      ch=substr(text,i,1)
      if(ch ~ /[ \t\r\n]/) { i++; continue }
      if(ch=="#") { while(i<=n && substr(text,i,1)!="\n") i++; continue }
      if(ch==";") { directive(i); i++; continue }
      if(ch=="{") {
        if(!na) fail("块缺少头部")
        kind=arg[1]; parent=block[depth]; depth++; block[depth]=kind
        if(mode=="edit") {
          if(kind=="server") { if(parent!="" || na!=1) fail("复杂 server"); servers++ }
          if(kind=="location" && parent=="server" && na==2 && arg[2]=="/") { locations++; target=depth; targetopen=i+1; targetclose=0 }
          if(parent=="location" && kind=="location") fail("嵌套 location 不支持")
        }
        na=0; i++; continue
      }
      if(ch=="}") {
        if(na || depth<=0) fail("块边界不完整")
        if(mode=="edit" && depth==target && block[depth]=="location" && !targetclose) targetclose=i
        delete block[depth]; depth--; i++; continue
      }
      begin=i; value=""; quote=""
      while(i<=n) {
        ch=substr(text,i,1)
        if(quote!="") {
          if(ch=="\\") { i++; if(i>n) fail("未完成转义"); value=value substr(text,i,1); i++; continue }
          if(ch==quote) { quote=""; i++; continue }
          value=value ch; i++; continue
        }
        if(ch=="\"" || ch==sprintf("%c",39)) { quote=ch; i++; continue }
        if(ch=="\\") { i++; if(i>n) fail("未完成转义"); value=value substr(text,i,1); i++; continue }
        if(ch=="$" && substr(text,i+1,1)=="{") {
          value=value "${"; i+=2
          while(i<=n && substr(text,i,1)!="}") { value=value substr(text,i,1); i++ }
          if(i>n) fail("变量边界不完整"); value=value "}"; i++; continue
        }
        if(ch ~ /[ \t\r\n;{}#]/) break
        value=value ch; i++
      }
      if(quote!="" || i==begin) fail("引号或 token 不完整")
      arg[++na]=value; apos[na]=begin; aend[na]=i-1
    }
    if(depth || na) fail("配置不完整")
    if(mode=="main") { if(includes!=1) fail("需要唯一 sites-enabled/* include") }
    else {
      if(servers!=1 || locations!=1 || !targetclose) fail("需要唯一 server 和直接 location /")
      for(id=1;id<=nd;id++) {
        if(name[id]=="server_name" && ctx[id]=="server") {
          if(argc[id]!=2 || val[id,2]!=domain) fail("共享或不匹配 server_name")
          names++
        }
        if(name[id]=="include") fail("站点内 include 不支持")
        if(ctx[id]!="location" || dep[id]!=target || start[id]>targetclose) continue
        # 排除 /admin 等同级 location：目标起点须在唯一 / 的块区间内。
        if(start[id]<targetopen) continue
        if(name[id]=="proxy_pass") { passes++; pass=id }
        if(name[id]=="proxy_set_header" && tolower(val[id,2])=="host") { hosts++; host=id }
        if(name[id]=="proxy_ssl_server_name") { snis++; sni=id }
        if(name[id]=="proxy_ssl_name") { sslnames++; sslname=id }
      }
      if(names!=1 || passes!=1 || hosts>1 || snis>1 || sslnames>1) fail("代理或 Host/SNI 指令歧义")
      if(argc[pass]!=2) fail("proxy_pass 参数歧义")
      replace(start[pass],finish[pass],"proxy_pass " upstream ";")
      addition=""
      if(hosts) replace(start[host],finish[host],"proxy_set_header Host " header ";")
      else addition=addition "\n        proxy_set_header Host " header ";"
      if(upstream ~ /^https:/) {
        if(snis) replace(start[sni],finish[sni],"proxy_ssl_server_name on;")
        else addition=addition "\n        proxy_ssl_server_name on;"
        if(sslnames) replace(start[sslname],finish[sslname],"proxy_ssl_name " sslhost ";")
        else addition=addition "\n        proxy_ssl_name " sslhost ";"
      }
      if(addition!="") replace(finish[pass]+1,finish[pass],addition)
    }
    # 按位置应用替换，不重排任何其他文本。
    cursor=1
    for(k=1;k<=nr;k++) {
      smallest=0
      for(j=1;j<=nr;j++) if(!used[j] && (!smallest || rstart[j]<rstart[smallest] || (rstart[j]==rstart[smallest] && rend[j]<rend[smallest]))) smallest=j
      if(rstart[smallest]<cursor) fail("替换区域重叠")
      printf "%s%s", substr(text,cursor,rstart[smallest]-cursor),rtext[smallest]
      cursor=rend[smallest]+1; used[smallest]=1
    }
    printf "%s",substr(text,cursor)
  }
  ' "$source" > "$output"
}

# 镜像全部启用项；候选 main 与原 main 同目录，故其他相对 include 仍指向原位置。
nginx_validate_candidate() {
  local domain="$1" candidate="$2" action="$3" work="$4" entry name resolved config_file="$CONFIG_DIR/$1"
  local mirror="$work/enabled" main_candidate
  [[ -f "$NGINX_MAIN_CONFIG" && ! -L "$NGINX_MAIN_CONFIG" ]] || { echo "主配置不存在或为不支持的软链。"; return 1; }
  mkdir -- "$mirror" || return 1
  for entry in "$ENABLED_DIR"/* "$ENABLED_DIR"/.[!.]* "$ENABLED_DIR"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="${entry##*/}"
    [[ "$name" == "$domain" ]] && continue
    resolved=$(readlink -f -- "$entry") || { echo "启用项不可解析：$entry"; return 1; }
    if [[ "$resolved" == "$config_file" ]]; then echo "同一站点有多个启用链接，拒绝修改。"; return 1; fi
    ln -s -- "$entry" "$mirror/$name" || return 1
  done
  if [[ "$action" != delete ]]; then ln -s -- "$candidate" "$mirror/$domain" || return 1; fi
  main_candidate=$(mktemp "$(dirname -- "$NGINX_MAIN_CONFIG")/.easy-nginx-main.XXXXXX") || return 1
  if ! nginx_transform_config main "$NGINX_MAIN_CONFIG" "$main_candidate" "" "" "$mirror"; then
    rm -f -- "$main_candidate"; return 1
  fi
  nginx -t -c "$main_candidate"
  local result=$?
  rm -f -- "$main_candidate" || return 1
  return "$result"
}

# 候选检查后提交，任一失败恢复原文件和启用链接；恢复失败保留备份并明确报告。
nginx_config_transaction() {
  local domain="$1" candidate="$2" action="$3" work="$4"
  local config_file="$CONFIG_DIR/$domain" link="$ENABLED_DIR/$domain" had_file=0 had_link=0 failed=0 applied=0 restored=1 stage=""
  if [[ -L "$config_file" || ( -e "$config_file" && ! -f "$config_file" ) ]]; then echo "站点不是普通文件，拒绝操作。"; return 1; fi
  if [[ -e "$link" && ! -L "$link" ]]; then echo "启用项不是软链，拒绝操作。"; return 1; fi
  if [[ -L "$link" ]] && [[ "$(readlink -f -- "$link")" != "$config_file" ]]; then echo "启用链接指向其他配置，拒绝操作。"; return 1; fi
  if [[ -f "$config_file" ]]; then
    cp -p -- "$config_file" "$work/original" || return 1; had_file=1
  fi
  if [[ -L "$link" ]]; then cp -a -- "$link" "$work/original-link" || return 1; had_link=1; fi
  nginx_validate_candidate "$domain" "$candidate" "$action" "$work" || { echo "候选全配置校验失败，未提交。"; return 1; }
  if [[ "$action" == delete ]]; then
    rm -f -- "$config_file" || failed=1
    ((failed)) || rm -f -- "$link" || failed=1
  else
    stage=$(mktemp "$CONFIG_DIR/.easy-nginx-commit.XXXXXX") || return 1
    cp -p -- "$candidate" "$stage" && mv -f -- "$stage" "$config_file" || failed=1
    rm -f -- "$stage" || failed=1
    ((failed)) || ln -sfn -- "$config_file" "$link" || failed=1
  fi
  if (( !failed )); then
    if nginx -t -c "$NGINX_MAIN_CONFIG"; then
      applied=1; systemctl reload nginx || failed=1
    else failed=1; fi
  fi
  ((failed)) || return 0
  echo "应用失败，正在恢复原站点与启用链接。"
  if ((had_file)); then cp -p -- "$work/original" "$config_file" || restored=0; else rm -f -- "$config_file" || restored=0; fi
  rm -f -- "$link" || restored=0
  if ((had_link)); then cp -a -- "$work/original-link" "$link" || restored=0; fi
  if (( !restored )); then
    echo "恢复文件或链接失败！恢复材料：$work"; NGINX_KEEP_RECOVERY=1
  elif ((applied)); then
    if ! nginx -t -c "$NGINX_MAIN_CONFIG" || ! systemctl reload nginx; then
      echo "文件和链接已恢复，但恢复后的服务 reload 失败；请检查 nginx。恢复材料：$work"
      NGINX_KEEP_RECOVERY=1
    fi
  fi
  return 1
}

nginx_finish_transaction() {
  local result="$1" work="$2"
  if [[ "$NGINX_KEEP_RECOVERY" != 1 ]]; then rm -rf -- "$work" || return 1; fi
  return "$result"
}

apply_proxy_config() {
  local domain="$1" upstream="$2" work result
  validate_domain "$domain" && validate_remote_upstream "$upstream" || return 1
  [[ -d "$CONFIG_DIR" && -d "$ENABLED_DIR" ]] || { echo "nginx 站点目录不存在。"; return 1; }
  if [[ -e "$CONFIG_DIR/$domain" || -L "$CONFIG_DIR/$domain" || -e "$ENABLED_DIR/$domain" || -L "$ENABLED_DIR/$domain" ]]; then
    echo "站点已存在，请使用修改入口。"; return 1
  fi
  work=$(mktemp -d "${TMPDIR:-/tmp}/easy-nginx.XXXXXX") || return 1
  NGINX_KEEP_RECOVERY=0
  if build_server_block "$domain" "$upstream" > "$work/candidate"; then
    nginx_config_transaction "$domain" "$work/candidate" add "$work"; result=$?
  else result=1; fi
  nginx_finish_transaction "$result" "$work" || return 1
  echo "反向代理 $domain -> $upstream 配置完成！"
}

setup_local_proxy() {
  local domain target_port err
  read -r -p "请输入域名： " domain || return 1
  validate_domain "$domain" || return 1
  while true; do
    read -r -p "请输入目标端口： " target_port || { echo "输入结束，已取消。"; return 1; }
    err=$(validate_local_port "$target_port")
    if [[ -n "$err" ]]; then echo "$err"; continue; fi
    break
  done
  apply_proxy_config "$domain" "http://127.0.0.1:$target_port"
}

setup_remote_proxy() {
  local domain upstream err
  read -r -p "请输入域名： " domain || return 1
  validate_domain "$domain" || return 1
  while true; do
    read -r -p "请输入远程网址（http:// 或 https://）： " upstream || { echo "输入结束，已取消。"; return 1; }
    err=$(validate_remote_upstream "$upstream")
    if [[ -n "$err" ]]; then echo "$err"; continue; fi
    break
  done
  apply_proxy_config "$domain" "$upstream"
}

modify_proxy() {
  local domain target upstream err work result config_file
  list_proxies
  read -r -p "请输入要修改的域名： " domain || return 1
  validate_domain "$domain" || return 1
  config_file="$CONFIG_DIR/$domain"
  [[ -f "$config_file" && ! -L "$config_file" ]] || { echo "未找到普通站点文件：$domain"; return 1; }
  cat -- "$config_file" || return 1
  read -r -p "新目标（端口号或完整 http(s) URL）： " target || return 1
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    validate_local_port "$target" || return 1
    upstream="http://127.0.0.1:$target"
  else upstream="$target"; fi
  validate_remote_upstream "$upstream" || return 1
  work=$(mktemp -d "${TMPDIR:-/tmp}/easy-nginx.XXXXXX") || return 1
  NGINX_KEEP_RECOVERY=0
  if cp -p -- "$config_file" "$work/candidate" && nginx_transform_config edit "$config_file" "$work/edited" "$domain" "$upstream" "" && cat -- "$work/edited" > "$work/candidate"; then
    nginx_config_transaction "$domain" "$work/candidate" modify "$work"; result=$?
  else result=1; fi
  nginx_finish_transaction "$result" "$work" || return 1
  echo "$domain 的反向代理目标已更新为 $upstream。"
}

delete_proxy() {
  local domain work result
  read -r -p "请输入要删除的域名： " domain || return 1
  validate_domain "$domain" || return 1
  [[ -f "$CONFIG_DIR/$domain" && ! -L "$CONFIG_DIR/$domain" ]] || { echo "未找到普通站点文件：$domain"; return 1; }
  work=$(mktemp -d "${TMPDIR:-/tmp}/easy-nginx.XXXXXX") || return 1
  NGINX_KEEP_RECOVERY=0
  nginx_config_transaction "$domain" "" delete "$work"; result=$?
  nginx_finish_transaction "$result" "$work" || return 1
  echo "$domain 配置已删除！"
}

# 添加反向代理（二级菜单）
add_proxy() {
  local proxy_choice

  while true; do
    echo "========================================="
    echo "             添加反向代理"
    echo "========================================="
    echo " 1) 反代本地端口（域名 -> http://127.0.0.1:端口）"
    echo " 2) 反代远程网址（域名 -> https://目标网址）"
    echo " 0) 返回"
    echo "========================================="
    read -p "请选择操作： " proxy_choice || return
    case "$proxy_choice" in
      1)
        setup_local_proxy
        ;;
      2)
        setup_remote_proxy
        ;;
      0)
        return
        ;;
      *)
        echo "无效的选择，请重新选择。"
        ;;
    esac
    echo
  done
}

# 查看所有反向代理配置
list_proxies() {
  echo "当前所有反向代理配置："
  ls "$CONFIG_DIR"
}

# 检查 Nginx 是否正在运行
nginx_status() {
  systemctl is-active --quiet nginx
  if [ $? -eq 0 ]; then
    echo -e "\033[32mNginx 正在运行。\033[0m"  # Green color for running
  else
    echo -e "\033[31mNginx 未运行。\033[0m"  # Red color for not running
  fi
}

# 重启 Nginx
restart_nginx() {
  echo "正在重启 Nginx..."
  systemctl restart nginx
  if [ $? -eq 0 ]; then
    echo "Nginx 重启成功！"
  else
    echo "Nginx 重启失败，请检查日志。"
  fi
}

# 一键删除并卸载 Nginx
uninstall_nginx() {
  echo "正在删除所有反向代理配置..."
  rm -rf "$CONFIG_DIR"/*
  rm -rf "$ENABLED_DIR"/*
  systemctl stop nginx
  systemctl disable nginx
  apt remove --purge -y nginx nginx-common nginx-full
  apt autoremove -y
  echo "Nginx 已卸载，所有反向代理配置已删除！"
}

# 主菜单
while true; do
  # 显示 Nginx 状态
  nginx_status

  echo "========================================="
  echo "Nginx 反向代理管理脚本"
  echo "1. 安装 Nginx"
  echo "2. 添加反向代理（本地端口 / 远程网址）"
  echo "3. 删除反向代理"
  echo "4. 查看所有反向代理配置"
  echo "5. 修改反向代理配置"
  echo "6. 重启 Nginx"
  echo "7. 一键删除并卸载 Nginx"
  echo "8. 退出"
  read -p "请选择操作： " choice || break

  case $choice in
    1)
      install_nginx
      ;;
    2)
      add_proxy
      ;;
    3)
      delete_proxy
      ;;
    4)
      list_proxies
      ;;
    5)
      modify_proxy
      ;;
    6)
      restart_nginx
      ;;
    7)
      uninstall_nginx
      exit 0
      ;;
    8)
      echo "退出脚本"
      exit 0
      ;;
    *)
      echo "无效的选择，请重新选择。"
      ;;
  esac
done
