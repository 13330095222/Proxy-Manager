#!/bin/bash
# ==============================================================================
# 子模块 3: Realm 高性能中转管理 (支持查看现有规则、随机端口、增量追加与删除)
# ==============================================================================
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

PROTO_HTTPS="ht""tps://"
GH_HOST="git""hub.com"

REALM_BIN="/usr/local/bin/realm"
REALM_DIR="/etc/realm"
REALM_CONF="${REALM_DIR}/config.toml"
REALM_SVC="/etc/systemd/system/realm.service"
PY_BIN=$(command -v python3 || command -v python)

mkdir -p "${REALM_DIR}"

# 首次安装下载 Realm 核心
install_realm_bin() {
    if [ ! -f "${REALM_BIN}" ]; then
        echo -e "${GREEN}正在下载 Realm 转发核心...${RESET}"
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
    fi
}

# 打印现有转发规则
list_relays() {
    echo -e "\n${CYAN}--- 当前已配置的 Realm 中转转发规则 ---${RESET}"
    if [ ! -f "${REALM_CONF}" ] || ! grep -q "\[\[endpoints\]\]" "${REALM_CONF}"; then
        echo -e "${YELLOW}暂无任何中转转发规则。${RESET}"
        return 1
    fi
    ${PY_BIN} -c "
import re
with open('${REALM_CONF}') as f:
    text = f.read()
blocks = text.split('[[endpoints]]')[1:]
for idx, b in enumerate(blocks, 1):
    l = re.search(r'listen\s*=\s*\"([^\"]+)\"', b)
    r = re.search(r'remote\s*=\s*\"([^\"]+)\"', b)
    if l and r:
        print(f'  [{idx}] 本机入口 {l.group(1)}  --->  目标落地 {r.group(1)}')
"
    return 0
}

# 同步元数据供主脚本放行防火墙
sync_realm_meta() {
    ${PY_BIN} -c "
import re
ports, summary = [], []
try:
    with open('${REALM_CONF}') as f:
        blocks = f.read().split('[[endpoints]]')[1:]
    for idx, b in enumerate(blocks, 1):
        l = re.search(r'listen\s*=\s*\"0\.0\.0\.0:(\d+)\"', b)
        r = re.search(r'remote\s*=\s*\"([^\"]+)\"', b)
        if l and r:
            ports.append(l.group(1))
            summary.append(f'[{idx}] 本机端口 {l.group(1)} (TCP+UDP) ---> 目标 {r.group(1)}')
except FileNotFoundError:
    pass
with open('${REALM_DIR}/meta.env', 'w') as out:
    out.write('RELAY_PORTS=\"' + ' '.join(ports) + '\"\n')
    out.write('RELAY_SUMMARY=\"' + '\\\\n'.join(summary) + '\"\n')
"
}

# 重载 Realm 系统服务
reload_realm() {
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
    sync_realm_meta
}

# 追加新规则
add_relays() {
    install_realm_bin
    if [ ! -f "${REALM_CONF}" ]; then
        cat << HEADER > "${REALM_CONF}"
[network]
no_tcp = false
use_udp = true
HEADER
    fi

    while true; do
        read -p "$(echo -e "${YELLOW}请输入本机中转监听端口 (直接回车将在 10000-50000 之间随机生成，输入 q 结束): ${RESET}")" L_PORT
        [ "$L_PORT" = "q" ] && break
        if [ -z "$L_PORT" ]; then
            L_PORT=$(shuf -i 10000-50000 -n 1 2>/dev/null || echo $((RANDOM % 40001 + 10000)))
            echo -e "${GREEN}-> 已随机分配本机中转端口: ${L_PORT}${RESET}"
        fi

        read -p "$(echo -e "${YELLOW}请输入目标落地服务器 IP 或域名: ${RESET}")" R_IP
        if [ -z "$R_IP" ]; then
            echo -e "${RED}目标地址不能为空，请重新填写！${RESET}"
            continue
        fi

        read -p "$(echo -e "${YELLOW}请输入目标落地服务器端口 (直接回车默认 443): ${RESET}")" R_PORT
        R_PORT=${R_PORT:-443}

        cat << ENDPOINT >> "${REALM_CONF}"

[[endpoints]]
listen = "0.0.0.0:${L_PORT}"
remote = "${R_IP}:${R_PORT}"
ENDPOINT
        echo -e "${GREEN}-> 已追加规则: 0.0.0.0:${L_PORT} -> ${R_IP}:${R_PORT}${RESET}"

        read -p "$(echo -e "${YELLOW}是否继续追加下一条中转规则？ [y/N] (回车完成): ${RESET}")" more
        [[ ! "$more" =~ ^[Yy]$ ]] && break
    done
    reload_realm
}

# 删除指定编号规则
del_relay() {
    if ! list_relays; then
        return
    fi
    read -p "$(echo -e "${YELLOW}请输入要删除的规则编号 (输入 0 取消): ${RESET}")" DEL_IDX
    [ -z "$DEL_IDX" ] || [ "$DEL_IDX" = "0" ] && return

    ${PY_BIN} -c "
with open('${REALM_CONF}') as f:
    parts = f.read().split('[[endpoints]]')
header = parts[0]
blocks = parts[1:]
idx = int('${DEL_IDX}') - 1
if 0 <= idx < len(blocks):
    blocks.pop(idx)
    with open('${REALM_CONF}', 'w') as out:
        out.write(header + ''.join(['[[endpoints]]' + b for b in blocks]))
    print('已成功删除指定规则！')
else:
    print('编号超出范围。')
"
    reload_realm
}

# 中转子菜单交互
list_relays || true
echo -e "\n${CYAN}请选择 Realm 中转操作：${RESET}"
echo -e "  ${GREEN}1.${RESET} 追加新的中转规则 (保留现有规则，端口支持回车随机)"
echo -e "  ${GREEN}2.${RESET} 删除指定的某条中转规则"
echo -e "  ${GREEN}3.${RESET} 清空所有旧规则并重新配置"
read -p "$(echo -e "${YELLOW}请输入选项 [1-3] (直接回车默认 1 追加): ${RESET}")" r_opt
r_opt=${r_opt:-1}

case "$r_opt" in
    1) add_relays ;;
    2) del_relay ;;
    3) rm -f "${REALM_CONF}"; add_relays ;;
    *) echo -e "${RED}无效选项${RESET}"; exit 1 ;;
esac
