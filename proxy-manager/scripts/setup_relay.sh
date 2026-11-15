#!/bin/bash
# ==============================================================================
# 子模块 3: 部署 Realm 高性能中转转发 (支持 TCP + UDP 双协议全端口转发)
# ==============================================================================
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

PROTO_HTTPS="ht""tps://"
GH_HOST="git""hub.com"

REALM_BIN="/usr/local/bin/realm"
REALM_DIR="/etc/realm"
REALM_CONF="${REALM_DIR}/config.toml"
REALM_SVC="/etc/systemd/system/realm.service"

echo -e "\n${GREEN}[步骤 2/3 - Realm 中转] 配置端口转发规则...${RESET}"

# 1. 交互式收集转发规则（支持添加多条转发端口）
mkdir -p "${REALM_DIR}"
cat << HEADER > "${REALM_CONF}"
[network]
no_tcp = false
use_udp = true
HEADER

RELAY_PORTS=""
RELAY_SUMMARY=""

while true; do
    read -p "$(echo -e "${YELLOW}请输入本机中转监听端口 (回车默认 10443，输入 q 结束): ${RESET}")" L_PORT
    [ "$L_PORT" = "q" ] && break
    L_PORT=${L_PORT:-10443}

    read -p "$(echo -e "${YELLOW}请输入目标落地服务器 IP 或域名: ${RESET}")" R_IP
    if [ -z "$R_IP" ]; then
        echo -e "${RED}目标 IP 不能为空，请重新填写！${RESET}"
        continue
    fi

    read -p "$(echo -e "${YELLOW}请输入目标落地服务器端口 (回车默认 443): ${RESET}")" R_PORT
    R_PORT=${R_PORT:-443}

    cat << ENDPOINT >> "${REALM_CONF}"

[[endpoints]]
listen = "0.0.0.0:${L_PORT}"
remote = "${R_IP}:${R_PORT}"
ENDPOINT

    RELAY_PORTS="${RELAY_PORTS} ${L_PORT}"
    RELAY_SUMMARY="${RELAY_SUMMARY}本机端口 ${L_PORT} (TCP+UDP) ---> 目标 ${R_IP}:${R_PORT}\n"
    echo -e "${GREEN}-> 已添加规则: 0.0.0.0:${L_PORT} -> ${R_IP}:${R_PORT}${RESET}"

    read -p "$(echo -e "${YELLOW}是否继续添加下一条转发规则？ [y/N] (回车结束添加): ${RESET}")" more
    [[ ! "$more" =~ ^[Yy]$ ]] && break
done


# 2. 识别 CPU 架构并下载最新版 Realm 转发核心
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) R_TAR="realm-x86_64-unknown-linux-gnu.tar.gz" ;;
    aarch64|arm64) R_TAR="realm-aarch64-unknown-linux-gnu.tar.gz" ;;
    *) echo -e "${RED}不支持的 CPU 架构: $ARCH${RESET}"; exit 1 ;;
esac

R_URL="${PROTO_HTTPS}${GH_HOST}/zhboner/realm/releases/latest/download/${R_TAR}"
curl -fL --progress-bar -o /tmp/realm.tar.gz "${R_URL}"
tar -xzf /tmp/realm.tar.gz -C /usr/local/bin/
rm -f /tmp/realm.tar.gz
chmod +x "${REALM_BIN}"

# 3. 注册并启动 Systemd 后台守护进程
cat << SVC > "${REALM_SVC}"
[Unit]
Description=Realm High Performance Relay
After=network.target

[Service]
Type=simple
User=root
ExecStart=${REALM_BIN} -c ${REALM_CONF}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now realm.service >/dev/null 2>&1
systemctl restart realm.service

# 4. 导出元数据供主脚本放行防火墙与汇总展示
cat << ENV > "${REALM_DIR}/meta.env"
RELAY_PORTS="${RELAY_PORTS}"
RELAY_SUMMARY="${RELAY_SUMMARY}"
ENV

echo -e "${GREEN}-> Realm 中转模块部署完成！${RESET}"
