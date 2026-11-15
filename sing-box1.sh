#!/bin/bash

# 确保以 root 权限运行
[[ $EUID -ne 0 ]] && echo "请使用 root 权限运行此脚本！" && exit 1

CONFIG_FILE="/etc/sing-box/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

# 安装 sing-box
install_singbox() {
    echo "正在安装 sing-box..."
    apt-get update && apt-get install -y curl wget jq systemd
    bash <(curl -fsSL https://sing-box.app/deb.sh)
    echo "sing-box 安装完成。"
}

# 生成配置
generate_config() {
    echo "=========================================="
    echo "      配置 XTLS-Reality & Hysteria2       "
    echo "=========================================="

    # 获取服务器 IP
    PUBLIC_IP=$(curl -s https://api.ipify.org)
    
    # 1. 配置 VLESS-Reality
    read -p "请输入 VLESS-Reality 端口 [默认 443]: " REALITY_PORT
    REALITY_PORT=${REALITY_PORT:-443}
    
    read -p "请输入 Reality 伪装域名 (例如 dl.google.com): " REALITY_SNI
    REALITY_SNI=${REALITY_SNI:-dl.google.com}

    # 生成 Reality 密钥对
    KEY_PAIR=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "PrivateKey" | awk '{print $2}' | tr -d '"')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "PublicKey" | awk '{print $2}' | tr -d '"')
    UUID=$(sing-box generate uuid)

    # 2. 配置 Hysteria2
    read -p "请输入 Hysteria2 端口 [默认 8443]: " HY2_PORT
    HY2_PORT=${HY2_PORT:-8443}
    
    read -p "请输入 Hysteria2 认证密码: " HY2_PASSWORD
    HY2_PASSWORD=${HY2_PASSWORD:-$(openssl rand -hex 8)}

    # 创建配置目录
    mkdir -p /etc/sing-box

    # 写入 sing-box 配置文件
    cat << EOF > $CONFIG_FILE
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $REALITY_PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REALITY_SNI",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": [
            "0123456789abcdef"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [
        {
          "password": "$HY2_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/sing-box/cert.crt",
        "key_path": "/etc/sing-box/cert.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "outbound": "direct"
    }
  ]
}
EOF

    # 为 Hysteria2 生成自签证书（若没有域名）
    openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/cert.key
    openssl req -new -x509 -days 3650 -key /etc/sing-box/cert.key -out /etc/sing-box/cert.crt -subj "/CN=bing.com"

    # 重启并启用服务
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box

    echo "=========================================="
    echo "              安装配置成功！              "
    echo "=========================================="
    echo "服务器 IP: $PUBLIC_IP"
    echo "------------------------------------------"
    echo "【VLESS-Reality 节点信息】"
    echo "端口: $REALITY_PORT"
    echo "UUID: $UUID"
    echo "公钥 (Public Key): $PUBLIC_KEY"
    echo "SNI: $REALITY_SNI"
    echo "vless://$UUID@$PUBLIC_IP:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=0123456789abcdef&type=tcp&headerType=none#VLESS-Reality"
    echo "------------------------------------------"
    echo "【Hysteria2 节点信息】"
    echo "端口: $HY2_PORT"
    echo "密码: $HY2_PASSWORD"
    echo "hysteria2://$HY2_PASSWORD@$PUBLIC_IP:$HY2_PORT?insecure=1#Hysteria2"
    echo "=========================================="
}

# 菜单
echo "1. 安装/重置 节点 (VLESS-Reality + Hysteria2)"
echo "2. 查看节点信息"
echo "3. 卸载"
read -p "请选择 [1-3]: " CHOICE

case $CHOICE in
    1)
        install_singbox
        generate_config
        ;;
    2)
        if [ -f "$CONFIG_FILE" ]; then
            cat $CONFIG_FILE
        else
            echo "未找到配置文件，请先安装。"
        fi
        ;;
    3)
        systemctl stop sing-box
        systemctl disable sing-box
        rm -rf /etc/sing-box
        apt-get purge -y sing-box
        echo "已卸载完成。"
        ;;
    *)
        echo "无效选项"
        ;;
esac
