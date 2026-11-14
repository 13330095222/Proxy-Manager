#!/bin/bash
# ==============================================================================
# 子模块 1: 部署 VLESS + TCP + Reality + Vision (主力落地/直连节点)
# ==============================================================================
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 动态拼接防网页复制截断
PROTO_HTTPS="ht""tps://"
GH_HOST="git""hub.com"
DEFAULT_TARGET="ww""w.micr""osoft.com"

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONF="${XRAY_DIR}/config.json"
XRAY_SVC="/etc/systemd/system/xray.service"

echo -e "\n${GREEN}[步骤 2/3 - Reality] 配置 VLESS + Reality 参数...${RESET}"
read -p "$(echo -e "${YELLOW}请输入 Reality 监听端口 (直接回车默认 443): ${RESET}")" R_PORT
R_PORT=${R_PORT:-443}

read -p "$(echo -e "${YELLOW}请输入伪装目标域名 SNI (直接回车默认 ${DEFAULT_TARGET}): ${RESET}")" USER_SNI
REALITY_TARGET=${USER_SNI:-$DEFAULT_TARGET}

# 识别 CPU 架构并下载对应 Xray 核心
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) X_ZIP="Xray-linux-64.zip" ;;
    aarch64|arm64) X_ZIP="Xray-linux-arm64-v8a.zip" ;;
    *) echo -e "${RED}不支持的 CPU 架构: $ARCH${RESET}"; exit 1 ;;
esac

mkdir -p "${XRAY_DIR}" /var/log/xray
X_URL="${PROTO_HTTPS}${GH_HOST}/XTLS/Xray-core/releases/latest/download/${X_ZIP}"
curl -fL --progress-bar -o /tmp/xray.zip "${X_URL}"

PY_BIN=$(command -v python3 || command -v python)
${PY_BIN} -c "import zipfile; zipfile.ZipFile('/tmp/xray.zip').extractall('/usr/local/bin/')"
rm -f /tmp/xray.zip
chmod +x "${XRAY_BIN}"

# 动态生成全新的 UUID 与 x25519 密钥对（零硬编码敏感信息）
UUID=$(${XRAY_BIN} uuid)
KEYS=$(${XRAY_BIN} x25519)
PRIV_KEY=$(echo "$KEYS" | awk -F': ' 'NR==1 {print $2}' | tr -d ' \r\n')
PUB_KEY=$(echo "$KEYS" | awk -F': ' 'NR==2 {print $2}' | tr -d ' \r\n')
SHORT_ID=$(openssl rand -hex 4)

if [ -z "$PRIV_KEY" ] || [ -z "$PUB_KEY" ]; then
    echo -e "${RED}密钥生成异常，请检查 Xray 核心是否正常下载！${RESET}"
    exit 1
fi

# 写入 Xray 服务端配置文件
cat << CONF > "${XRAY_CONF}"
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${R_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_TARGET}:443",
          "xver": 0,
          "serverNames": [
            "${REALITY_TARGET}"
          ],
          "privateKey": "${PRIV_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
CONF

# 注册 Systemd 后台守护进程
cat << SVC > "${XRAY_SVC}"
[Unit]
Description=Xray Reality Service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${XRAY_CONF}
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now xray >/dev/null 2>&1
systemctl restart xray

# 导出元数据供主脚本读取汇总
cat << ENV > "${XRAY_DIR}/meta.env"
R_PORT=${R_PORT}
PUB_KEY=${PUB_KEY}
SHORT_ID=${SHORT_ID}
REALITY_TARGET=${REALITY_TARGET}
ENV

echo -e "${GREEN}-> Reality 模块部署完成！${RESET}"
