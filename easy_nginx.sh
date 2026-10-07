#!/bin/bash

# 检查是否以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 用户运行此脚本。"
  exit 1
fi

# nginx 配置目录（测试时可覆盖这两个变量）
CONFIG_DIR="/etc/nginx/sites-available"
ENABLED_DIR="/etc/nginx/sites-enabled"

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

#--------------------------------------------
# 判断 upstream 是否指向本机回环（判据与 easyCaddy.sh 一致）
#--------------------------------------------
upstream_is_loopback() {
  local upstream="$1"
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
# 从回环 upstream 中取端口号（未写明端口且主机名干净时按协议给默认端口）
# 解析不出来时返回空串
#--------------------------------------------
loopback_port() {
  local upstream="$1"
  local hostport host
  hostport="${upstream#*://}"

  # 明确带端口：IPv6 字面量 [addr]:8080 与普通 host:8080
  if [[ "$hostport" =~ ^\[[^]]*\]:([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$hostport" =~ ^([^:]+):([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[2]}"
    return
  fi

  # 未写明端口：主机名必须干净（非空、无空白、无游离冒号；IPv6 需写成 [addr]）
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
# 校验本地端口输入（不通过时输出错误信息，通过时不输出）
#--------------------------------------------
validate_local_port() {
  local port="$1"
  if [ -z "$port" ]; then
    echo "端口输入不能为空，请重新输入。"
    return
  fi
  if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "错误：端口必须是 1-65535 之间的数字（例如 8080），请重新输入。"
    return
  fi
}

#--------------------------------------------
# 校验远程网址输入（不通过时输出错误信息，通过时不输出）
# 判据与 easyCaddy.sh 的 validate_remote_upstream 对等：必须显式带 http:// 或 https://，
# 不含空白 / userinfo(@) / 路径 / 查询串 / 锚点，端口必须是 1-65535，
# [ ] 包裹的 IPv6 字面量单独放行
#--------------------------------------------
validate_remote_upstream() {
  local url="$1"

  case "$url" in
    http://*|https://*) ;;
    *)
      echo "错误：远程网址必须以 http:// 或 https:// 开头（不接受裸域名），请重新输入。"
      return
      ;;
  esac

  local rest hostonly portpart
  rest="${url#*://}"

  # 含空白字符（如 "https://a.com b.com"）会让生成的 nginx 配置语法错误，
  # reload 失败会连带影响其它站点，必须直接拒掉
  case "$rest" in
    *[[:space:]]*)
      echo "错误：远程网址不能包含空格等空白字符，请重新输入。"
      return
      ;;
  esac

  # 含 userinfo（"https://user:pass@host"）不是 nginx proxy_pass 支持的写法
  case "$rest" in
    *@*)
      echo "错误：远程网址不能包含用户名/密码（@），请只输入 协议 + 主机名（可带端口）。"
      return
      ;;
  esac

  hostonly="${rest%%[/?#]*}"

  if [ -z "$hostonly" ]; then
    echo "错误：远程网址缺少主机名（示例：https://target.example.com），请重新输入。"
    return
  fi

  if [ "$hostonly" != "$rest" ]; then
    echo "错误：远程网址不能包含路径、查询串或锚点（proxy_pass 的地址不支持），请只输入 协议 + 主机名（可带端口）。"
    return
  fi

  # 端口段校验：[ ] 包裹的 IPv6 字面量单独放行（端口取 ] 之后的部分），
  # 其余情况无冒号即无端口、多冒号一律拒绝、端口必须是 1-65535
  portpart="${hostonly##*:}"
  if [[ "$hostonly" == \[* ]]; then
    portpart=""
    if [[ "$hostonly" =~ ^\[[^]]*\]:([0-9]{1,5})$ ]]; then
      portpart="${BASH_REMATCH[1]}"
    elif [[ ! "$hostonly" =~ ^\[[^]]*\]$ ]]; then
      echo "错误：远程网址的主机名格式不正确（IPv6 字面量应写成 [地址] 或 [地址]:端口），请重新输入。"
      return
    fi
  elif [ "$portpart" == "$hostonly" ]; then
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
# 生成 nginx server 块（本地端口与远程网址共用）
# 用法：build_server_block <域名> <upstream>
# 说明：printf 的格式串用单引号包裹，里面的 $host / $remote_addr 等 nginx 变量
#       不会被 shell 展开，必须原样写进配置文件。
#--------------------------------------------
build_server_block() {
  local domain="$1"
  local upstream="$2"

  if upstream_is_loopback "$upstream"; then
    local target_port
    target_port=$(loopback_port "$upstream")
    printf 'server {\n    listen 80;\n    server_name %s;\n\n    location / {\n        proxy_pass http://127.0.0.1:%s;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n    }\n}\n' "$domain" "$target_port"
  else
    local scheme hostport
    scheme="${upstream%%://*}"
    hostport="${upstream#*://}"
    # 远程网址：proxy_pass 结尾不要加 /，否则会替换掉原请求 URI
    #          proxy_ssl_server_name on 是反代 HTTPS 上游的必要项（不发 SNI 会被上游拒绝或给默认站点）
    printf 'server {\n    listen 80;\n    server_name %s;\n\n    location / {\n        # 注意：proxy_pass 里的域名在 nginx 启动/reload 时解析一次并缓存，\n        #       上游 IP 变化后需要重新 reload（systemctl reload nginx）才会生效。\n        proxy_pass %s://%s;\n        # 反代 HTTPS 上游必须打开 SNI，否则上游收不到 SNI（多站点上游会返回默认站点或直接拒绝）。\n        proxy_ssl_server_name on;\n        proxy_set_header Host %s;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n    }\n}\n' "$domain" "$scheme" "$hostport" "$hostport"
  fi
}

#--------------------------------------------
# 写入配置文件、建立软链并 reload nginx
#--------------------------------------------
apply_proxy_config() {
  local domain="$1"
  local upstream="$2"
  local config_file="$CONFIG_DIR/$domain"

  echo "正在添加反向代理配置..."
  if ! build_server_block "$domain" "$upstream" > "$config_file"; then
    echo "写入配置文件失败：$config_file"
    return 1
  fi

  ln -sfn "$config_file" "$ENABLED_DIR/$domain"
  systemctl reload nginx

  echo "反向代理 $domain -> $upstream 配置完成！"
}

#--------------------------------------------
# 添加反向代理：反代本地端口
#--------------------------------------------
setup_local_proxy() {
  local domain target_port err

  read -p "请输入域名： " domain || return
  if [ -z "$domain" ]; then
    echo "域名输入不能为空。"
    return
  fi

  while true; do
    read -p "请输入反向代理的目标端口（例如 8080）： " target_port || { echo "输入结束，已取消。"; return; }
    err=$(validate_local_port "$target_port")
    if [ -n "$err" ]; then
      echo "$err"
      continue
    fi
    break
  done

  apply_proxy_config "$domain" "http://127.0.0.1:$target_port"
}

#--------------------------------------------
# 添加反向代理：反代远程网址
#--------------------------------------------
setup_remote_proxy() {
  local domain upstream err

  read -p "请输入域名： " domain || return
  if [ -z "$domain" ]; then
    echo "域名输入不能为空。"
    return
  fi

  while true; do
    read -p "请输入远程网址（必须带 http:// 或 https:// 前缀，例如 https://target.example.com）： " upstream || { echo "输入结束，已取消。"; return; }
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

  apply_proxy_config "$domain" "$upstream"
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

# 删除反向代理配置
delete_proxy() {
  local domain
  read -p "请输入要删除的域名： " domain || return
  config_file="$CONFIG_DIR/$domain"

  if [ -f "$config_file" ]; then
    rm "$config_file"
    rm "$ENABLED_DIR/$domain"
    systemctl reload nginx
    echo "$domain 配置已删除！"
  else
    echo "未找到配置文件：$domain"
  fi
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

# 修改反向代理配置（本地端口与远程网址都支持）
modify_proxy() {
  local domain new_target new_upstream err

  list_proxies
  read -p "请输入要修改的域名： " domain || return
  config_file="$CONFIG_DIR/$domain"

  if [ -f "$config_file" ]; then
    echo "当前配置如下："
    cat "$config_file"
    echo "请输入新的反向代理目标：直接输入端口号（例如 8080）表示反代本机端口，"
    echo "输入完整网址（例如 https://target.example.com）表示反代远程网址。"
    read -p "新目标： " new_target || return

    if [ -z "$new_target" ]; then
      echo "输入不能为空，未做修改。"
      return
    fi

    if [[ "$new_target" =~ ^[0-9]+$ ]]; then
      err=$(validate_local_port "$new_target")
      if [ -n "$err" ]; then
        echo "$err"
        return
      fi
      new_upstream="http://127.0.0.1:$new_target"
    else
      err=$(validate_remote_upstream "$new_target")
      if [ -n "$err" ]; then
        echo "$err"
        return
      fi
      new_upstream="$new_target"
    fi

    # 用统一的块生成函数重写整个配置文件，本地/远程模板各自正确
    build_server_block "$domain" "$new_upstream" > "$config_file"

    # 重载 Nginx 配置
    systemctl reload nginx
    echo "$domain 的反向代理目标已更新为 $new_upstream。"
  else
    echo "未找到配置文件：$domain"
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
