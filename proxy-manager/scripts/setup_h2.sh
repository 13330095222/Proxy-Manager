#!/bin/bash
# ==============================================================================
# 子模块 2: 部署 Hysteria2 (支持 20k-30k 端口跳跃与 ACME 正规域名证书)
# ==============================================================================
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 动态拼接防网页剪贴板截断
PROTO_HTTPS="ht""tps://"
GH_HOST="git""hub.com"
DEFAULT_SNI="ww""w.bi""ng.com"

HY2_BIN="/usr/local/bin/hysteria"
HY2_DIR="/etc/hysteria"
HY2_CONF="${HY2_DIR}/config.yaml"
HY2_SVC="/etc/systemd/system/hysteria-server.service"

echo -e "\n${GREEN}[步骤 2/3 - Hysteria2] 配置 Hysteria2 参数...${RESET}"

# 1. 交互设置监听主端口（回车则在 20000-30000 之间随机生成）
read -p "$(echo -e "${YELLOW}1. 请输入 Hysteria2 主端口 (直接回车将在 20000-30000 之间随机生成): ${RESET}")" H_PORT
if [ -z "$H_PORT" ]; then
    H_PORT=$(shuf -i 20000-30000 -n 1 2>/dev/null || echo $((RANDOM % 10001 + 20000)))
    echo -e "${GREEN}-> 已随机分配主端口: ${H_PORT}${RESET}"
fi

# 2. 交互设置连接密码
read -p "$(echo -e "${YELLOW}2. 请输入自定义连接密码 (直接回车自动生成高强度随机密码): ${RESET}")" INPUT_PASS
if [ -z "$INPUT_PASS" ]; then
    H_PASS="GameUDP_$(openssl rand -hex 4)"
    echo -e "${GREEN}-> 已自动生成密码: ${H_PASS}${RESET}"
else
    H_PASS="$INPUT_PASS"
fi

# 3. 交互设置证书模式（输入已解析域名启用 ACME 正规证书，回车使用自签名证书）
read -p "$(echo -e "${YELLOW}3. 如需绑定域名申请正规 TLS 证书请直接输入域名 (直接回车使用免域名自签名证书): ${RESET}")" USER_DOMAIN
PUBLIC_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb)

# 4. 识别 CPU 架构并下载最新版 Hysteria2 核心
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) H_ARCH="amd64" ;;
    aarch64|arm64) H_ARCH="arm64" ;;
    *) echo -e "${RED}不支持的 CPU 架构: $ARCH${RESET}"; exit 1 ;;
esac

H_URL="${PROTO_HTTPS}${GH_HOST}/apernet/hysteria/releases/latest/download/hysteria-linux-${H_ARCH}"
curl -fL --progress-bar -o "${HY2_BIN}" "${H_URL}"
chmod +x "${HY2_BIN}"

# 5. 生成 TLS 证书与服务端配置文件
mkdir -p "${HY2_DIR}"
if [ -n "$USER_DOMAIN" ]; then
    USE_ACME="true"
    H_SNI="$USER_DOMAIN"
    H_ADDR="$USER_DOMAIN"
    H_INSECURE=0
    TLS_BLOCK="acme:
  domains:
    - ${H_SNI}
  email: admin@${H_SNI}"
    echo -e "${GREEN}-> 已启用 ACME 域名证书模式 (${H_SNI})${RESET}"
else
    USE_ACME="false"
    H_SNI="${DEFAULT_SNI}"
    H_ADDR="${PUBLIC_IP}"
    H_INSECURE=1
    openssl ecparam -genkey -name prime256v1 -out "${HY2_DIR}/server.key" 2>/dev/null
    openssl req -new -x509 -days 36500 -key "${HY2_DIR}/server.key" -out "${HY2_DIR}/server.crt" -subj "/CN=${H_SNI}" 2>/dev/null
    chmod 600 "${HY2_DIR}/server.key"
    TLS_BLOCK="tls:
  cert: ${HY2_DIR}/server.crt
  key: ${HY2_DIR}/server.key"
    echo -e "${GREEN}-> 已启用免域名自签名证书模式 (伪装 SNI: ${H_SNI})${RESET}"
fi

cat << CONF > "${HY2_CONF}"
listen: 0.0.0.0:${H_PORT}

${TLS_BLOCK}

auth:
  type: password
  password: ${H_PASS}

bandwidth:
  up: 100 mbps
  down: 100 mbps

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s
  maxIncomingStreams: 1024

masquerade:
  type: proxy
  proxy:
    url: ${PROTO_HTTPS}${DEFAULT_SNI}
    rewriteHost: true
CONF

# 6. 注册并启动 Systemd 后台守护进程
cat << SVC > "${HY2_SVC}"
[Unit]
Description=Hysteria2 UDP Game Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${HY2_BIN} server -c ${HY2_CONF}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now hysteria-server.service >/dev/null 2>&1
systemctl restart hysteria-server.service

# 7. 导出元数据供主脚本读取汇总
cat << ENV > "${HY2_DIR}/meta.env"
H_PORT=${H_PORT}
H_PASS=${H_PASS}
H_SNI=${H_SNI}
H_ADDR=${H_ADDR}
H_INSECURE=${H_INSECURE}
USE_ACME=${USE_ACME}
ENV

echo -e "${GREEN}-> Hysteria2 模块部署完成！${RESET}"
