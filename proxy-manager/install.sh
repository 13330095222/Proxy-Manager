#!/bin/bash
# ==============================================================================
# 项目名称: 多协议游戏加速与中转节点模块化管理脚本
# 适用系统: Ubuntu / Debian / CentOS / Rocky Linux (x86_64 & ARM64)
# 核心功能: 1. VLESS+Reality(Vision) 2. Hysteria2(端口跳跃/ACME) 3. Realm中转
# ==============================================================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# 定位脚本所在目录（兼容本地运行与 Git 克隆运行）
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${BASE_DIR}/scripts"
chmod +x "${SCRIPTS_DIR}"/*.sh 2>/dev/null || true

XRAY_DIR="/usr/local/etc/xray"
HY2_DIR="/etc/hysteria"
REALM_DIR="/etc/realm"
INFO_FILE="/root/proxy_nodes_summary.txt"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[错误] 请先执行 sudo su 切换到 root 用户后再运行此脚本！${RESET}"
    exit 1
fi

# 通用交互确认函数（直接回车默认确认 y）
confirm_step() {
    local msg="$1"
    read -p "$(echo -e "${YELLOW}${msg} [Y/n] (回车默认确认): ${RESET}")" ans
    ans=${ans:-y}
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo -e "${RED}已取消当前操作。${RESET}"
        exit 0
    fi
}

# 1. 环境初始化与内核 BBR 加速优化
prepare_env() {
    echo -e "\n${GREEN}[步骤 1/3] 正在检查基础依赖与开启内核 TCP BBR 加速...${RESET}"
    for cmd in curl openssl tar python3; do
        if ! command -v $cmd >/dev/null 2>&1; then
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update -y >/dev/null 2>&1
                apt-get install -y curl openssl tar python3 iptables-persistent >/dev/null 2>&1
            elif command -v yum >/dev/null 2>&1; then
                yum install -y curl openssl tar python3 >/dev/null 2>&1
            fi
            break
        fi
    done

    # 若存在 SELinux 则设为宽容模式，防止拦截端口转发
    if command -v setenforce >/dev/null 2>&1; then
        setenforce 0 2>/dev/null || true
        sed -i 's/^SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config 2>/dev/null || true
    fi

    # 写入内核参数：启用 BBR 拥塞控制与调大 UDP/TCP 读写缓冲区
    cat << SYSCTL > /etc/sysctl.d/99-proxy-opt.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.ip_forward=1
SYSCTL
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-proxy-opt.conf >/dev/null 2>&1
}

# 2. 自动配置系统防火墙与端口跳跃
apply_firewall() {
    echo -e "\n${GREEN}[步骤 3/3] 正在配置系统防火墙与底层 NAT 转发规则...${RESET}"
    NIC=$(ip -4 route show default | awk '{print $5}' | head -n 1)
    [ -z "$NIC" ] && NIC="eth0"

    unset R_PORT H_PORT USE_ACME RELAY_PORTS
    [ -f "${XRAY_DIR}/meta.env" ] && source "${XRAY_DIR}/meta.env"
    [ -f "${HY2_DIR}/meta.env" ] && source "${HY2_DIR}/meta.env"
    [ -f "${REALM_DIR}/meta.env" ] && source "${REALM_DIR}/meta.env"

    # 适配 CentOS/Rocky firewalld
    if systemctl is-active --quiet firewalld; then
        [ -n "$R_PORT" ] && firewall-cmd --permanent --add-port=${R_PORT}/tcp >/dev/null 2>&1
        if [ -n "$H_PORT" ]; then
            firewall-cmd --permanent --add-port=${H_PORT}/udp >/dev/null 2>&1
            firewall-cmd --permanent --add-port=${H_PORT}/tcp >/dev/null 2>&1
            firewall-cmd --permanent --add-port=20000-30000/udp >/dev/null 2>&1
            [ "$USE_ACME" = "true" ] && firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 && firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1
            firewall-cmd --permanent --add-masquerade >/dev/null 2>&1
        fi
        for rp in $RELAY_PORTS; do
            firewall-cmd --permanent --add-port=${rp}/tcp >/dev/null 2>&1
            firewall-cmd --permanent --add-port=${rp}/udp >/dev/null 2>&1
        done
        firewall-cmd --reload >/dev/null 2>&1
    fi

    # 适配 Ubuntu/Debian ufw
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        [ -n "$R_PORT" ] && ufw allow ${R_PORT}/tcp >/dev/null 2>&1
        if [ -n "$H_PORT" ]; then
            ufw allow ${H_PORT}/udp >/dev/null 2>&1
            ufw allow 20000:30000/udp >/dev/null 2>&1
            [ "$USE_ACME" = "true" ] && ufw allow 80/tcp >/dev/null 2>&1 && ufw allow 443/tcp >/dev/null 2>&1
        fi
        for rp in $RELAY_PORTS; do
            ufw allow ${rp}/tcp >/dev/null 2>&1
            ufw allow ${rp}/udp >/dev/null 2>&1
        done
    fi

    # 写入 Hysteria2 20000-30000 端口跳跃 NAT 重定向
    if [ -n "$H_PORT" ]; then
        iptables -t nat -F PREROUTING 2>/dev/null || true
        iptables -t nat -A PREROUTING -i "$NIC" -p udp --dport 20000:30000 -j REDIRECT --to-ports ${H_PORT}
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
    fi
}

# 3. 汇总并打印所有已部署节点信息（使用 Python 标准 JSON 解析，杜绝索引错位）
show_nodes() {
    PUBLIC_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb)
    BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    PY_BIN=$(command -v python3 || command -v python)

    echo "============================================================" > "${INFO_FILE}"
    echo "         节点部署信息汇总 (内核拥塞控制: ${BBR_STATUS})         " >> "${INFO_FILE}"
    echo "============================================================" >> "${INFO_FILE}"

    # 展示 VLESS + Reality 信息
    if [ -f "${XRAY_DIR}/config.json" ] && [ -f "${XRAY_DIR}/meta.env" ]; then
        source "${XRAY_DIR}/meta.env"
        echo "" >> "${INFO_FILE}"
        echo "【节点 1】VLESS + TCP + Reality + Vision (状态: $(systemctl is-active xray))" >> "${INFO_FILE}"
        echo "监听端口: ${R_PORT} | 伪装 SNI: ${REALITY_TARGET} | 建议客户端核心: xray" >> "${INFO_FILE}"
        UUID_LIST=$(${PY_BIN} -c "import json; d=json.load(open('${XRAY_DIR}/config.json')); print(' '.join([c['id'] for c in d['inbounds'][0]['settings']['clients']]))")
        IDX=1
        for U in $UUID_LIST; do
            echo "用户 ${IDX} 导入链接:" >> "${INFO_FILE}"
            echo "vless://${U}@${PUBLIC_IP}:${R_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_TARGET}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp#Reality_User${IDX}_${PUBLIC_IP}" >> "${INFO_FILE}"
            IDX=$((IDX+1))
        done
    fi

    # 展示 Hysteria2 信息
    if [ -f "${HY2_DIR}/config.yaml" ] && [ -f "${HY2_DIR}/meta.env" ]; then
        source "${HY2_DIR}/meta.env"
        echo "" >> "${INFO_FILE}"
        echo "【节点 2】Hysteria2 20k-30k 端口跳跃 (状态: $(systemctl is-active hysteria-server.service))" >> "${INFO_FILE}"
        echo "地址: ${H_ADDR} | 主端口: ${H_PORT} (跳跃: 20000-30000) | 建议客户端核心: xray" >> "${INFO_FILE}"
        echo "导入链接:" >> "${INFO_FILE}"
        echo "hysteria2://${H_PASS}@${H_ADDR}:${H_PORT}/?mport=20000-30000&sni=${H_SNI}&insecure=${H_INSECURE}&upmbps=100&downmbps=100#H2_Hop_${PUBLIC_IP}" >> "${INFO_FILE}"
    fi

    # 展示 Realm 中转信息
    if [ -f "${REALM_DIR}/config.toml" ] && [ -f "${REALM_DIR}/meta.env" ]; then
        source "${REALM_DIR}/meta.env"
        echo "" >> "${INFO_FILE}"
        echo "【中转服务】Realm TCP+UDP 端口转发 (状态: $(systemctl is-active realm.service))" >> "${INFO_FILE}"
        echo "中转入口 IP: ${PUBLIC_IP}" >> "${INFO_FILE}"
        echo -e "${RELAY_SUMMARY}" >> "${INFO_FILE}"
    fi

    echo "============================================================" >> "${INFO_FILE}"
    echo ""
    cat "${INFO_FILE}"
    echo -e "${YELLOW}提示：请确保云服务商安全组已放行对应的 TCP/UDP 端口！${RESET}"
}

# 4. 为 Reality 节点追加多用户 UUID
add_reality_user() {
    if [ ! -f "${XRAY_DIR}/config.json" ]; then
        echo -e "${RED}未检测到已安装的 Reality 服务！${RESET}"
        exit 1
    fi
    NEW_UUID=$(/usr/local/bin/xray uuid)
    PY_BIN=$(command -v python3 || command -v python)
    ${PY_BIN} -c "
import json
with open('${XRAY_DIR}/config.json', 'r') as f:
    d = json.load(f)
d['inbounds'][0]['settings']['clients'].append({'id': '${NEW_UUID}', 'flow': 'xtls-rprx-vision'})
with open('${XRAY_DIR}/config.json', 'w') as f:
    json.dump(d, f, indent=2)
"
    systemctl restart xray
    echo -e "${GREEN}成功添加新用户 UUID: ${NEW_UUID}${RESET}"
    show_nodes
}

# 5. 彻底卸载所有组件
uninstall_all() {
    echo -e "\n${RED}警告：此操作将停止并彻底删除本机部署的所有代理与中转服务！${RESET}"
    confirm_step "确定要执行彻底卸载吗？"
    systemctl stop xray hysteria-server.service realm.service 2>/dev/null || true
    systemctl disable xray hysteria-server.service realm.service 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/hysteria-server.service /etc/systemd/system/realm.service
    rm -f /usr/local/bin/xray /usr/local/bin/hysteria /usr/local/bin/realm "${INFO_FILE}" /etc/sysctl.d/99-proxy-opt.conf
    rm -rf "${XRAY_DIR}" "${HY2_DIR}" "${REALM_DIR}" /var/log/xray
    systemctl daemon-reload
    iptables -t nat -F PREROUTING 2>/dev/null || true
    echo -e "${GREEN}所有组件与配置已彻底清理干净！${RESET}"
}

# 主交互菜单
clear
echo -e "${CYAN}============================================================${RESET}"
echo -e "${CYAN}       全能游戏加速与中转节点管理脚本 (Modular Edition)     ${RESET}"
echo -e "${CYAN}============================================================${RESET}"
echo -e "  ${GREEN}1.${RESET} 一键部署双协议落地 (VLESS-Reality + Hysteria2)"
echo -e "  ${GREEN}2.${RESET} 仅部署 VLESS + TCP + Reality + Vision (主力推荐)"
echo -e "  ${GREEN}3.${RESET} 仅部署 Hysteria2 (支持 20k-30k 端口跳跃与域名证书)"
echo -e "  ${GREEN}4.${RESET} 部署/更新 Realm 中转转发 (专用于中转跳板服务器)"
echo -e "  ${GREEN}5.${RESET} 查看当前所有节点配置与客户端导入链接"
echo -e "  ${GREEN}6.${RESET} 新增 Reality 多用户 UUID (独立链接分发)"
echo -e "  ${GREEN}7.${RESET} 重启所有已安装服务"
echo -e "  ${GREEN}8.${RESET} 彻底卸载所有节点与中转组件"
echo -e "${CYAN}============================================================${RESET}"
read -p "$(echo -e "${YELLOW}请输入数字选择操作 [1-8]: ${RESET}")" opt

case "$opt" in
    1)
        confirm_step "即将部署双协议落地节点，是否继续？"
        prepare_env
        bash "${SCRIPTS_DIR}/setup_reality.sh"
        bash "${SCRIPTS_DIR}/setup_h2.sh"
        apply_firewall
        show_nodes
        ;;
    2)
        confirm_step "即将部署 VLESS + Reality 节点，是否继续？"
        prepare_env
        bash "${SCRIPTS_DIR}/setup_reality.sh"
        apply_firewall
        show_nodes
        ;;
    3)
confirm_step "即将部署 Hysteria2 节点，是否继续？"
prepare_env
bash "${SCRIPTS_DIR}/setup_h2.sh"
apply_firewall
show_nodes
;;
4)
confirm_step "即将在本机配置 Realm 端口中转转发，是否继续？"
prepare_env
bash "${SCRIPTS_DIR}/setup_relay.sh"
apply_firewall
show_nodes
;;
5)
show_nodes
;;
6)
add_reality_user
;;
7)
[ -f /etc/systemd/system/xray.service ] && systemctl restart xray
[ -f /etc/systemd/system/hysteria-server.service ] && systemctl restart hysteria-server.service
[ -f /etc/systemd/system/realm.service ] && systemctl restart realm.service
sleep 2
show_nodes
;;
8)
uninstall_all
;;
*)
echo -e "${RED}无效选项，请输入 1 到 8 之间的数字。${RESET}"
exit 1
;;
esac
