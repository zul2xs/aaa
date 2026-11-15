#!/usr/bin/env bash

# 确保以 root 权限运行
[ "$(id -u)" != 0 ] && echo "错误：必须以 root 权限运行此脚本！" && exit 1

WORK_DIR="/etc/sing-box"
mkdir -p "$WORK_DIR"

echo "========================================="
echo "   Sing-box 双节点 (Reality + Hy2) 安装"
echo "========================================="

# 1. 获取服务器 IP（支持自动检测并允许手动修改）
AUTO_IP=$(curl -s https://ip.sb || curl -s https://api.ipify.org)
read -p "请输入或确认服务器公网 IP [默认: ${AUTO_IP}]: " SERVER_IP
SERVER_IP=${SERVER_IP:-$AUTO_IP}

# 2. 输入端口
read -p "请输入 VLESS-Reality 端口 [默认: 8443]: " REALITY_PORT
REALITY_PORT=${REALITY_PORT:-8443}

read -p "请输入 Hysteria2 端口 [默认: 8444]: " HY2_PORT
HY2_PORT=${HY2_PORT:-8444}

# 3. 检查系统架构并下载安装 sing-box
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) SING_ARCH="amd64" ;;
    aarch64|arm64) SING_ARCH="arm64" ;;
    *) echo "错误：不支持的架构: $ARCH"; exit 1 ;;
esac

echo "正在下载并安装 sing-box..."
LATEST_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
LATEST_VER=${LATEST_VER:-1.10.0}
DL_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VER}/sing-box-${LATEST_VER}-linux-${SING_ARCH}.tar.gz"

curl -L -o /tmp/sing-box.tar.gz "$DL_URL"
tar -xzf /tmp/sing-box.tar.gz -C /tmp
mv /tmp/sing-box-${LATEST_VER}-linux-${SING_ARCH}/sing-box /usr/local/bin/
chmod +x /usr/local/bin/sing-box

# 4. 生成配置参数与密钥
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -hex 8)

# 生成 Reality 密钥对
KEYPAIR=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}' | tr -d '"')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}' | tr -d '"')

# 为 Hysteria2 生成自签证书
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout "${WORK_DIR}/key.pem" \
  -out "${WORK_DIR}/cert.pem" \
  -subj "/CN=gateway.icloud.com" 2>/dev/null

# 5. 写入配置文件
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
          "password": "${HY2_PASS}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${WORK_DIR}/cert.pem",
        "key_path": "${WORK_DIR}/key.pem"
      },
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

# 6. 配置 Systemd 服务
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
systemctl restart sing-box

# 7. 优雅输出节点信息与导入链接
clear
echo "========================================================================="
echo "                        🎉 安装配置成功！                                "
echo "========================================================================="
echo ""
echo "-------------------------------------------------------------------------"
echo " 1. 【VLESS-Reality 节点】"
echo "-------------------------------------------------------------------------"
echo " 服务器 IP   : ${SERVER_IP}"
echo " 端口        : ${REALITY_PORT}"
echo " UUID        : ${UUID}"
echo " Public Key  : ${PUBLIC_KEY}"
echo " SNI         : gateway.icloud.com"
echo " 📥 导入链接 :"
echo "vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=gateway.icloud.com&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp#vless-reality"
echo ""
echo "-------------------------------------------------------------------------"
echo " 2. 【Hysteria2 节点】"
echo "-------------------------------------------------------------------------"
echo " 服务器 IP   : ${SERVER_IP}"
echo " 端口        : ${HY2_PORT}"
echo " 密码        : ${HY2_PASS}"
echo " SNI         : gateway.icloud.com"
echo " 📥 导入链接 :"
echo "hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=gateway.icloud.com#hysteria2"
echo "========================================================================="
