#!/usr/bin/env bash

# 当前脚本版本号 (双节点定制版)
VERSION='v1.3.30-dual (2026.11.15)'

# 各变量默认值
TEMP_DIR='/tmp/sing-box'
WORK_DIR='/etc/sing-box'
START_PORT_DEFAULT='8881'
MIN_PORT=100
MAX_PORT=65520
DEFAULT_NEWEST_VERSION='1.15.0'

# 仅保留两个核心节点
PROTOCOL_LIST=("vless + reality" "hysteria2")
NODE_TAG=("vless-reality" "hysteria2")

export DEBIAN_FRONTEND=noninteractive

cleanup_temp() {
  rm -rf "$TEMP_DIR"
}

trap cleanup_temp EXIT
trap 'cleanup_temp; printf "\n"; exit 1' INT QUIT TERM
mkdir -p "$TEMP_DIR"

warning() { echo -e "\033[31m\033[01m$*\033[0m"; }
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; }
info() { echo -e "\033[32m\033[01m$*\033[0m"; }
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }

check_root() {
  [ "$(id -u)" != 0 ] && error "\n 必须以 root 方式运行此脚本 \n"
}

check_system_info() {
  [ -s /etc/os-release ] && SYS="$(awk -F '"' 'tolower($0) ~ /pretty_name/{print $2}' /etc/os-release)"
  SYSTEM='Debian'
  if grep -qi 'ubuntu' <<< "$SYS"; then SYSTEM='Ubuntu'; fi
  if grep -qi 'centos' <<< "$SYS"; then SYSTEM='CentOS'; fi
  if grep -qi 'alpine' <<< "$SYS"; then SYSTEM='Alpine'; fi

  SINGBOX_DAEMON_FILE='/etc/systemd/system/sing-box.service'
  [ "$SYSTEM" = 'Alpine' ] && SINGBOX_DAEMON_FILE='/etc/init.d/sing-box'
}

check_arch() {
  case "$(uname -m)" in
    aarch64|arm64 ) SING_BOX_ARCH=arm64 ;;
    x86_64|amd64 ) SING_BOX_ARCH=amd64 ;;
    * ) error "不支持的架构: $(uname -m)" ;;
  esac
}

check_install() {
  if [ -s ${SINGBOX_DAEMON_FILE} ]; then
    STATUS="运行中"
  else
    STATUS="未安装"
  fi
}

uninstall() {
  if [ -d ${WORK_DIR} ]; then
    rm -rf ${WORK_DIR} ${TEMP_DIR} /usr/bin/sb
    if [ "$SYSTEM" = 'Alpine' ]; then
      rc-service sing-box stop 2>/dev/null
      rc-update del sing-box 2>/dev/null
      rm -f /etc/init.d/sing-box
    else
      systemctl stop sing-box 2>/dev/null
      systemctl disable sing-box 2>/dev/null
      rm -f /etc/systemd/system/sing-box.service
      systemctl daemon-reload
    fi
    info "\n Sing-box 已彻底卸载 \n"
  else
    error "\n Sing-box 尚未安装 \n"
  fi
}

install_singbox() {
  info "正在准备安装 Sing-box (双节点: VLESS-Reality + Hysteria2)..."
  mkdir -p ${WORK_DIR}
  
  # 获取系统公网IP
  SERVER_IP=$(curl -s https://ip.sb || curl -s https://api.ipify.org)
  hint "检测到当前服务器 IP: ${SERVER_IP}"
  
  read -rp "请输入 VLESS-Reality 端口 (默认 8443): " REALITY_PORT
  REALITY_PORT=${REALITY_PORT:-8443}
  
  read -rp "请输入 Hysteria2 端口 (默认 8444): " HY2_PORT
  HY2_PORT=${HY2_PORT:-8444}

  # 生成 UUID 和 Reality 密钥对
  UUID=$(cat /proc/sys/kernel/random/uuid)
  
  # 下载并安装 sing-box 主程序
  LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
  LATEST_VERSION=${LATEST_VERSION:-$DEFAULT_NEWEST_VERSION}
  
  DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${SING_BOX_ARCH}.tar.gz"
  info "正在下载 sing-box v${LATEST_VERSION}..."
  curl -L -o "${TEMP_DIR}/sing-box.tar.gz" "${DOWNLOAD_URL}"
  
  tar -xzf "${TEMP_DIR}/sing-box.tar.gz" -C "${TEMP_DIR}"
  mv ${TEMP_DIR}/sing-box-${LATEST_VERSION}-linux-${SING_BOX_ARCH}/sing-box /usr/local/bin/
  chmod +x /usr/local/bin/sing-box

  # 生成 Reality 密钥
  KEYPAIR=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}' | tr -d '"')
  PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}' | tr -d '"')
  HY2_PASSWORD=$(openssl rand -hex 8)

  # 写入配置文件
  cat << EOF > ${WORK_DIR}/config.json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "stream_settings": {
        "network": "tcp",
        "security": "reality",
        "reality_settings": {
          "dest": "gateway.icloud.com:443",
          "server_names": [
            "gateway.icloud.com",
            "www.apple.com"
          ],
          "private_key": "${PRIVATE_KEY}"
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        {
          "password": "${HY2_PASSWORD}"
        }
      ],
      "masquerade": "https://gateway.icloud.com"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

  # 创建系统服务
  if [ "$SYSTEM" = 'Alpine' ]; then
    cat << EOF > /etc/init.d/sing-box
#!/sbin/openrc-run
name="sing-box"
description="Sing-box Service"
command="/usr/local/bin/sing-box"
command_args="run -c ${WORK_DIR}/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
EOF
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box start
  else
    cat << EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -c ${WORK_DIR}/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
  fi

  info "\n==================================================================="
  info " 安装成功！当前仅包含两个核心节点："
  info "-------------------------------------------------------------------"
  echo -e " 1. VLESS-Reality 节点:"
  echo -e "    - 服务器IP: ${SERVER_IP}"
  echo -e "    - 端口: ${REALITY_PORT}"
  echo -e "    - UUID: ${UUID}"
  echo -e "    - Public Key: ${PUBLIC_KEY}"
  echo -e "    - 目标域名: gateway.icloud.com"
  echo -e "-------------------------------------------------------------------"
  echo -e " 2. Hysteria2 节点:"
  echo -e "    - 服务器IP: ${SERVER_IP}"
  echo -e "    - 端口: ${HY2_PORT}"
  echo -e "    - 密码: ${HY2_PASSWORD}"
  info "===================================================================\n"
}

# 主菜单
menu() {
  check_root
  check_system_info
  check_arch
  check_install

  clear
  echo -e "===================================================================\n"
  info " Sing-box 双节点管理脚本 (VLESS-Reality + Hysteria2)"
  info " 当前状态: ${STATUS} | 系统: $SYS"
  echo -e "===================================================================\n"
  hint " 1. 安装/重置双节点配置"
  hint " 2. 查看当前节点信息"
  hint " 9. 卸载 Sing-box"
  hint " 0. 退出脚本"
  read -rp "请选择 [0-9]: " CHOOSE

  case "$CHOOSE" in
    1 ) install_singbox ;;
    2 ) 
        if [ -s ${WORK_DIR}/config.json ]; then
          info "配置文件位于: ${WORK_DIR}/config.json"
          cat ${WORK_DIR}/config.json
        else
          error "未找到配置文件，请先安装！"
        fi
        ;;
    9 ) uninstall ;;
    0 ) exit 0 ;;
    * ) warning "输入错误，请重新选择" && sleep 1 && menu ;;
  esac
}

menu
